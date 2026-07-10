local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PackageRoot = ReplicatedStorage.Packages.EZProfileStore
local Server = require(PackageRoot.Server)
local Shared = require(PackageRoot.Shared)
local Signal = require(PackageRoot.Parent.Signal)

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

local function makeServer(template: { [any]: any }?, leaderstats: { any }?)
	return Server.new({
		storeName = "TestStore_" .. tostring(math.random(1, 1e9)),
		template = template or { Coins = 0 },
		useMockInStudio = true,
		leaderstats = leaderstats,
	})
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

			server:UpdateData(player, "Coins", 100)
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

			server:UpdateData(player, "Flag", nil)
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

			server:InsertData(player, "Items", "Sword")
			local batch = server._pendingBatches[player]
			expect(batch[1][1]).to.equal(Shared.OP.Ins)
			expect(batch[1][2]).to.equal("Items")
			expect(batch[1][3]).to.equal("Sword")

			server:Destroy()
		end)

		it("_waitForData consumes pending updates already represented in the snapshot", function()
			local server = makeServer({ Items = {} })
			local player = makeFakePlayer()
			seed(server, player, { Items = {} })

			server:InsertData(player, "Items", "Sword")
			expect(#server._pendingBatches[player]).to.equal(1)

			local snapshot = server:_waitForData(player)

			expect(snapshot.Items[1]).to.equal("Sword")
			expect(server._pendingBatches[player]).to.equal(nil)

			server:Destroy()
		end)
	end)

	describe("Server:IncrementData", function()
		it("adds delta to existing numeric path", function()
			local server = makeServer()
			local player = makeFakePlayer()
			seed(server, player, { Coins = 50 })

			expect(server:IncrementData(player, "Coins", 25)).to.equal(true)
			expect(server:GetData(player).Coins).to.equal(75)

			server:Destroy()
		end)

		it("treats nil path as 0", function()
			local server = makeServer()
			local player = makeFakePlayer()
			seed(server, player, {})

			expect(server:IncrementData(player, "NewStat", 10)).to.equal(true)
			expect(server:GetData(player).NewStat).to.equal(10)

			server:Destroy()
		end)

		it("defaults delta to 1", function()
			local server = makeServer()
			local player = makeFakePlayer()
			seed(server, player, { Coins = 5 })

			expect(server:IncrementData(player, "Coins")).to.equal(true)
			expect(server:GetData(player).Coins).to.equal(6)

			server:Destroy()
		end)

		it("returns false on non-numeric existing value", function()
			local server = makeServer()
			local player = makeFakePlayer()
			seed(server, player, { Name = "Bob" })

			expect(server:IncrementData(player, "Name", 1)).to.equal(false)
			expect(server:GetData(player).Name).to.equal("Bob")

			server:Destroy()
		end)

		it("returns false when no profile loaded", function()
			local server = makeServer()
			local player = makeFakePlayer()

			expect(server:IncrementData(player, "Coins", 1)).to.equal(false)

			server:Destroy()
		end)
	end)

	describe("Server:DecrementData", function()
		it("subtracts delta", function()
			local server = makeServer()
			local player = makeFakePlayer()
			seed(server, player, { Coins = 100 })

			expect(server:DecrementData(player, "Coins", 30)).to.equal(true)
			expect(server:GetData(player).Coins).to.equal(70)

			server:Destroy()
		end)

		it("defaults delta to 1", function()
			local server = makeServer()
			local player = makeFakePlayer()
			seed(server, player, { Coins = 5 })

			expect(server:DecrementData(player, "Coins")).to.equal(true)
			expect(server:GetData(player).Coins).to.equal(4)

			server:Destroy()
		end)
	end)

	describe("Server:RemoveData", function()
		it("sets the path to nil and queues a 'del' op", function()
			local server = makeServer()
			local player = makeFakePlayer()
			seed(server, player, { Flag = true })

			expect(server:RemoveData(player, "Flag")).to.equal(true)
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

			expect(server:RemoveData(player, "Missing")).to.equal(false)

			server:Destroy()
		end)

		it("returns false when no profile loaded", function()
			local server = makeServer()
			local player = makeFakePlayer()
			expect(server:RemoveData(player, "Anything")).to.equal(false)
			server:Destroy()
		end)
	end)

	describe("Server:UpdateArrayItem", function()
		it("replaces the value at index", function()
			local server = makeServer()
			local player = makeFakePlayer()
			seed(server, player, { Items = { "a", "b", "c" } })

			expect(server:UpdateArrayItem(player, "Items", 2, "B")).to.equal(true)
			expect(server:GetData(player).Items[2]).to.equal("B")

			local batch = server._pendingBatches[player]
			expect(batch[1][1]).to.equal(Shared.OP.AUpd)
			expect(batch[1][2]).to.equal("Items")
			expect(batch[1][3]).to.equal(2)
			expect(batch[1][4]).to.equal("B")

			server:Destroy()
		end)

		it("returns false on out-of-bounds index", function()
			local server = makeServer()
			local player = makeFakePlayer()
			seed(server, player, { Items = { "a" } })

			expect(server:UpdateArrayItem(player, "Items", 5, "x")).to.equal(false)

			server:Destroy()
		end)

		it("returns false on non-array target", function()
			local server = makeServer()
			local player = makeFakePlayer()
			seed(server, player, { Stats = { Coins = 5 } })

			expect(server:UpdateArrayItem(player, "Stats", 1, "x")).to.equal(false)

			server:Destroy()
		end)
	end)

	describe("Server:RemoveArrayItem", function()
		it("removes the item at index and shrinks length", function()
			local server = makeServer()
			local player = makeFakePlayer()
			seed(server, player, { Items = { "a", "b", "c" } })

			expect(server:RemoveArrayItem(player, "Items", 2)).to.equal(true)
			local items = server:GetData(player).Items
			expect(#items).to.equal(2)
			expect(items[2]).to.equal("c")

			local batch = server._pendingBatches[player]
			expect(batch[1][1]).to.equal(Shared.OP.ARm)
			expect(batch[1][2]).to.equal("Items")
			expect(batch[1][3]).to.equal(2)

			server:Destroy()
		end)

		it("returns false on out-of-bounds index", function()
			local server = makeServer()
			local player = makeFakePlayer()
			seed(server, player, { Items = { "a" } })

			expect(server:RemoveArrayItem(player, "Items", 5)).to.equal(false)

			server:Destroy()
		end)

		it("returns false on non-array target", function()
			local server = makeServer()
			local player = makeFakePlayer()
			seed(server, player, { Stats = { Coins = 5 } })

			expect(server:RemoveArrayItem(player, "Stats", 1)).to.equal(false)

			server:Destroy()
		end)
	end)

	describe("Server:BatchSetValues", function()
		it("applies all writes and returns the number of changes", function()
			local server = makeServer()
			local player = makeFakePlayer()
			seed(server, player, { Coins = 0, Gems = 0, Level = 1 })

			local count = server:BatchSetValues(player, {
				{ path = "Coins", value = 50 },
				{ path = "Gems", value = 10 },
				{ path = "Level", value = 1 }, -- no-op (same value)
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
				{ path = "A", value = 1 },
				{ path = "B", value = 2 },
				{ path = "C", value = 3 },
			})

			expect(#server._pendingBatches[player]).to.equal(3)

			server:Destroy()
		end)

		it("returns 0 when no profile loaded", function()
			local server = makeServer()
			local player = makeFakePlayer()
			expect(server:BatchSetValues(player, { { path = "X", value = 1 } })).to.equal(0)
			server:Destroy()
		end)
	end)

	describe("Server:SaveAsync", function()
		it("calls profile:Save() and returns true", function()
			local server = makeServer()
			local player = makeFakePlayer()
			local profile = seed(server, player, { Coins = 1 })
			local saved = false
			profile.Save = function()
				saved = true
			end

			expect(server:SaveAsync(player)).to.equal(true)
			expect(saved).to.equal(true)

			server:Destroy()
		end)

		it("returns false when no profile loaded", function()
			local server = makeServer()
			local player = makeFakePlayer()
			expect(server:SaveAsync(player)).to.equal(false)
			server:Destroy()
		end)
	end)

	describe("Server:IsReady", function()
		it("returns true when profile is loaded", function()
			local server = makeServer()
			local player = makeFakePlayer()
			seed(server, player, {})

			expect(server:IsReady(player)).to.equal(true)

			server:Destroy()
		end)

		it("returns false when profile is not loaded", function()
			local server = makeServer()
			local player = makeFakePlayer()
			expect(server:IsReady(player)).to.equal(false)
			server:Destroy()
		end)

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

	describe("Server:WipeAsync", function()
		it("accepts a userId number", function()
			local server = makeServer()
			expect(server:WipeAsync(99999)).to.equal(true)
			server:Destroy()
		end)

		it("accepts negative mock UserIds", function()
			local server = makeServer()
			expect(server:WipeAsync(-42)).to.equal(true)
			server:Destroy()
		end)
	end)

	describe("Server save signals", function()
		it("PreSave fires when profile.OnSave fires", function()
			local server = makeServer()
			local player = makeFakePlayer()
			local profile = seed(server, player, { Coins = 0 })

			local conn = profile.OnSave:Connect(function()
				server.PreSave:Fire(player, profile.Data)
			end)

			local fired = false
			server.PreSave:Connect(function(p, data)
				expect(p).to.equal(player)
				expect(data).to.equal(profile.Data)
				fired = true
			end)

			profile.OnSave:Fire()
			expect(fired).to.equal(true)

			conn:Disconnect()
			server:Destroy()
		end)

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

		it("exposes PreSave, PostSave, LastSave signals", function()
			local server = makeServer()
			expect(server.PreSave).to.be.ok()
			expect(server.PostSave).to.be.ok()
			expect(server.LastSave).to.be.ok()
			expect(typeof(server.PreSave.Connect)).to.equal("function")
			server:Destroy()
		end)
	end)

	describe("Server.new leaderstats validation", function()
		it("accepts a valid leaderstats config", function()
			local server = makeServer({ Coins = 0, Stats = { Wins = 0 } }, {
				{ path = "Coins", name = "Coins", type = "IntValue" },
				{ path = "Stats.Wins", name = "Wins", type = "IntValue" },
			})
			expect(server).to.be.ok()
			server:Destroy()
		end)

		it("rejects a path that doesn't exist in the template", function()
			local ok = pcall(function()
				Server.new({
					storeName = "BadPath_" .. tostring(math.random(1, 1e9)),
					template = { Coins = 0 },
					useMockInStudio = true,
					leaderstats = {
						{ path = "DoesNotExist", name = "Bad", type = "IntValue" },
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
					useMockInStudio = true,
					leaderstats = {
						{ path = "Name", name = "Name", type = "IntValue" },
					},
				})
			end)
			expect(ok).to.equal(false)
		end)
	end)

	describe("Server leaderstats Folder", function()
		it("creates a leaderstats Folder with declared Values seeded from data", function()
			local server = makeServer({ Coins = 0, Stats = { Wins = 0 } }, {
				{ path = "Coins", name = "Coins", type = "IntValue" },
				{ path = "Stats.Wins", name = "Wins", type = "IntValue" },
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
				{ path = "Coins", name = "Coins", type = "IntValue" },
			})
			local player = makeFakePlayer()
			seed(server, player, { Coins = 0 })
			server:_buildLeaderstats(player)

			server:UpdateData(player, "Coins", 100)
			server:_mirrorLeaderstats(player)

			expect(server._leaderstats[player]["Coins"].Value).to.equal(100)

			server:Destroy()
		end)

		it("updates the Value when a tracked subpath changes via parent write", function()
			local server = makeServer({ Stats = { Wins = 0, Losses = 0 } }, {
				{ path = "Stats.Wins", name = "Wins", type = "IntValue" },
			})
			local player = makeFakePlayer()
			seed(server, player, { Stats = { Wins = 0, Losses = 0 } })
			server:_buildLeaderstats(player)

			server:UpdateData(player, "Stats", { Wins = 7, Losses = 1 })
			server:_mirrorLeaderstats(player)

			expect(server._leaderstats[player]["Stats.Wins"].Value).to.equal(7)

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

		it("creates an explicitly isolated mock store", function()
			local server = Server.mock({
				storeName = "ForcedMock_" .. tostring(math.random(1, 1e9)),
				template = { Coins = 0 },
			})

			expect(server.IsMock).to.equal(true)
			server:Destroy()
		end)

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
