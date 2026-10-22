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
	end)

	describe("Shared.diff", function()
		local function diff(old, new)
			local out = {}
			Shared.diff(old, new, {}, out)
			local result = {}
			for _, change in out do
				result[change.key] = change
			end
			return result, out
		end

		it("recurses into dictionaries", function()
			local changes = diff({
				Coins = 1,
				Stats = { Wins = 1, Losses = 0 },
				Gone = true,
			}, {
				Coins = 2,
				Stats = { Wins = 2, Losses = 0 },
				New = { X = 1 },
			})

			expect(changes.Coins.op).to.equal(Shared.OP.Set)
			expect(changes["Stats.Wins"].value).to.equal(2)
			expect(changes["Stats.Losses"]).to.equal(nil)
			expect(changes.New.value.X).to.equal(1)
			expect(changes.Gone.op).to.equal(Shared.OP.Del)
		end)

		it("emits ins for appends and set for any other array change", function()
			local _, appended = diff({ Items = { "a" } }, { Items = { "a", "b", "c" } })
			expect(#appended).to.equal(2)
			expect(appended[1].op).to.equal(Shared.OP.Ins)
			expect(appended[1].value).to.equal("b")
			expect(appended[2].value).to.equal("c")

			local replaced = diff({ Items = { "a", "b" } }, { Items = { "b" } })
			expect(replaced.Items.op).to.equal(Shared.OP.Set)
			expect(#replaced.Items.value).to.equal(1)
		end)

		it("replaces dictionaries whose keys cannot be addressed by paths", function()
			local changes = diff({ Ids = { ["a.b"] = 1 } }, { Ids = { ["a.b"] = 2 } })
			expect(changes.Ids.value["a.b"]).to.equal(2)
		end)
	end)

	describe("Shared.trace", function()
		it("records the path a selector reads", function()
			local path = Shared.trace(function(data: any)
				return data.Stats.Wins
			end)
			expect(table.concat(path, ".")).to.equal("Stats.Wins")
		end)

		it("rejects selectors that don't return a field", function()
			expect(pcall(Shared.trace, function()
				return 1
			end)).to.equal(false)
			expect(pcall(Shared.trace, function(data: any)
				return data["a.b"]
			end)).to.equal(false)
		end)
	end)
end
