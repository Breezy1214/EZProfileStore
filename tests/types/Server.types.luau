--!strict
-- Type regression fixture: never run. Lines marked `expect-error` must fail to type-check; all others must pass.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local EZProfileStore = require(ReplicatedStorage.Packages.EZProfileStore)

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

local config: EZProfileStore.ServerConfig<Data> = {
	storeName = "Types",
	template = template,
	leaderstats = {
		{
			name = "Coins",
			type = "IntValue",
			value = function(data)
				return data.Coins
			end,
		},
		{
			name = "Games",
			type = "IntValue",
			value = function(data)
				return data.Stats.Wins + data.Stats.Losses
			end,
		},
		{
			name = "Bad",
			type = "IntValue",
			value = function(data)
				return data.Stats -- expect-error
			end,
		},
	},
	privatePaths = {
		function(data)
			return data.Settings
		end,
	},
	validate = function(data)
		data.Coins = 0 -- expect-error
		return data.Coins >= 0, "negative coins"
	end,
}
local store = EZProfileStore.Server.new(config)

local inferred = EZProfileStore.Server.new({
	storeName = "Inferred",
	template = template,
	leaderstats = {
		{
			name = "Coins",
			type = "IntValue",
			value = function(data)
				return data.Coins
			end,
		},
	},
})
local _inferredData: Data? = inferred:Get(game:GetService("Players").LocalPlayer) -- expect-error
local player: Player = game:GetService("Players").LocalPlayer
local other: Player = player

local data = store:Get(player)
if data then
	local _total: number = data.Coins + data.Stats.Wins
	local pet = data.Pets["a"]
	local _level: number? = if pet then pet.Level else nil
	local _name: number = data.Name -- expect-error
	data.Coins = 5 -- expect-error
end

store:Update(player, function(draft)
	draft.Coins += 10
	draft.Stats.Wins += 1
	table.insert(draft.Inventory, "Potion")
	draft.Pets["a"] = { Level = 1, Nickname = "Rex" }
	draft.Settings = nil
end)
store:Update(player, function(draft)
	if draft.Coins < 10 then
		return false
	end
	draft.Coins -= 10
	return nil
end)
store:Update(player, function(draft)
	draft.Coins = "ten" -- expect-error
end)
store:Update(player, function(draft)
	table.insert(draft.Inventory, 5) -- expect-error
end)
store:Update(player, function(draft)
	draft.Nope = 1 -- expect-error
end)
store:Update(player, function(): string -- expect-error
	return "no"
end)

store:UpdateMany({ player, other }, function(drafts)
	drafts[player].Coins -= 10
	drafts[other].Coins += 10
	drafts[other].Name = 1 -- expect-error
end)

store.Changed:Connect(function(_, changed)
	local _coins: number = changed.Coins
	changed.Coins = 1 -- expect-error
end)

store.FirstJoin:Connect(function(_, first)
	first.Coins = 50
end)
