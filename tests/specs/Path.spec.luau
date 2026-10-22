local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PackageRoot = ReplicatedStorage.Packages.EZProfileStore
local Path = require(PackageRoot.Path)
local Shared = require(PackageRoot.Shared)

return function()
	describe("Path.tree", function()
		it("builds nested paths with pre-split keys", function()
			local Paths = Path.tree({ Coins = 0, Stats = { Wins = 0 } })
			expect(Paths.Coins.__key).to.equal("Coins")
			expect(Paths.Stats.Wins.__key).to.equal("Stats.Wins")
			expect(#Paths.Stats.Wins.__keys).to.equal(2)
			expect(Paths.Stats.Wins.__keys[1]).to.equal("Stats")
		end)

		it("creates fields lazily, including optional fields and dictionary keys", function()
			local Paths = Path.tree({ Pets = {} })
			expect(Paths.Settings.Music.__key).to.equal("Settings.Music")
			expect(Paths.Pets["pet-1"].Level.__key).to.equal("Pets.pet-1.Level")
		end)

		it("rejects keys that cannot be addressed", function()
			local Paths = Path.tree({})
			expect(function()
				return Paths["a.b"]
			end).to.throw()
			expect(function()
				return Paths[""]
			end).to.throw()
			expect(function()
				return Paths.__secret
			end).to.throw()
			expect(function()
				return (Paths :: any)[1]
			end).to.throw()
		end)

		it("is read-only and frozen", function()
			local Paths = Path.tree({ Coins = 0 })
			expect(function()
				(Paths :: any).Coins = 1
			end).to.throw()
			expect(table.isfrozen(Paths.Coins)).to.equal(true)
			expect(table.isfrozen(Paths.Coins.__keys)).to.equal(true)
		end)

		it("does not treat the root as a path", function()
			local Paths = Path.tree({ Coins = 0 })
			expect(Path.is(Paths)).to.equal(false)
			expect(Path.is(Paths.Coins)).to.equal(true)
			expect(Path.is("Coins")).to.equal(false)
			expect(Path.is({ __key = "Coins", __keys = { "Coins" } })).to.equal(false)
		end)
	end)

	describe("Shared.resolvePath", function()
		it("rejects anything that is not a tree path", function()
			for _, input in { 5, "Stats.Wins", { "Stats", "Wins" }, Path.tree({}) } do
				expect(function()
					Shared.resolvePath(input)
				end).to.throw()
			end
		end)
	end)
end
