--!strict
-- Type regression fixture: never run. Lines marked `expect-error` must fail to type-check; all others must pass.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local EZProfileStore = require(ReplicatedStorage.Packages.EZProfileStore)

export type Data = {
	Coins: number,
	Stats: { Wins: number },
	Inventory: { string },
	Pets: { [string]: { Level: number } },
}
local template: Data = { Coins = 0, Stats = { Wins = 0 }, Inventory = {}, Pets = {} }

local client = EZProfileStore.Client.new({ template = template })

local wins = client:Select(function(data)
	return data.Stats.Wins
end)
local _wins: number? = wins:Get()
local _badWins: string? = wins:Get() -- expect-error
wins:Observe(function(new, old)
	local _delta: number = (new or 0) - (old or 0)
end)
wins:Observe(function(_new: string?) end) -- expect-error
wins:Destroy()

local total = client:Select(function(data)
	return data.Coins + data.Stats.Wins
end)
local _state = total.State
total:Destroy()

client:Select(function(data)
	data.Coins = 1 -- expect-error
	return data.Coins
end)

client.Ready:andThen(function(data)
	local _total: number = data.Coins + data.Stats.Wins
	data.Coins = 1 -- expect-error
end)

local data = client:GetAsync()
local _items: { string } = data.Inventory
data.Stats.Wins = 2 -- expect-error

local annotated = EZProfileStore.Client.new() :: EZProfileStore.Client<Data>
local _annotatedCoins = annotated
	:Select(function(snapshot)
		return snapshot.Coins
	end)
	:Get()
