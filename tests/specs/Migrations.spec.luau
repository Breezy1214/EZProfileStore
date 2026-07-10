local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Migrations = require(ReplicatedStorage.Packages.EZProfileStore.Migrations)

return function()
	describe("Migrations", function()
		it("runs only versions newer than the stored version", function()
			local ran = {}
			local migrations = Migrations.new({
				function(data)
					table.insert(ran, 1)
					data.Legacy = true
				end,
				{
					name = "currency-table",
					up = function(data, context)
						table.insert(ran, context.version)
						data.Currency = { Coins = data.Coins }
						data.Coins = nil
					end,
				},
			})

			local data = { Coins = 25 }
			local report = migrations:Migrate(data, 1)

			expect(#ran).to.equal(1)
			expect(ran[1]).to.equal(2)
			expect(data.Currency.Coins).to.equal(25)
			expect(data.Legacy).to.equal(nil)
			expect(report.fromVersion).to.equal(1)
			expect(report.toVersion).to.equal(2)
			expect(report.applied[1].name).to.equal("currency-table")
		end)

		it("accepts a replacement table returned by a migration", function()
			local migrations = Migrations.new({
				function(data)
					return { Coins = data.LegacyCoins }
				end,
			})
			local data = { LegacyCoins = 50 }

			migrations:Migrate(data)

			expect(data.LegacyCoins).to.equal(nil)
			expect(data.Coins).to.equal(50)
		end)

		it("restores all nested data when a migration fails", function()
			local migrations = Migrations.new({
				function(data)
					data.Inventory.Items[1] = "changed"
				end,
				{
					name = "broken",
					up = function(data)
						data.Inventory.Items[2] = "partial"
						error("boom")
					end,
				},
			})
			local data = { Inventory = { Items = { "original" } } }

			local ok, message = pcall(function()
				migrations:Migrate(data)
			end)

			expect(ok).to.equal(false)
			expect(string.find(message, "broken", 1, true) ~= nil).to.equal(true)
			expect(data.Inventory.Items[1]).to.equal("original")
			expect(data.Inventory.Items[2]).to.equal(nil)
		end)

		it("supports reversible migration tests", function()
			local migrations = Migrations.new()
			migrations:Add("rename", function(data)
				data.New = data.Old
				data.Old = nil
			end, function(data)
				data.Old = data.New
				data.New = nil
			end)
			local data = { Old = 10 }

			migrations:Migrate(data)
			local report = migrations:Rollback(data, 1, 0)

			expect(data.Old).to.equal(10)
			expect(data.New).to.equal(nil)
			expect(report.toVersion).to.equal(0)
		end)
	end)
end
