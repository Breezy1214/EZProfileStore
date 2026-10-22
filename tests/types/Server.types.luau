--!strict
-- Type regression fixture: never run. Lines marked `expect-error` must fail to type-check; all others must pass.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local EZProfileStore = require(ReplicatedStorage.Packages.EZProfileStore)
local Path = EZProfileStore.Path

export type Data = {
	Coins: number,
	Name: string,
	Stats: { Wins: number, Losses: number },
	Inventory: { string },
	Pets: { [string]: { Level: number, Nickname: string } },
	Settings: { Music: boolean }?,
}
local template: Data = {
	Coins = 0,
	Name = "",
	Stats = { Wins = 0, Losses = 0 },
	Inventory = {},
	Pets = {},
}
local Paths = Path.tree(template)

local store = EZProfileStore.Server.new({
	storeName = "Types",
	template = template,
	leaderstats = {
		{ path = Paths.Coins, name = "Coins", type = "IntValue" },
	},
	privatePaths = { Paths.Settings },
	validate = function(data)
		return data.Coins >= 0, "negative coins"
	end,
})
local player: Player = game:GetService("Players").LocalPlayer

-- Reads
local _coins: number? = store:ReadData(player, Paths.Coins)
local _wins: number? = store:ReadData(player, Paths.Stats.Wins)
local _level: number? = store:ReadData(player, Paths.Pets["pet-1"].Level)
local _music: boolean? = store:ReadData(player, Paths.Settings.Music)
local _badRead: string? = store:ReadData(player, Paths.Coins) -- expect-error
local _ = Paths.Stats.Nope -- expect-error

-- Writes
store:UpdateData(player, Paths.Coins, 10)
store:UpdateData(player, Paths.Coins, "ten") -- expect-error
store:UpdateData(player, Paths.Pets["pet-1"], { Level = 1, Nickname = "Rex" })
store:UpdateData(player, Paths.Pets["pet-1"], { Level = "1", Nickname = "Rex" }) -- expect-error
store:InsertData(player, Paths.Inventory, "Sword")
store:InsertData(player, Paths.Inventory, 5) -- expect-error
store:InsertData(player, Paths.Coins, 5) -- expect-error
store:IncrementData(player, Paths.Stats.Wins, 1)
store:IncrementData(player, Paths.Name, 1) -- expect-error
store:UpdateArrayItem(player, Paths.Inventory, 1, "Shield")
store:UpdateArrayItem(player, Paths.Inventory, 1, false) -- expect-error
store:RemoveData(player, Paths.Pets["pet-1"])
store:BatchSetValues(player, { Path.write(Paths.Coins, 1), Path.write(Paths.Name, "x") })
store:BatchSetValues(player, { Path.write(Paths.Coins, "1") }) -- expect-error

-- Data access
local data = store:GetData(player)
if data then
	local _total: number = data.Coins + data.Stats.Wins
	local _name: number = data.Name -- expect-error
	data.Coins = 5 -- expect-error
end

store:Mutate(player, function(draft)
	draft.Coins -= 10
	table.insert(draft.Inventory, "Potion")
	draft.Nope = 1 -- expect-error
	return true
end)

store.FirstJoin:Connect(function(_, first)
	first.Coins = 50
end)

-- Transactions
local buyer: Player = player
store:Transaction(function()
	store:IncrementData(buyer, Paths.Coins, -10)
	store:InsertData(buyer, Paths.Inventory, "Sword")
	return true
end)
store:Transaction(function()
	store:InsertData(buyer, Paths.Inventory, 1) -- expect-error
end)
store:Transaction(function(): string -- expect-error
	return "no"
end)
