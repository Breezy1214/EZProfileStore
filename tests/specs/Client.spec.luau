local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PackageRoot = ReplicatedStorage.Packages.EZProfileStore
local Client = require(PackageRoot.Client)
local Shared = require(PackageRoot.Shared)
local Fusion = require(PackageRoot.Parent.Fusion)

local function makeClient(initial: { [any]: any }?): any
	local scope = Fusion.scoped(Fusion)
	local self: any = setmetatable({
		_dataValue = scope:Value(nil),
		_seq = 0,
		_pendingBatches = {},
		_pendingEntryCount = 0,
		_overflowWarned = false,
		_connections = {},
		_scope = scope,
		_rejectedReason = nil,
		_resolveReady = function() end,
		_isDestroyed = false,
	}, { __index = Client })

	self._rejectReady = function(reason)
		self._rejectedReason = reason
	end
	if initial ~= nil then
		self:_handleInit({ seq = 0, data = initial })
	end
	return self
end

return function()
	describe("Client._applyBatch", function()
		it("applies set, del, and ins ops", function()
			local c = makeClient({ Coins = 0, Flag = true, Items = {} })
			c:_applyBatch({
				{ Shared.OP.Set, "Coins", 100 },
				{ Shared.OP.Del, "Flag" },
				{ Shared.OP.Ins, "Items", "Sword" },
			})
			local data = c:Get()
			expect(data.Coins).to.equal(100)
			expect(data.Flag).to.equal(nil)
			expect(data.Items[1]).to.equal("Sword")
		end)

		it("keeps data frozen and reuses untouched subtrees", function()
			local c = makeClient({ Stats = { Wins = 0 }, Settings = { Music = true } })
			local before = c:Get()
			c:_applyBatch({ { Shared.OP.Set, "Stats.Wins", 1 }, { Shared.OP.Set, "Stats.Best", { Score = 5 } } })
			local after = c:Get()

			expect(after).never.to.equal(before)
			expect(after.Settings).to.equal(before.Settings)
			expect(table.isfrozen(after)).to.equal(true)
			expect(table.isfrozen(after.Stats)).to.equal(true)
			expect(table.isfrozen(after.Stats.Best)).to.equal(true)
			expect(table.isfrozen(before.Stats)).to.equal(true)
			expect(before.Stats.Wins).to.equal(0)
		end)
		it("applies several ops to the same table in one batch", function()
			local c = makeClient({ Items = {} })
			c:_applyBatch({
				{ Shared.OP.Set, "A", { x = 1 } },
				{ Shared.OP.Set, "A.x", 2 },
				{ Shared.OP.Ins, "Items", "a" },
				{ Shared.OP.Ins, "Items", "b" },
			})
			local data = c:Get()
			expect(data.A.x).to.equal(2)
			expect(#data.Items).to.equal(2)
			expect(table.isfrozen(data.A)).to.equal(true)
			expect(table.isfrozen(data.Items)).to.equal(true)
		end)
	end)

	describe("Client:Select", function()
		it("reads the selected value and observes only its changes", function()
			local c = makeClient({ Coins = 0, Stats = { Wins = 0 } })
			local stats = c:Select(function(data)
				return data.Stats
			end)
			local coins = c:Select(function(data)
				return data.Coins
			end)
			expect(coins:Get()).to.equal(0)

			local statChanges = 0
			local seen = {}
			stats:Observe(function()
				statChanges += 1
			end)
			coins:Observe(function(new, old)
				table.insert(seen, { new = new, old = old })
			end)

			c:_applyBatch({ { Shared.OP.Set, "Coins", 5 } })
			expect(coins:Get()).to.equal(5)
			expect(#seen).to.equal(1)
			expect(seen[1].new).to.equal(5)
			expect(seen[1].old).to.equal(0)
			expect(statChanges).to.equal(0)

			c:_applyBatch({ { Shared.OP.Set, "Stats.Wins", 1 } })
			expect(statChanges).to.equal(1)
			expect(#seen).to.equal(1)

			local stopObserving = stats:Observe(function()
				statChanges += 100
			end)
			stopObserving()
			c:_applyBatch({ { Shared.OP.Set, "Stats.Wins", 2 } })
			expect(statChanges).to.equal(2)

			stats:Destroy()
			coins:Destroy()
			c:_applyBatch({ { Shared.OP.Set, "Coins", 6 } })
			expect(#seen).to.equal(1)
		end)

		it("selects nil until data loads", function()
			local c = makeClient(nil)
			local coins = c:Select(function(data)
				return data.Coins
			end)
			expect(coins:Get()).to.equal(nil)

			local seen = nil
			coins:Observe(function(new)
				seen = new
			end)
			c:_handleInit({ seq = 0, data = { Coins = 3 } })
			expect(seen).to.equal(3)
			coins:Destroy()
		end)
	end)

	describe("Client sequencing", function()
		it("drops buffered batches already contained in the snapshot", function()
			local c = makeClient(nil)
			local resolved = nil
			c._resolveReady = function(data)
				resolved = data
			end

			c:_handleUpdate(1, { { Shared.OP.Ins, "Items", "Sword" } })
			c:_handleUpdate(2, { { Shared.OP.Ins, "Items", "Shield" } })
			c:_handleInit({ seq = 1, data = { Items = { "Sword" } } })

			local items = c:Get().Items
			expect(resolved).to.equal(c:Get())
			expect(#items).to.equal(2)
			expect(items[1]).to.equal("Sword")
			expect(items[2]).to.equal("Shield")
			expect(c._seq).to.equal(2)
		end)

		it("skips malformed entries without dropping the rest of the batch", function()
			local c = makeClient({ Coins = 0 })
			c:_handleUpdate(1, { "junk", 5, { Shared.OP.Set, "Coins", 7 } })
			expect(c:Get().Coins).to.equal(7)
		end)

		it("ignores stale batches after initialization", function()
			local c = makeClient({ Coins = 5 })
			c._seq = 3

			c:_handleUpdate(3, { { Shared.OP.Set, "Coins", 1 } })
			expect(c:Get().Coins).to.equal(5)

			c:_handleUpdate(4, { { Shared.OP.Set, "Coins", 9 } })
			expect(c:Get().Coins).to.equal(9)
		end)
	end)

	describe("Client._rejectInit", function()
		it("rejects readiness when the snapshot cannot be loaded", function()
			local c = makeClient(nil)

			c:_rejectInit("snapshot failed")

			expect(c._rejectedReason).to.equal("snapshot failed")
		end)

		it("does not reject after the snapshot is initialized", function()
			local c = makeClient({ Coins = 0 })

			c:_rejectInit("snapshot failed")

			expect(c._rejectedReason).to.equal(nil)
		end)
	end)
end
