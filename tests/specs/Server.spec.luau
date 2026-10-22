local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PackageRoot = ReplicatedStorage.Packages.EZProfileStore
local ServerModule = require(PackageRoot.Server)
local Signal = require(PackageRoot.Parent.Signal)

-- Stores created by specs never start sessions for real players (such as the developer in a
-- Play-mode run); specs seed profiles directly instead.
local function isolated(config: any): any
	if typeof(config) == "table" and config.autoLoadPlayers == nil then
		config.autoLoadPlayers = false
	end
	return config
end
local Server = setmetatable({
	new = function(config: any)
		return ServerModule.new(isolated(config))
	end,
	mock = function(config: any)
		return ServerModule.mock(isolated(config))
	end,
}, { __index = ServerModule })
local Shared = require(PackageRoot.Shared)

local function makeFakePlayer(): any
	local player = Instance.new("Folder")
	player.Name = "TestPlayer"
	return player
end

local function makeFakeProfile(data: { [any]: any })
	return {
		Data = data,
		SessionLoadCount = 1,
		OnSave = Signal.new(),
		OnAfterSave = Signal.new(),
		OnLastSave = Signal.new(),
		OnSessionEnd = Signal.new(),
		Save = function() end,
		EndSession = function() end,
	}
end

local function makeServer(template: { [any]: any }?, leaderstats: { any }?, extra: { [string]: any }?)
	local config: { [string]: any } = {
		storeName = "TestStore_" .. tostring(math.random(1, 1e9)),
		template = template or { Coins = 0 },
		mode = "studio",
		leaderstats = leaderstats,
	}
	for key, value in extra or {} do
		config[key] = value
	end
	return Server.new(config :: any)
end

local function seed(server: any, player: any, data: { [any]: any }): any
	local profile = makeFakeProfile(data)
	server._profiles[player] = profile
	return profile
end

