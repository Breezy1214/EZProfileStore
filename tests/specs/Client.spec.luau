local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PackageRoot = ReplicatedStorage.Packages.EZProfileStore
local Client = require(PackageRoot.Client)
local Shared = require(PackageRoot.Shared)
local Fusion = require(PackageRoot.Parent.Fusion)
local Signal = require(PackageRoot.Parent.Signal)

local function makeClient(initial: { [any]: any }?): any
	local scope = Fusion.scoped(Fusion)
	local self: any = setmetatable({
		_dataValue = scope:Value(initial),
		_seq = 0,
		_pendingBatches = {},
		_pendingEntryCount = 0,
		_overflowWarned = false,
		_connections = {},
		_scope = scope,
		_rejectedReason = nil,
		_rejectReady = function() end,
		_isDestroyed = false,
		Updated = Signal.new(),
	}, { __index = Client })

	self._rejectReady = function(reason)
		self._rejectedReason = reason
	end
	return self
end

return function()
	describe("Client._applyBatch", function()
		it("applies a set op", function()
			local c = makeClient({ Coins = 0 })
			c:_applyBatch({ { Shared.OP.Set, "Coins", 100 } }, false)
			expect(Fusion.peek(c._dataValue).Coins).to.equal(100)
		end)

		it("applies a del op", function()
			local c = makeClient({ Flag = true })
			c:_applyBatch({ { Shared.OP.Del, "Flag" } }, false)
			expect(Fusion.peek(c._dataValue).Flag).to.equal(nil)
		end)

		it("applies an ins op into an array", function()
			local c = makeClient({ Items = {} })
			c:_applyBatch({ { Shared.OP.Ins, "Items", "Sword" } }, false)
			expect(Fusion.peek(c._dataValue).Items[1]).to.equal("Sword")
		end)

		it("applies an aupd op", function()
			local c = makeClient({ Items = { "a", "b", "c" } })
			c:_applyBatch({ { Shared.OP.AUpd, "Items", 2, "B" } }, false)
			expect(Fusion.peek(c._dataValue).Items[2]).to.equal("B")
		end)

		it("applies an arm op", function()
			local c = makeClient({ Items = { "a", "b", "c" } })
			c:_applyBatch({ { Shared.OP.ARm, "Items", 2 } }, false)
			expect(#Fusion.peek(c._dataValue).Items).to.equal(2)
			expect(Fusion.peek(c._dataValue).Items[2]).to.equal("c")
		end)

		it("fires Updated once per entry when fireSignal is true", function()
			local c = makeClient({ A = 0, B = 0 })
			local fires = 0
			c.Updated:Connect(function()
				fires += 1
			end)
			c:_applyBatch({
				{ Shared.OP.Set, "A", 1 },
				{ Shared.OP.Set, "B", 2 },
			}, true)
			expect(fires).to.equal(2)
		end)
	end)

	describe("Client sequencing", function()
		it("drops buffered batches already contained in the snapshot", function()
			local c = makeClient(nil)
			c._resolveReady = function() end

			c:_handleUpdate(1, { { Shared.OP.Ins, "Items", "Sword" } })
			c:_handleUpdate(2, { { Shared.OP.Ins, "Items", "Shield" } })
			c:_handleInit({ seq = 1, data = { Items = { "Sword" } } })

			local items = Fusion.peek(c._dataValue).Items
			expect(#items).to.equal(2)
			expect(items[1]).to.equal("Sword")
			expect(items[2]).to.equal("Shield")
			expect(c._seq).to.equal(2)
		end)

		it("ignores stale batches after initialization", function()
			local c = makeClient({ Coins = 5 })
			c._seq = 3

			c:_handleUpdate(3, { { Shared.OP.Set, "Coins", 1 } })
			expect(Fusion.peek(c._dataValue).Coins).to.equal(5)

			c:_handleUpdate(4, { { Shared.OP.Set, "Coins", 9 } })
			expect(Fusion.peek(c._dataValue).Coins).to.equal(9)
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
