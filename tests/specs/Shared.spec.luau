local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PackageRoot = ReplicatedStorage.Packages.EZProfileStore
local Shared = require(PackageRoot.Shared)

return function()
	describe("Shared.deepEqual", function()
		it("compares nested profile data", function()
			expect(Shared.deepEqual({ Coins = 10, Items = { "a" } }, { Coins = 10, Items = { "a" } })).to.equal(true)
			expect(Shared.deepEqual({ Coins = 10 }, { Coins = 11 })).to.equal(false)
			expect(Shared.deepEqual({ Coins = 10 }, { Coins = 10, Gems = 1 })).to.equal(false)
		end)
	end)

	describe("Shared.validateValue", function()
		it("accepts savable nested data", function()
			expect(Shared.validateValue({ Coins = 1, Items = { "a", "b" }, Flags = { On = true }, Empty = {} })).to.equal(
				true
			)
			expect(Shared.validateValue(buffer.create(4))).to.equal(true)
		end)

		it("rejects values DataStores cannot encode", function()
			local cyclic = {}
			cyclic.Self = cyclic

			for _, value in { 0 / 0, math.huge, -math.huge, "\255", "\237\190\140", workspace, print, Vector3.zero } do
				expect(Shared.validateValue(value)).to.equal(false)
			end
			expect(Shared.validateValue({ Nested = { Bad = 0 / 0 } })).to.equal(false)
			expect(Shared.validateValue({ ["\255"] = 1 })).to.equal(false)
			-- selene: allow(mixed_table)
			expect(Shared.validateValue({ 1, Key = 2 })).to.equal(false)
			expect(Shared.validateValue({ [1] = 1, [3] = 3 })).to.equal(false)
			expect(Shared.validateValue({ [1.5] = 1 })).to.equal(false)
			expect(Shared.validateValue({ [workspace] = 1 })).to.equal(false)
			expect(Shared.validateValue(cyclic)).to.equal(false)
		end)

		it("names the offending path", function()
			local _, reason = Shared.validateValue({ Stats = { Wins = 0 / 0 } })
			expect(string.find(reason, "Stats.Wins", 1, true)).to.be.ok()
		end)
	end)

	describe("Shared.redact", function()
		it("removes paths without mutating the source", function()
			local source = { A = { Secret = 1, Public = 2 }, B = 3 }
			local result = Shared.redact(source, { { "A", "Secret" }, { "Missing", "Path" } })

			expect(result.A.Secret).to.equal(nil)
			expect(result.A.Public).to.equal(2)
			expect(result.B).to.equal(3)
			expect(source.A.Secret).to.equal(1)
		end)

		it("returns the same table when nothing is removed", function()
			local source = { A = 1 }
			expect(Shared.redact(source, { { "B" } })).to.equal(source)
		end)
	end)

	describe("Shared.diff", function()
		local function byPath(changes)
			local result = {}
			for _, change in changes do
				result[table.concat(change.path, ".")] = change
			end
			return result
		end

		it("recurses into dictionaries and replaces arrays whole", function()
			local changes = byPath(Shared.diff({
				Coins = 1,
				Stats = { Wins = 1, Losses = 0 },
				Items = { "a" },
				Gone = true,
			}, {
				Coins = 2,
				Stats = { Wins = 2, Losses = 0 },
				Items = { "a", "b" },
				New = { X = 1 },
			}))

			expect(changes.Coins.value).to.equal(2)
			expect(changes["Stats.Wins"].value).to.equal(2)
			expect(changes["Stats.Losses"]).to.equal(nil)
			expect(#changes.Items.value).to.equal(2)
			expect(changes.New.value.X).to.equal(1)
			expect(changes.Gone).to.be.ok()
			expect(changes.Gone.value).to.equal(nil)
		end)

		it("replaces dictionaries whose keys cannot be addressed by paths", function()
			local changes = byPath(Shared.diff({ Ids = { ["a.b"] = 1 } }, { Ids = { ["a.b"] = 2 } }))
			expect(changes.Ids.value["a.b"]).to.equal(2)
		end)
	end)

	describe("Shared.OP", function()
		it("exposes the five opcodes", function()
			expect(Shared.OP.Set).to.equal("set")
			expect(Shared.OP.Del).to.equal("del")
			expect(Shared.OP.Ins).to.equal("ins")
			expect(Shared.OP.AUpd).to.equal("aupd")
			expect(Shared.OP.ARm).to.equal("arm")
		end)
	end)

	describe("Shared.arrayUpdate", function()
		it("replaces the value at a 1-based index", function()
			local root = { Items = { "a", "b", "c" } }
			local changed = Shared.arrayUpdate(root, { "Items" }, 2, "B")
			expect(changed).to.equal(true)
			expect(root.Items[2]).to.equal("B")
		end)

		it("returns false on out-of-bounds index", function()
			local root = { Items = { "a" } }
			expect(Shared.arrayUpdate(root, { "Items" }, 0, "x")).to.equal(false)
			expect(Shared.arrayUpdate(root, { "Items" }, 5, "x")).to.equal(false)
			expect(root.Items[1]).to.equal("a")
		end)

		it("returns false when target is not an array", function()
			local root = { Stats = { Coins = 5 } }
			expect(Shared.arrayUpdate(root, { "Stats" }, 1, "x")).to.equal(false)
		end)

		it("returns false on empty path", function()
			expect(Shared.arrayUpdate({}, {}, 1, "x")).to.equal(false)
		end)
	end)

	describe("Shared.arrayRemove", function()
		it("removes the value at a 1-based index and shrinks length", function()
			local root = { Items = { "a", "b", "c" } }
			local changed = Shared.arrayRemove(root, { "Items" }, 2)
			expect(changed).to.equal(true)
			expect(root.Items[1]).to.equal("a")
			expect(root.Items[2]).to.equal("c")
			expect(#root.Items).to.equal(2)
		end)

		it("returns false on out-of-bounds index", function()
			local root = { Items = { "a" } }
			expect(Shared.arrayRemove(root, { "Items" }, 0)).to.equal(false)
			expect(Shared.arrayRemove(root, { "Items" }, 5)).to.equal(false)
			expect(#root.Items).to.equal(1)
		end)

		it("returns false when target is not an array", function()
			local root = { Stats = { Coins = 5 } }
			expect(Shared.arrayRemove(root, { "Stats" }, 1)).to.equal(false)
		end)
	end)

	describe("Shared.arrayUpdateSpine", function()
		it("returns a new root with the array spine cloned", function()
			local root = { Items = { "a", "b", "c" }, Other = { kept = true } }
			local newRoot = Shared.arrayUpdateSpine(root, { "Items" }, 2, "B")
			expect(newRoot).never.to.equal(root)
			expect(newRoot.Items).never.to.equal(root.Items)
			expect(newRoot.Other).to.equal(root.Other) -- sibling identity preserved
			expect(newRoot.Items[2]).to.equal("B")
			expect(root.Items[2]).to.equal("b") -- original untouched
		end)

		it("returns root unchanged when target is not an array", function()
			local root = { Stats = { Coins = 5 } }
			local newRoot = Shared.arrayUpdateSpine(root, { "Stats" }, 1, "x")
			expect(newRoot).to.equal(root)
		end)

		it("returns root unchanged on empty path", function()
			local root = {}
			expect(Shared.arrayUpdateSpine(root, {}, 1, "x")).to.equal(root)
		end)
	end)

	describe("Shared.arrayRemoveSpine", function()
		it("returns a new root with the array shrunk", function()
			local root = { Items = { "a", "b", "c" }, Other = { kept = true } }
			local newRoot = Shared.arrayRemoveSpine(root, { "Items" }, 2)
			expect(newRoot).never.to.equal(root)
			expect(newRoot.Items).never.to.equal(root.Items)
			expect(newRoot.Other).to.equal(root.Other)
			expect(#newRoot.Items).to.equal(2)
			expect(newRoot.Items[2]).to.equal("c")
			expect(#root.Items).to.equal(3) -- original untouched
		end)

		it("returns root unchanged when index is out of bounds", function()
			local root = { Items = { "a" } }
			expect(Shared.arrayRemoveSpine(root, { "Items" }, 5)).to.equal(root)
		end)
	end)

	describe("Shared.writePath", function()
		it("does not materialize parents for missing deletes", function()
			local root = {}
			local changed = Shared.writePath(root, { "Stats", "Coins" }, nil, false)

			expect(changed).to.equal(false)
			expect(root.Stats).to.equal(nil)
		end)

		it("does not materialize parents for invalid inserts", function()
			local root = {}
			local changed = Shared.writePath(root, { "Inventory", "Items" }, "Sword", true)

			expect(changed).to.equal(false)
			expect(root.Inventory).to.equal(nil)
		end)
	end)

	describe("Shared.writePathSpine", function()
		it("returns the same root for missing deletes", function()
			local root = {}
			local newRoot = Shared.writePathSpine(root, { "Stats", "Coins" }, nil, false)

			expect(newRoot).to.equal(root)
			expect(root.Stats).to.equal(nil)
		end)

		it("returns the same root for invalid inserts", function()
			local root = {}
			local newRoot = Shared.writePathSpine(root, { "Inventory", "Items" }, "Sword", true)

			expect(newRoot).to.equal(root)
			expect(root.Inventory).to.equal(nil)
		end)
	end)
end