return function()
	describe("Server wire format", function()
		local function ops(server, player)
			local result = {}
			for _, entry in server._pendingBatches[player] or {} do
				table.insert(result, entry)
			end
			return result
		end

		it("emits set, del, and ins for the minimal change", function()
			local server = makeServer({})
			local player = makeFakePlayer()
			seed(server, player, { Coins = 0, Flag = true, Items = { "Bow" }, Stats = { Wins = 1, Losses = 0 } })

			expect(server:Update(player, function(data)
				data.Coins = 100
				data.Flag = nil
				table.insert(data.Items, "Sword")
				data.Stats.Wins += 1
			end)).to.equal(true)

			local byKey = {}
			for _, entry in ops(server, player) do
				byKey[entry[2]] = entry
			end
			expect(byKey.Coins[1]).to.equal(Shared.OP.Set)
			expect(byKey.Coins[3]).to.equal(100)
			expect(byKey.Flag[1]).to.equal(Shared.OP.Del)
			expect(byKey.Items[1]).to.equal(Shared.OP.Ins)
			expect(byKey.Items[3]).to.equal("Sword")
			expect(byKey["Stats.Wins"][3]).to.equal(2)
			expect(byKey["Stats.Losses"]).to.equal(nil)
			expect(#ops(server, player)).to.equal(4)

			server:Destroy()
		end)

		it("replaces a whole array when it changes other than by appending", function()
			local server = makeServer({})
			local player = makeFakePlayer()
			seed(server, player, { Items = { "a", "b", "c" } })

			server:Update(player, function(data)
				table.remove(data.Items, 1)
			end)

			local batch = ops(server, player)
			expect(#batch).to.equal(1)
			expect(batch[1][1]).to.equal(Shared.OP.Set)
			expect(#batch[1][3]).to.equal(2)

			server:Destroy()
		end)

		it("sends nothing when the transform changes nothing", function()
			local server = makeServer({})
			local player = makeFakePlayer()
			seed(server, player, { Coins = 5, Stats = { Wins = 1 } })

			expect(server:Update(player, function(data)
				data.Coins = 5
				local _ = data.Stats.Wins
			end)).to.equal(true)
			expect(server._pendingBatches[player]).to.equal(nil)

			server:Destroy()
		end)

		it("_waitForData seals the open batch under the snapshot sequence", function()
			local server = makeServer({ Items = {} })
			local player = makeFakePlayer()
			seed(server, player, { Items = {} })

			server:Update(player, function(data)
				table.insert(data.Items, "Sword")
			end)
			expect(server._sequences[player]).to.equal(1)

			local snapshot = server:_waitForData(player)
			expect(snapshot.seq).to.equal(1)
			expect(snapshot.data.Items[1]).to.equal("Sword")
			expect(server._pendingBatches[player]).to.equal(nil)

			server:Update(player, function(data)
				table.insert(data.Items, "Shield")
			end)
			expect(server._sequences[player]).to.equal(2)

			server:Destroy()
		end)

		it("coalesces repeated writes in one frame", function()
			local server = makeServer({})
			local player = makeFakePlayer()
			seed(server, player, { Coins = 0 })

			for _ = 1, 3 do
				server:Update(player, function(data)
					data.Coins += 1
				end)
			end

			local batch = ops(server, player)
			expect(#batch).to.equal(1)
			expect(batch[1][3]).to.equal(3)
			expect(server._sequences[player]).to.equal(1)

			server:Destroy()
		end)

		it("keeps a parent write after earlier child writes in the same frame", function()
			local server = makeServer({})
			local player = makeFakePlayer()
			seed(server, player, {})

			server:Update(player, function(data)
				data.A = { x = 1 }
			end)
			server:Update(player, function(data)
				data.A.x = 2
			end)
			server:Update(player, function(data)
				data.A = nil
			end)

			local batch = ops(server, player)
			expect(batch[#batch][1]).to.equal(Shared.OP.Del)
			expect(batch[#batch][2]).to.equal("A")

			server:Destroy()
		end)

		it("copies payloads so later writes are not replayed twice", function()
			local server = makeServer({})
			local player = makeFakePlayer()
			seed(server, player, {})

			server:Update(player, function(data)
				data.Items = {}
			end)
			server:Update(player, function(data)
				table.insert(data.Items, "Sword")
			end)

			local batch = ops(server, player)
			expect(#batch[1][3]).to.equal(0)
			expect(batch[2][1]).to.equal(Shared.OP.Ins)
			expect(#server:Get(player).Items).to.equal(1)

			server:Destroy()
		end)
	end)

	describe("Server snapshot requests", function()
		it("serves one in-flight request per player and rejects extras immediately", function()
			local server = makeServer()
			local player = makeFakePlayer()
			local release = Signal.new()

			local waits = 0
			server._waitForData = function()
				waits += 1
				release:Wait()
				return { seq = 0, data = {} }
			end

			local snapshot = nil
			task.spawn(function()
				snapshot = server:_serveSnapshotRequest(player)
			end)

			expect(server._snapshotRequests[player]).to.equal(true)
			expect(server:_serveSnapshotRequest(player)).to.equal(nil)
			expect(waits).to.equal(1)

			release:Fire()
			expect(snapshot.seq).to.equal(0)
			expect(server._snapshotRequests[player]).to.equal(nil)

			task.spawn(function()
				server:_serveSnapshotRequest(player)
			end)
			expect(waits).to.equal(2)

			server:_onPlayerRemoving(player)
			expect(server._snapshotRequests[player]).to.equal(nil)

			release:Fire()
			server:Destroy()
		end)

		it("clears in-flight requests when the store is destroyed", function()
			local server = makeServer()
			local player = makeFakePlayer()
			local release = Signal.new()

			server._waitForData = function()
				release:Wait()
				return nil
			end

			task.spawn(function()
				server:_serveSnapshotRequest(player)
			end)
			expect(server._snapshotRequests[player]).to.equal(true)

			server:Destroy()
			expect(server._snapshotRequests[player]).to.equal(nil)

			release:Fire()
		end)
	end)

	describe("Server:IsReady", function()
		it("returns false after ProfileStore reports the session inactive", function()
			local server = makeServer()
			local player = makeFakePlayer()
			local profile = seed(server, player, {})
			profile.IsActive = function()
				return false
			end

			expect(server:IsReady(player)).to.equal(false)
			expect(server:Get(player)).to.equal(nil)
			expect(server:GetProfileAsync(player, 0.01)).to.equal(nil)
			expect(server:GetAsync(player, 0.01)).to.equal(nil)

			server:Destroy()
		end)
	end)

	describe("Server save signals", function()
		it("keeps save signal forwarding active while ending a player session", function()
			local server = makeServer()
			local player = makeFakePlayer()
			local profile = seed(server, player, { Coins = 0 })
			server._profileConnections[player] = {
				profile.OnSave:Connect(function()
					server.PreSave:Fire(player, profile.Data)
				end),
				profile.OnLastSave:Connect(function(reason)
					server.LastSave:Fire(player, reason)
				end),
			}
			profile.EndSession = function()
				profile.OnSave:Fire()
				profile.OnLastSave:Fire("Manual")
				profile.OnSessionEnd:Fire()
			end

			local preSaveFired = false
			local lastSaveReason = nil
			server.PreSave:Connect(function()
				preSaveFired = true
			end)
			server.LastSave:Connect(function(_, reason)
				lastSaveReason = reason
			end)

			server:_onPlayerRemoving(player)

			expect(preSaveFired).to.equal(true)
			expect(lastSaveReason).to.equal("Manual")

			server:Destroy()
		end)
	end)

	describe("Server.new leaderstats validation", function()
		local function build(template, entry)
			return pcall(function()
				Server.new({
					storeName = "BadStat_" .. tostring(math.random(1, 1e9)),
					template = template,
					mode = "studio",
					leaderstats = { entry },
				}):Destroy()
			end)
		end

		it("rejects a selector that errors on the template", function()
			expect(build({ Coins = 0 }, {
				name = "Bad",
				type = "IntValue",
				value = function(data)
					return data.Stats.Wins
				end,
			})).to.equal(false)
		end)

		it("rejects a selector whose type doesn't match the Value class", function()
			expect(build({ Name = "Bob" }, {
				name = "Name",
				type = "IntValue",
				value = function(data)
					return data.Name
				end,
			})).to.equal(false)
		end)
	end)

	describe("Server leaderstats", function()
		local function setup()
			local server = makeServer({ Coins = 0, Stats = { Wins = 0, Losses = 0 } }, {
				{
					name = "Coins",
					type = "IntValue",
					value = function(data)
						return data.Coins
					end,
				},
				{
					name = "Games",
					type = "IntValue",
					value = function(data)
						return data.Stats.Wins + data.Stats.Losses
					end,
				},
			})
			local player = makeFakePlayer()
			seed(server, player, { Coins = 25, Stats = { Wins = 3, Losses = 1 } })
			server:_buildLeaderstats(player)
			return server, player
		end

		it("creates a leaderstats Folder seeded from data, including derived stats", function()
			local server, player = setup()

			local folder = player:FindFirstChild("leaderstats")
			expect(folder).to.be.ok()
			expect(folder.Coins.Value).to.equal(25)
			expect(folder.Games.Value).to.equal(4)

			server:Destroy()
		end)

		it("mirrors changes after flush", function()
			local server, player = setup()

			server:Update(player, function(data)
				data.Coins = 100
				data.Stats = { Wins = 7, Losses = 1 }
			end)
			server:_flushUpdates()

			local folder = player:FindFirstChild("leaderstats")
			expect(folder.Coins.Value).to.equal(100)
			expect(folder.Games.Value).to.equal(8)

			server:Destroy()
		end)
	end)

	describe("Server save-safety validation", function()
		it("rejects values DataStores cannot save", function()
			local server = makeServer({})
			local player = makeFakePlayer()
			seed(server, player, { Coins = 0, Name = "a", Items = {} })

			local badWrites = {
				function(data)
					data.Coins = 0 / 0
				end,
				function(data)
					data.Coins = math.huge
				end,
				function(data)
					data.Name = "\255"
				end,
				function(data)
					data.Color = workspace
				end,
				function(data)
					-- selene: allow(mixed_table)
					data.Mixed = { 1, Key = 2 }
				end,
				function(data)
					table.insert(data.Items, workspace)
				end,
				function(data)
					data.Items[1.5] = "x"
				end,
			}
			for _, write in badWrites do
				expect(server:Update(player, write)).to.equal(false)
			end

			local data = server:Get(player)
			expect(data.Coins).to.equal(0)
			expect(data.Name).to.equal("a")
			expect(data.Color).to.equal(nil)
			expect(#data.Items).to.equal(0)
			expect(server._pendingBatches[player]).to.equal(nil)

			server:Destroy()
		end)

		it("rejects keys that can't be replicated", function()
			local server = makeServer({})
			local player = makeFakePlayer()
			seed(server, player, {})

			expect(server:Update(player, function(data)
				data["a.b"] = 1
			end)).to.equal(false)
			expect(server:Update(player, function(data)
				data[1] = 1
			end)).to.equal(false)
			expect(server:Get(player)["a.b"]).to.equal(nil)

			server:Destroy()
		end)
	end)

	describe("Server privatePaths", function()
		it("keeps private paths out of snapshots and updates", function()
			local server = makeServer({}, nil, {
				privatePaths = {
					function(data)
						return data.Receipts
					end,
					function(data)
						return data.Admin.Notes
					end,
				},
			})
			local player = makeFakePlayer()
			local data = { Coins = 0, Receipts = { a = true }, Admin = { Notes = "x", Rank = 1 } }
			seed(server, player, data)

			local snapshot = server:_waitForData(player)
			expect(snapshot.data.Receipts).to.equal(nil)
			expect(snapshot.data.Admin.Notes).to.equal(nil)
			expect(snapshot.data.Admin.Rank).to.equal(1)
			expect(data.Receipts.a).to.equal(true)

			server:Update(player, function(draft)
				draft.Receipts.b = true
			end)
			expect(server._pendingBatches[player]).to.equal(nil)

			server:Update(player, function(draft)
				draft.Admin = { Notes = "y", Rank = 2 }
			end)
			local batch = server._pendingBatches[player]
			expect(#batch).to.equal(1)
			expect(batch[1][2]).to.equal("Admin.Rank")
			expect(server:Get(player).Admin.Notes).to.equal("y")

			server:Destroy()
		end)

		it("still mirrors leaderstats derived from private paths", function()
			local server = makeServer({ Stats = { Wins = 0 } }, {
				{
					name = "Wins",
					type = "IntValue",
					value = function(data)
						return data.Stats.Wins
					end,
				},
			}, {
				privatePaths = {
					function(data)
						return data.Stats
					end,
				},
			})
			local player = makeFakePlayer()
			seed(server, player, { Stats = { Wins = 0 } })
			server:_buildLeaderstats(player)

			server:Update(player, function(data)
				data.Stats.Wins += 1
			end)
			expect(server._pendingBatches[player]).to.equal(nil)
			server:_flushUpdates()

			expect(player.leaderstats.Wins.Value).to.equal(1)

			server:Destroy()
		end)

		it("rejects a selector that doesn't return a field", function()
			local ok = pcall(function()
				makeServer({}, nil, {
					privatePaths = {
						function()
							return 1
						end,
					},
				}):Destroy()
			end)
			expect(ok).to.equal(false)
		end)
	end)

	describe("Server:Update", function()
		it("edits data as plain Luau and leaves untouched sections in place", function()
			local server = makeServer({})
			local player = makeFakePlayer()
			local live = { Coins = 100, Items = {}, Stats = { Wins = 1 }, Settings = { Music = true } }
			seed(server, player, live)
			local settings = live.Settings

			expect(server:Update(player, function(data)
				data.Coins -= 40
				table.insert(data.Items, "Sword")
				data.Stats.Wins += 1
				expect(#data.Items).to.equal(1)
				local keys = 0
				for _ in data do
					keys += 1
				end
				expect(keys).to.equal(4)
			end)).to.equal(true)

			local data = server:Get(player)
			expect(data.Coins).to.equal(60)
			expect(data.Items[1]).to.equal("Sword")
			expect(data.Stats.Wins).to.equal(2)
			expect(data.Settings).to.equal(settings)

			server:Destroy()
		end)

		it("discards the draft when the transform errors, aborts, or yields", function()
			local server = makeServer({})
			local player = makeFakePlayer()
			seed(server, player, { Coins = 100, Items = { "Sword" } })

			local aborts = {
				function()
					error("boom")
				end,
				function()
					return false
				end,
				function()
					task.wait()
				end,
			}
			for _, abort in aborts do
				expect(server:Update(player, function(data)
					data.Coins = 0
					table.remove(data.Items, 1)
					return abort()
				end)).to.equal(false)
			end

			expect(server:Get(player).Coins).to.equal(100)
			expect(server:Get(player).Items[1]).to.equal("Sword")
			expect(server._pendingBatches[player]).to.equal(nil)

			server:Destroy()
		end)

		it("does not alias tables assigned into data", function()
			local server = makeServer({})
			local player = makeFakePlayer()
			seed(server, player, {})
			local defaults = { Music = true }

			server:Update(player, function(data)
				data.Settings = defaults
			end)
			defaults.Music = false

			expect(server:Get(player).Settings.Music).to.equal(true)

			server:Destroy()
		end)

		it("rejects a draft used after its Update returns", function()
			local server = makeServer({})
			local player = makeFakePlayer()
			seed(server, player, { Inventory = {} })

			local saved
			server:Update(player, function(data)
				saved = data
			end)

			expect(function()
				saved.Inventory.Gold = 999
			end).to.throw()
			expect(server:Get(player).Inventory.Gold).to.equal(nil)

			server:Destroy()
		end)

		it("passes validate a plain table", function()
			local seenKeys = 0
			local server = makeServer({}, nil, {
				validate = function(data)
					seenKeys = 0
					for _ in pairs(data) do
						seenKeys += 1
					end
					return true
				end,
			})
			local player = makeFakePlayer()
			seed(server, player, { Coins = 0, Stats = { Wins = 0 } })

			server:Update(player, function(data)
				data.Coins = 1
			end)
			expect(seenKeys).to.equal(2)

			server:Destroy()
		end)

		it("errors when nested inside another Update", function()
			local server = makeServer({})
			local player = makeFakePlayer()
			seed(server, player, { Coins = 0 })

			local nestedOk = nil
			server:Update(player, function()
				nestedOk = pcall(function()
					server:Update(player, function() end)
				end)
				return false
			end)
			expect(nestedOk).to.equal(false)

			server:Destroy()
		end)

		it("returns false for a player without loaded data", function()
			local server = makeServer({})
			expect(server:Update(makeFakePlayer(), function() end)).to.equal(false)
			server:Destroy()
		end)

		it("runs config.validate before committing", function()
			local server = makeServer({ Coins = 0 }, nil, {
				validate = function(data)
					return data.Coins >= 0, "Coins must not be negative"
				end,
			})
			local player = makeFakePlayer()
			seed(server, player, { Coins = 10 })

			expect(server:Update(player, function(data)
				data.Coins -= 20
			end)).to.equal(false)
			expect(server:Update(player, function(data)
				data.Coins -= 5
			end)).to.equal(true)
			expect(server:Get(player).Coins).to.equal(5)

			server:Destroy()
		end)

		it("fails profile preparation when config.validate rejects loaded data", function()
			local server = makeServer({ Coins = 0 }, nil, {
				validate = function(data)
					return data.Coins ~= nil, "missing Coins"
				end,
			})
			local player = makeFakePlayer()
			local profile = {
				Data = {},
				RobloxMetaData = {},
				SessionLoadCount = 2,
				Reconcile = function() end,
			}

			local ok, reason = server:_prepareProfile(player, profile, "Player_1")
			expect(ok).to.equal(false)
			expect(reason).to.equal("missing Coins")

			server:Destroy()
		end)

		it("fires Changed after commit, and listener updates are kept", function()
			local server = makeServer({})
			local player = makeFakePlayer()
			seed(server, player, { Crates = 0, Gems = 100 })

			local seen = {}
			server.Changed:Connect(function(changedPlayer, data)
				expect(changedPlayer).to.equal(player)
				table.insert(seen, data.Gems)
				if data.Crates == 1 and data.Gems == 50 then
					server:Update(player, function(draft)
						draft.Gems += 10
					end)
				end
			end)

			server:Update(player, function(data)
				data.Crates += 1
				data.Gems -= 50
			end)
			server:Update(player, function() end)

			expect(#seen).to.equal(2)
			expect(seen[1]).to.equal(50)
			expect(server:Get(player).Gems).to.equal(60)

			server:Destroy()
		end)
	end)

	describe("Server:UpdateMany", function()
		it("trades between players atomically", function()
			local server = makeServer({})
			local alice = makeFakePlayer()
			local bob = makeFakePlayer()
			seed(server, alice, { Items = { "Sword" }, Coins = 0 })
			seed(server, bob, { Items = {}, Coins = 50 })

			expect(server:UpdateMany({ alice, bob }, function(drafts)
				table.insert(drafts[bob].Items, table.remove(drafts[alice].Items, 1))
				drafts[bob].Coins -= 50
				drafts[alice].Coins += 50
			end)).to.equal(true)

			expect(#server:Get(alice).Items).to.equal(0)
			expect(server:Get(bob).Items[1]).to.equal("Sword")
			expect(server:Get(alice).Coins).to.equal(50)
			expect(server:Get(bob).Coins).to.equal(0)

			server:Destroy()
		end)

		it("changes nobody when one side fails", function()
			local server = makeServer({ Coins = 0 }, nil, {
				validate = function(data)
					return data.Coins >= 0
				end,
			})
			local alice = makeFakePlayer()
			local bob = makeFakePlayer()
			local offline = makeFakePlayer()
			seed(server, alice, { Coins = 0 })
			seed(server, bob, { Coins = 10 })

			expect(server:UpdateMany({ alice, bob }, function(drafts)
				drafts[alice].Coins += 50
				drafts[bob].Coins -= 50
			end)).to.equal(false)
			expect(server:UpdateMany({ alice, offline }, function(drafts)
				drafts[alice].Coins += 50
			end)).to.equal(false)

			expect(server:Get(alice).Coins).to.equal(0)
			expect(server:Get(bob).Coins).to.equal(10)
			expect(server._pendingBatches[alice]).to.equal(nil)

			server:Destroy()
		end)
	end)

	describe("Server session start", function()
		it("does not load players when autoLoadPlayers is false", function()
			local server = makeServer()
			-- Only the PlayerRemoving cleanup connection is bound.
			expect(#server._connections).to.equal(1)
			server:Destroy()
		end)

		it("fails the load cleanly when StartSessionAsync throws", function()
			local store = {
				StartSessionAsync = function()
					error("datastore exploded")
				end,
			}
			local server = Server.new({ storeName = "Throwing", template = {}, store = store })
			local kicked = false
			local player = {
				UserId = 7,
				Parent = nil,
				Kick = function()
					kicked = true
				end,
			}
			server.GetKey = function()
				return "Player_7"
			end

			local failure = nil
			server.ProfileLoadFailed:Connect(function(_, reason)
				failure = reason
			end)
			server:_onPlayerAdded(player)

			expect(failure).to.be.ok()
			expect(string.find(failure, "datastore exploded", 1, true)).to.be.ok()
			expect(kicked).to.equal(false) -- already gone, so no kick
			expect(server._profiles[player]).to.equal(nil)

			server:Destroy()
		end)
	end)

	describe("Server messages", function()
		it("sends savable messages through the store", function()
			local sent = {}
			local store = {
				MessageAsync = function(_, key, message)
					table.insert(sent, { key = key, message = message })
					return true
				end,
			}
			local server = Server.new({ storeName = "Messages", template = {}, store = store })

			expect(server:SendMessageAsync(42, { Gift = 10 })).to.equal(true)
			expect(server:SendMessageAsync(42, { Gift = 0 / 0 })).to.equal(false)
			expect(#sent).to.equal(1)
			expect(sent[1].key).to.equal("Player_42")

			server:Destroy()
		end)

		it("delivers messages to handlers until disconnected", function()
			local server = makeServer({})
			local player = makeFakePlayer()
			local profile = seed(server, player, { Coins = 0 })
			local profileHandlers = {}
			profile.MessageHandler = function(_, fn)
				table.insert(profileHandlers, fn)
			end

			local received = {}
			local disconnect = server:OnMessage(function(fromPlayer, message, processed)
				table.insert(received, message)
				expect(fromPlayer).to.equal(player)
				processed()
			end)
			expect(#profileHandlers).to.equal(1)

			local processedCount = 0
			profileHandlers[1]({ Gift = 5 }, function()
				processedCount += 1
			end)
			disconnect()
			profileHandlers[1]({ Gift = 6 }, function()
				processedCount += 1
			end)

			expect(#received).to.equal(1)
			expect(received[1].Gift).to.equal(5)
			expect(processedCount).to.equal(1)

			server:Destroy()
		end)
	end)

	describe("Server developer experience helpers", function()
		local function makeInjectedStore()
			local savedVersion = nil
			local currentProfile = nil
			local versions = {
				{
					Data = { Coins = 300 },
					KeyInfo = { Version = "v3", UpdatedTime = 3000 },
				},
				{
					Data = { Coins = 200 },
					KeyInfo = { Version = "v2", UpdatedTime = 2000 },
				},
				{
					Data = { Coins = 100 },
					KeyInfo = { Version = "v1", UpdatedTime = 1000 },
				},
			}
			currentProfile = versions[1]
			for _, profile in versions do
				profile.RobloxMetaData = {}
				profile.UserIds = {}
				profile.SetAsync = function(self)
					savedVersion = self.KeyInfo.Version
					currentProfile = self
				end
			end

			local store = {}
			function store:VersionQuery()
				local index = 0
				return {
					NextAsync = function()
						index += 1
						return versions[index]
					end,
				}
			end
			function store:GetAsync(_key, version)
				if version == nil then
					return currentProfile
				end
				for _, profile in versions do
					if profile.KeyInfo.Version == version then
						return profile
					end
				end
				return nil
			end
			function store:RemoveAsync()
				return true
			end

			return store, function()
				return savedVersion
			end
		end

		it("accepts an injected store and exposes deterministic keys", function()
			local injected = makeInjectedStore()
			local server = Server.new({
				storeName = "Injected",
				template = {},
				store = injected,
				keyPrefix = "Account_",
			})

			expect(server:GetStore()).to.equal(injected)
			expect(server:GetKey(42)).to.equal("Account_42")
			expect(server:GetKey("Shared_Guild")).to.equal("Shared_Guild")

			server:Destroy()
		end)

		it("rejects ambiguous backend injection", function()
			local injected = makeInjectedStore()
			local bothOk = pcall(function()
				Server.new({
					storeName = "Ambiguous",
					template = {},
					store = injected,
					profileStore = {},
				})
			end)
			local mockOk = pcall(function()
				Server.new({
					storeName = "AmbiguousMock",
					template = {},
					store = injected,
					mode = "mock",
				})
			end)

			expect(bothOk).to.equal(false)
			expect(mockOk).to.equal(false)
		end)

		it("previews the previous save by default and rolls back exact versions", function()
			local injected, getSavedVersion = makeInjectedStore()
			local server = Server.new({
				storeName = "Rollback",
				template = {},
				store = injected,
			})

			local preview = server:PreviewRollbackAsync(42)
			expect(preview.version).to.equal("v2")
			expect(preview.data.Coins).to.equal(200)

			local fired = false
			server.RolledBack:Connect(function(result)
				fired = result.version == "v1"
			end)
			local exactPreview = server:PreviewRollbackAsync(42, { version = "v1" })
			expect(exactPreview.profile).to.equal(nil)
			exactPreview.data.Coins = 999 -- preview data is detached from the stored profile
			local applied = server:ApplyRollbackAsync(exactPreview)
			expect(applied.version).to.equal("v1")
			expect(applied.data.Coins).to.equal(100)
			expect(getSavedVersion()).to.equal("v1")
			expect(fired).to.equal(true)
			expect(pcall(function()
				server:ApplyRollbackAsync(exactPreview)
			end)).to.equal(false)

			server:Destroy()
		end)

		it("retires a matching live session before reporting rollback completion", function()
			local injected = makeInjectedStore()
			local server = Server.new({
				storeName = "OnlineRollback",
				template = {},
				store = injected,
			})
			local player = makeFakePlayer()
			local live = makeFakeProfile({ Coins = 999 })
			live.Key = "Player_42"
			local ended = false
			live.EndSession = function()
				ended = true
				live.OnSessionEnd:Fire()
				live.OnAfterSave:Fire(live.Data)
			end
			server._profiles[player] = live
			server._profileConnections[player] = {
				live.OnSessionEnd:Connect(function()
					server:_releaseProfile(player, live, false)
				end),
			}

			local result = server:RollbackAsync(42, { version = "v1" })

			expect(result.version).to.equal("v1")
			expect(ended).to.equal(true)
			expect(server._profiles[player]).to.equal(nil)

			server:Destroy()
		end)

		it("keeps a preview reusable when rollback verification fails", function()
			local injected = makeInjectedStore()
			local historical = injected:GetAsync("Player_42", "v1")
			historical.SetAsync = function() end
			local server = Server.new({
				storeName = "FailedRollback",
				template = {},
				store = injected,
			})
			local preview = server:PreviewRollbackAsync(42, { version = "v1" })

			expect(pcall(function()
				server:ApplyRollbackAsync(preview)
			end)).to.equal(false)
			expect(server._rollbackPreviews[preview]).to.be.ok()

			server:Destroy()
		end)

		it("tracks migrations in profile metadata and skips history for new profiles", function()
			local injected = makeInjectedStore()
			local server = Server.new({
				storeName = "Migrations",
				template = {},
				store = injected,
				migrations = {
					{
						name = "coins",
						up = function(data)
							data.Currency = data.Currency or {}
							data.Currency.Coins = data.Currency.Coins or data.LegacyCoins or 0
							data.LegacyCoins = nil
						end,
					},
				},
			})
			local player = makeFakePlayer()
			local oldProfile = {
				Data = { LegacyCoins = 25 },
				RobloxMetaData = {},
				SessionLoadCount = 3,
				Reconcile = function(self)
					self.Data.Currency = self.Data.Currency or {}
					self.Data.Currency.Coins = self.Data.Currency.Coins or 0
				end,
			}
			local newProfile = {
				Data = { LegacyCoins = 50 },
				RobloxMetaData = {},
				SessionLoadCount = 1,
			}

			local ok = server:_prepareProfile(player, oldProfile, "Player_1")
			local newOk = server:_migrateProfile(player, newProfile, "Player_2")

			expect(ok).to.equal(true)
			expect(oldProfile.Data.Currency.Coins).to.equal(25)
			expect(oldProfile.RobloxMetaData.EZProfileStoreVersion).to.equal(1)
			expect(newOk).to.equal(true)
			expect(newProfile.Data.LegacyCoins).to.equal(50)
			expect(newProfile.RobloxMetaData.EZProfileStoreVersion).to.equal(1)

			server:Destroy()
		end)
	end)
end
