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
	end)

	describe("Server:WipeAsync", function()
		it("accepts a userId number", function()
			local server = makeServer()
			expect(server:WipeAsync(99999)).to.equal(true)
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
end
