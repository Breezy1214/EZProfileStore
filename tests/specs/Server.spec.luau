local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PackageRoot = ReplicatedStorage.Packages.EZProfileStore
local Path = require(PackageRoot.Path)
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
local P = Path.tree({})

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
		it("UpdateData emits a 'set' opcode entry", function()
			local server = makeServer()
			local player = makeFakePlayer()
			seed(server, player, { Coins = 0 })

			server:UpdateData(player, P.Coins, 100)
			local batch = server._pendingBatches[player]
			expect(#batch).to.equal(1)
			expect(batch[1][1]).to.equal(Shared.OP.Set)
			expect(batch[1][2]).to.equal("Coins")
			expect(batch[1][3]).to.equal(100)

			server:Destroy()
		end)

		it("UpdateData with nil emits a 'del' opcode entry", function()
			local server = makeServer()
			local player = makeFakePlayer()
			seed(server, player, { Flag = true })

			server:UpdateData(player, P.Flag, nil)
			local batch = server._pendingBatches[player]
			expect(batch[1][1]).to.equal(Shared.OP.Del)
			expect(batch[1][2]).to.equal("Flag")
			expect(batch[1][3]).to.equal(nil)

			server:Destroy()
		end)

		it("InsertData emits an 'ins' opcode entry", function()
			local server = makeServer({ Items = {} })
			local player = makeFakePlayer()
			seed(server, player, { Items = {} })

			server:InsertData(player, P.Items, "Sword")
			local batch = server._pendingBatches[player]
			expect(batch[1][1]).to.equal(Shared.OP.Ins)
			expect(batch[1][2]).to.equal("Items")
			expect(batch[1][3]).to.equal("Sword")

			server:Destroy()
		end)

		it("_waitForData seals the open batch under the snapshot sequence", function()
			local server = makeServer({ Items = {} })
			local player = makeFakePlayer()
			seed(server, player, { Items = {} })

			server:InsertData(player, P.Items, "Sword")
			expect(#server._pendingBatches[player]).to.equal(1)
			expect(server._sequences[player]).to.equal(1)

			local snapshot = server:_waitForData(player)

			expect(snapshot.seq).to.equal(1)
			expect(snapshot.data.Items[1]).to.equal("Sword")
			expect(server._pendingBatches[player]).to.equal(nil)

			server:InsertData(player, P.Items, "Shield")
			expect(server._sequences[player]).to.equal(2)

			server:Destroy()
		end)

		it("starts a new sequence number only when a new batch opens", function()
			local server = makeServer({ A = 0, B = 0 })
			local player = makeFakePlayer()
			seed(server, player, { A = 0, B = 0 })

			server:UpdateData(player, P.A, 1)
			server:UpdateData(player, P.B, 1)
			expect(server._sequences[player]).to.equal(1)

			server:_flushUpdates()
			server:UpdateData(player, P.A, 2)
			expect(server._sequences[player]).to.equal(2)

			server:Destroy()
		end)

		it("copies table payloads at queue time so later writes are not replayed twice", function()
			local server = makeServer({})
			local player = makeFakePlayer()
			seed(server, player, {})

			server:UpdateData(player, P.Items, {})
			server:InsertData(player, P.Items, "Sword")

			local batch = server._pendingBatches[player]
			expect(#batch[1][3]).to.equal(0)
			expect(batch[2][1]).to.equal(Shared.OP.Ins)
			expect(#server:GetData(player).Items).to.equal(1)

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

	describe("Server:IncrementData", function()
		it("adds delta to existing numeric path", function()
			local server = makeServer()
			local player = makeFakePlayer()
			seed(server, player, { Coins = 50 })

			expect(server:IncrementData(player, P.Coins, 25)).to.equal(true)
			expect(server:GetData(player).Coins).to.equal(75)

			server:Destroy()
		end)

		it("treats nil path as 0", function()
			local server = makeServer()
			local player = makeFakePlayer()
			seed(server, player, {})

			expect(server:IncrementData(player, P.NewStat, 10)).to.equal(true)
			expect(server:GetData(player).NewStat).to.equal(10)

			server:Destroy()
		end)

		it("returns false on non-numeric existing value", function()
			local server = makeServer()
			local player = makeFakePlayer()
			seed(server, player, { Name = "Bob" })

			expect(server:IncrementData(player, P.Name, 1)).to.equal(false)
			expect(server:GetData(player).Name).to.equal("Bob")

			server:Destroy()
		end)
	end)

	describe("Server:RemoveData", function()
		it("sets the path to nil and queues a 'del' op", function()
			local server = makeServer()
			local player = makeFakePlayer()
			seed(server, player, { Flag = true })

			expect(server:RemoveData(player, P.Flag)).to.equal(true)
			expect(server:GetData(player).Flag).to.equal(nil)

			local batch = server._pendingBatches[player]
			expect(batch[1][1]).to.equal(Shared.OP.Del)
			expect(batch[1][2]).to.equal("Flag")

			server:Destroy()
		end)

		it("returns false on already-nil path", function()
			local server = makeServer()
			local player = makeFakePlayer()
			seed(server, player, {})

			expect(server:RemoveData(player, P.Missing)).to.equal(false)

			server:Destroy()
		end)
	end)

	describe("Server:UpdateArrayItem", function()
		it("replaces the value at index", function()
			local server = makeServer()
			local player = makeFakePlayer()
			seed(server, player, { Items = { "a", "b", "c" } })

			expect(server:UpdateArrayItem(player, P.Items, 2, "B")).to.equal(true)
			expect(server:GetData(player).Items[2]).to.equal("B")

			local batch = server._pendingBatches[player]
			expect(batch[1][1]).to.equal(Shared.OP.AUpd)
			expect(batch[1][2]).to.equal("Items")
			expect(batch[1][3]).to.equal(2)
			expect(batch[1][4]).to.equal("B")

			server:Destroy()
		end)
	end)

	describe("Server:RemoveArrayItem", function()
		it("removes the item at index and shrinks length", function()
			local server = makeServer()
			local player = makeFakePlayer()
			seed(server, player, { Items = { "a", "b", "c" } })

			expect(server:RemoveArrayItem(player, P.Items, 2)).to.equal(true)
			local items = server:GetData(player).Items
			expect(#items).to.equal(2)
			expect(items[2]).to.equal("c")

			local batch = server._pendingBatches[player]
			expect(batch[1][1]).to.equal(Shared.OP.ARm)
			expect(batch[1][2]).to.equal("Items")
			expect(batch[1][3]).to.equal(2)

			server:Destroy()
		end)
	end)

	describe("Server:BatchSetValues", function()
		it("applies all writes and returns the number of changes", function()
			local server = makeServer()
			local player = makeFakePlayer()
			seed(server, player, { Coins = 0, Gems = 0, Level = 1 })

			local count = server:BatchSetValues(player, {
				Path.write(P.Coins, 50),
				Path.write(P.Gems, 10),
				Path.write(P.Level, 1), -- no-op (same value)
			})

			expect(count).to.equal(2)
			expect(server:GetData(player).Coins).to.equal(50)
			expect(server:GetData(player).Gems).to.equal(10)

			server:Destroy()
		end)

		it("coalesces all writes into a single batch in one frame", function()
			local server = makeServer()
			local player = makeFakePlayer()
			seed(server, player, { A = 0, B = 0, C = 0 })

			server:BatchSetValues(player, {
				Path.write(P.A, 1),
				Path.write(P.B, 2),
				Path.write(P.C, 3),
			})

			expect(#server._pendingBatches[player]).to.equal(3)

			server:Destroy()
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
			expect(server:GetData(player)).to.equal(nil)
			expect(server:GetProfileAsync(player, 0.01)).to.equal(nil)
			expect(server:GetDataAsync(player, 0.01)).to.equal(nil)

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
		it("rejects a path that doesn't exist in the template", function()
			local ok = pcall(function()
				Server.new({
					storeName = "BadPath_" .. tostring(math.random(1, 1e9)),
					template = { Coins = 0 },
					mode = "studio",
					leaderstats = {
						{ path = P.DoesNotExist, name = "Bad", type = "IntValue" },
					},
				})
			end)
			expect(ok).to.equal(false)
		end)

		it("rejects type/value class mismatch", function()
			local ok = pcall(function()
				Server.new({
					storeName = "BadType_" .. tostring(math.random(1, 1e9)),
					template = { Name = "Bob" },
					mode = "studio",
					leaderstats = {
						{ path = P.Name, name = "Name", type = "IntValue" },
					},
				})
			end)
			expect(ok).to.equal(false)
		end)
	end)

	describe("Server leaderstats Folder", function()
		it("creates a leaderstats Folder with declared Values seeded from data", function()
			local server = makeServer({ Coins = 0, Stats = { Wins = 0 } }, {
				{ path = P.Coins, name = "Coins", type = "IntValue" },
				{ path = P.Stats.Wins, name = "Wins", type = "IntValue" },
			})
			local player = makeFakePlayer()
			seed(server, player, { Coins = 25, Stats = { Wins = 3 } })

			server:_buildLeaderstats(player)

			local mirror = server._leaderstats[player]
			expect(mirror).to.be.ok()
			expect(mirror["Coins"].Value).to.equal(25)
			expect(mirror["Stats.Wins"].Value).to.equal(3)

			server:Destroy()
		end)
	end)

	describe("Server leaderstats mirror", function()
		it("updates the Value when a tracked path changes after flush", function()
			local server = makeServer({ Coins = 0 }, {
				{ path = P.Coins, name = "Coins", type = "IntValue" },
			})
			local player = makeFakePlayer()
			seed(server, player, { Coins = 0 })
			server:_buildLeaderstats(player)

			server:UpdateData(player, P.Coins, 100)
			server:_mirrorLeaderstats(player)

			expect(server._leaderstats[player]["Coins"].Value).to.equal(100)

			server:Destroy()
		end)

		it("updates the Value when a tracked subpath changes via parent write", function()
			local server = makeServer({ Stats = { Wins = 0, Losses = 0 } }, {
				{ path = P.Stats.Wins, name = "Wins", type = "IntValue" },
			})
			local player = makeFakePlayer()
			seed(server, player, { Stats = { Wins = 0, Losses = 0 } })
			server:_buildLeaderstats(player)

			server:UpdateData(player, P.Stats, { Wins = 7, Losses = 1 })
			server:_mirrorLeaderstats(player)

			expect(server._leaderstats[player]["Stats.Wins"].Value).to.equal(7)

			server:Destroy()
		end)
	end)

	describe("Server save-safety validation", function()
		it("rejects values DataStores cannot save", function()
			local server = makeServer({ Coins = 0 })
			local player = makeFakePlayer()
			seed(server, player, { Coins = 0, Name = "a" })

			expect(server:UpdateData(player, P.Coins, 0 / 0)).to.equal(false)
			expect(server:UpdateData(player, P.Coins, math.huge)).to.equal(false)
			expect(server:UpdateData(player, P.Name, "\255")).to.equal(false)
			expect(server:UpdateData(player, P.Color, workspace)).to.equal(false)
			-- selene: allow(mixed_table)
			expect(server:UpdateData(player, P.Mixed, { 1, Key = 2 })).to.equal(false)
			expect(server:InsertData(player, P.Items, workspace)).to.equal(false)
			expect(server:IncrementData(player, P.Coins, 0 / 0)).to.equal(false)

			local data = server:GetData(player)
			expect(data.Coins).to.equal(0)
			expect(data.Name).to.equal("a")
			expect(data.Color).to.equal(nil)
			expect(server._pendingBatches[player]).to.equal(nil)

			server:Destroy()
		end)

		it("rejects fractional array indices", function()
			local server = makeServer({ Items = {} })
			local player = makeFakePlayer()
			seed(server, player, { Items = { "a", "b" } })

			expect(server:UpdateArrayItem(player, P.Items, 1.5, "x")).to.equal(false)
			expect(server:RemoveArrayItem(player, P.Items, 1.5)).to.equal(false)
			expect(#server:GetData(player).Items).to.equal(2)

			server:Destroy()
		end)

		it("rejects anything that is not a Path", function()
			local server = makeServer({})
			local player = makeFakePlayer()
			seed(server, player, {})

			expect(function()
				server:UpdateData(player, "Coins", 1)
			end).to.throw()
			expect(function()
				server:ReadData(player, { "Coins" })
			end).to.throw()

			server:Destroy()
		end)
	end)

	describe("Server privatePaths", function()
		it("keeps private paths out of snapshots and updates", function()
			local server = makeServer({}, nil, { privatePaths = { P.Receipts, P.Admin.Notes } })
			local player = makeFakePlayer()
			local data = { Coins = 0, Receipts = { a = true }, Admin = { Notes = "x", Rank = 1 } }
			seed(server, player, data)

			local snapshot = server:_waitForData(player)
			expect(snapshot.data.Receipts).to.equal(nil)
			expect(snapshot.data.Admin.Notes).to.equal(nil)
			expect(snapshot.data.Admin.Rank).to.equal(1)
			expect(data.Receipts.a).to.equal(true)
			expect(data.Admin.Notes).to.equal("x")

			expect(server:UpdateData(player, P.Receipts.b, true)).to.equal(true)
			expect(server._pendingBatches[player]).to.equal(nil)

			server:UpdateData(player, P.Admin, { Notes = "y", Rank = 2 })
			local batch = server._pendingBatches[player]
			expect(#batch).to.equal(1)
			expect(batch[1][3].Rank).to.equal(2)
			expect(batch[1][3].Notes).to.equal(nil)
			expect(server:GetData(player).Admin.Notes).to.equal("y")

			server:Destroy()
		end)

		it("still mirrors leaderstats inside private paths", function()
			local server = makeServer({ Stats = { Wins = 0 } }, {
				{ path = P.Stats.Wins, name = "Wins", type = "IntValue" },
			}, { privatePaths = { P.Stats } })
			local player = makeFakePlayer()
			seed(server, player, { Stats = { Wins = 0 } })
			server:_buildLeaderstats(player)

			server:IncrementData(player, P.Stats.Wins)
			expect(server._pendingBatches[player]).to.equal(nil)
			server:_flushUpdates()

			expect(server._leaderstats[player]["Stats.Wins"].Value).to.equal(1)

			server:Destroy()
		end)
	end)

	describe("Server:Mutate", function()
		it("commits only the changed paths", function()
			local server = makeServer({})
			local player = makeFakePlayer()
			seed(server, player, { Coins = 100, Items = {}, Stats = { Wins = 1, Losses = 0 }, Old = true })

			local ok = server:Mutate(player, function(data)
				data.Coins -= 40
				table.insert(data.Items, "Sword")
				data.Stats.Wins += 1
				data.Old = nil
			end)

			expect(ok).to.equal(true)
			local data = server:GetData(player)
			expect(data.Coins).to.equal(60)
			expect(data.Items[1]).to.equal("Sword")
			expect(data.Stats.Wins).to.equal(2)
			expect(data.Old).to.equal(nil)

			local ops = {}
			for _, entry in server._pendingBatches[player] do
				ops[entry[2]] = entry[1]
			end
			expect(ops.Coins).to.equal(Shared.OP.Set)
			expect(ops.Items).to.equal(Shared.OP.Set)
			expect(ops["Stats.Wins"]).to.equal(Shared.OP.Set)
			expect(ops["Stats.Losses"]).to.equal(nil)
			expect(ops.Old).to.equal(Shared.OP.Del)

			server:Destroy()
		end)

		it("discards the draft when the transform errors, aborts, yields, or saves bad data", function()
			local server = makeServer({})
			local player = makeFakePlayer()
			seed(server, player, { Coins = 100 })

			local function spend(data)
				data.Coins = 0
			end
			expect(server:Mutate(player, function(data)
				spend(data)
				error("boom")
			end)).to.equal(false)
			expect(server:Mutate(player, function(data)
				spend(data)
				return false
			end)).to.equal(false)
			expect(server:Mutate(player, function(data)
				spend(data)
				task.wait()
			end)).to.equal(false)
			expect(server:Mutate(player, function(data)
				data.Coins = 0 / 0
			end)).to.equal(false)

			expect(server:GetData(player).Coins).to.equal(100)
			expect(server._pendingBatches[player]).to.equal(nil)

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

			expect(server:Mutate(player, function(data)
				data.Coins -= 20
			end)).to.equal(false)
			expect(server:Mutate(player, function(data)
				data.Coins -= 5
			end)).to.equal(true)
			expect(server:GetData(player).Coins).to.equal(5)

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

		it("fires DataUpdated after the whole commit so listener writes are kept", function()
			local server = makeServer({})
			local player = makeFakePlayer()
			seed(server, player, { Crates = { Opened = 0 }, Currency = { Gems = 100 } })

			local firstSeen = nil
			server.DataUpdated:Connect(function(_, keyPath)
				local data = server:GetData(player)
				if firstSeen == nil then
					firstSeen = { opened = data.Crates.Opened, gems = data.Currency.Gems }
				end
				if keyPath == "Crates.Opened" then
					server:IncrementData(player, P.Currency.Gems, 10)
				end
			end)

			expect(server:Mutate(player, function(data)
				data.Crates.Opened += 1
				data.Currency.Gems -= 50
			end)).to.equal(true)

			expect(firstSeen.opened).to.equal(1)
			expect(firstSeen.gems).to.equal(50)
			expect(server:GetData(player).Currency.Gems).to.equal(60)

			local replicated = {}
			for _, entry in server._pendingBatches[player] do
				replicated[entry[2]] = entry[3]
			end
			expect(replicated["Crates.Opened"]).to.equal(1)
			expect(replicated["Currency.Gems"]).to.equal(60)

			server:Destroy()
		end)
	end)

	describe("Server:MutateMany", function()
		it("trades between players atomically", function()
			local server = makeServer({})
			local alice = makeFakePlayer()
			local bob = makeFakePlayer()
			seed(server, alice, { Items = { "Sword" }, Coins = 0 })
			seed(server, bob, { Items = {}, Coins = 50 })

			local ok = server:MutateMany({ alice, bob }, function(drafts)
				table.insert(drafts[bob].Items, table.remove(drafts[alice].Items, 1))
				drafts[bob].Coins -= 50
				drafts[alice].Coins += 50
			end)

			expect(ok).to.equal(true)
			expect(#server:GetData(alice).Items).to.equal(0)
			expect(server:GetData(bob).Items[1]).to.equal("Sword")
			expect(server:GetData(alice).Coins).to.equal(50)
			expect(server:GetData(bob).Coins).to.equal(0)

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

			expect(server:MutateMany({ alice, bob }, function(drafts)
				drafts[alice].Coins += 50
				drafts[bob].Coins -= 50
			end)).to.equal(false)
			expect(server:MutateMany({ alice, offline }, function(drafts)
				drafts[alice].Coins += 50
			end)).to.equal(false)

			expect(server:GetData(alice).Coins).to.equal(0)
			expect(server:GetData(bob).Coins).to.equal(10)

			server:Destroy()
		end)
	end)

	describe("Server.DataUpdated", function()
		it("fires DataUpdated with the dot-joined key", function()
			local server = makeServer({})
			local player = makeFakePlayer()
			local Paths = Path.tree({ Stats = { Wins = 0 } })
			seed(server, player, { Stats = { Wins = 0 } })

			local seen = {}
			server.DataUpdated:Connect(function(_, key, value)
				table.insert(seen, { key = key, value = value })
			end)
			server:IncrementData(player, Paths.Stats.Wins)

			expect(seen[1].key).to.equal(Path.keyOf(Paths.Stats.Wins))
			expect(seen[1].value).to.equal(1)

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

	describe("Server:Transaction", function()
		local function setup(extra: { [string]: any }?)
			local server = makeServer({}, nil, extra)
			local alice = makeFakePlayer()
			local bob = makeFakePlayer()
			seed(server, alice, { Coins = 100, Items = { "Sword" }, Stats = { Wins = 1 } })
			seed(server, bob, { Coins = 0, Items = {}, Stats = { Wins = 0 } })
			return server, alice, bob
		end

		it("commits writes across players and replicates them in order", function()
			local server, alice, bob = setup()
			local events = {}
			server.DataUpdated:Connect(function(player, key)
				table.insert(events, { player = player, key = key })
			end)

			local ok = server:Transaction(function()
				server:IncrementData(alice, P.Coins, -50)
				server:IncrementData(bob, P.Coins, 50)
				server:InsertData(bob, P.Items, "Sword")
				server:RemoveArrayItem(alice, P.Items, 1)
				expect(#events).to.equal(0) -- held until commit
				expect(server._pendingBatches[alice]).to.equal(nil)
				return true
			end)

			expect(ok).to.equal(true)
			expect(server:GetData(alice).Coins).to.equal(50)
			expect(server:GetData(bob).Coins).to.equal(50)
			expect(server:GetData(bob).Items[1]).to.equal("Sword")
			expect(#server:GetData(alice).Items).to.equal(0)
			expect(#events).to.equal(4)
			expect(events[1].key).to.equal("Coins")
			expect(#server._pendingBatches[alice]).to.equal(2)
			expect(#server._pendingBatches[bob]).to.equal(2)

			server:Destroy()
		end)

		it("rolls back every kind of write on false, error, or yield", function()
			local server, alice = setup()
			local snapshot = Shared.deepCopy(server:GetData(alice))

			local aborts = {
				function()
					return false
				end,
				function()
					error("boom")
				end,
				function()
					task.wait()
				end,
			}
			for _, abort in aborts do
				local ok = server:Transaction(function()
					server:UpdateData(alice, P.Coins, 1)
					server:UpdateData(alice, P.New.Deep.Value, 1) -- creates parents
					server:UpdateData(alice, P.Stats, { Wins = 99 })
					server:IncrementData(alice, P.Stats.Wins)
					server:InsertData(alice, P.Items, "Bow")
					server:UpdateArrayItem(alice, P.Items, 1, "Axe")
					server:RemoveArrayItem(alice, P.Items, 2)
					server:RemoveData(alice, P.Coins)
					return abort()
				end)
				expect(ok).to.equal(false)
				expect(Shared.deepEqual(server:GetData(alice), snapshot)).to.equal(true)
			end

			expect(server._pendingBatches[alice]).to.equal(nil)
			server:Destroy()
		end)

		it("rolls back when config.validate rejects a touched player", function()
			local server, alice, bob = setup({
				validate = function(data)
					return data.Coins >= 0, "Coins must not be negative"
				end,
			})

			local warnings = {}
			local logConnection = game:GetService("LogService").MessageOut:Connect(function(message)
				table.insert(warnings, message)
			end)
			local ok = server:Transaction(function()
				server:IncrementData(bob, P.Coins, -10)
				server:IncrementData(alice, P.Coins, 10)
			end)
			task.wait()
			logConnection:Disconnect()

			local reported = false
			for _, message in warnings do
				if string.find(message, "Coins must not be negative", 1, true) then
					reported = true
				end
			end
			expect(reported).to.equal(true)
			expect(ok).to.equal(false)
			expect(server:GetData(alice).Coins).to.equal(100)
			expect(server:GetData(bob).Coins).to.equal(0)
			server:Destroy()
		end)

		it("treats nested transactions as savepoints", function()
			local server, alice = setup()

			local ok = server:Transaction(function()
				server:IncrementData(alice, P.Coins, 1)
				local inner = server:Transaction(function()
					server:IncrementData(alice, P.Coins, 1000)
					return false
				end)
				expect(inner).to.equal(false)
				expect(server:GetData(alice).Coins).to.equal(101)
				local kept = server:Transaction(function()
					server:IncrementData(alice, P.Stats.Wins)
				end)
				expect(kept).to.equal(true)
			end)

			expect(ok).to.equal(true)
			expect(server:GetData(alice).Coins).to.equal(101)
			expect(server:GetData(alice).Stats.Wins).to.equal(2)
			expect(#server._pendingBatches[alice]).to.equal(2)
			server:Destroy()
		end)

		it("includes Mutate writes and undoes them with the transaction", function()
			local server, alice = setup()

			local ok = server:Transaction(function()
				server:Mutate(alice, function(data)
					data.Coins = 0
					data.Stats.Wins = 50
				end)
				return false
			end)

			expect(ok).to.equal(false)
			expect(server:GetData(alice).Coins).to.equal(100)
			expect(server:GetData(alice).Stats.Wins).to.equal(1)
			server:Destroy()
		end)

		it("keeps payloads copied at write time", function()
			local server, alice = setup()
			local stats = { Wins = 5 }

			server:Transaction(function()
				server:UpdateData(alice, P.Stats, stats)
				server:IncrementData(alice, P.Stats.Wins)
			end)

			local batch = server._pendingBatches[alice]
			expect(batch[1][3].Wins).to.equal(5)
			expect(batch[2][3]).to.equal(6)
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
