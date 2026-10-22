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
local Paths = EZProfileStore.Path.tree(template)

local client = EZProfileStore.Client.new({ template = template })

local _coins: number? = client:Read(Paths.Coins)
local _level: number? = client:Read(Paths.Pets["a"].Level)
local _bad: string? = client:Read(Paths.Coins) -- expect-error

client:OnChanged(Paths.Stats.Wins, function(newValue: number?, oldValue: number?)
	local _delta: number = (newValue or 0) - (oldValue or 0)
end)
client:WatchPath(Paths.Stats.Wins):onChange(function(newValue, oldValue)
	local _delta: number = (newValue or 0) - (oldValue or 0)
end)
client:OnChanged(Paths.Stats.Wins, function(_newValue: string?) end) -- expect-error

local watcher = client:WatchPath(Paths.Inventory)
local _items: { string }? = watcher.get()
watcher:Destroy()

client.Ready:andThen(function(data)
	local _total: number = data.Coins + data.Stats.Wins
	data.Coins = 1 -- expect-error
end)

local data = client:GetDataAsync()
local _wins: number = data.Stats.Wins
data.Stats.Wins = 2 -- expect-error

-- Annotating instead of passing a template also works.
local annotated = EZProfileStore.Client.new() :: EZProfileStore.Client<Data>
local _annotatedCoins: number? = annotated:Read(Paths.Coins)

local function award(store: EZProfileStore.Server<Data>, player: Player)
	store:IncrementData(player, Paths.Coins, 5)
	store:IncrementData(player, Paths.Inventory, 5) -- expect-error
end
local _ = award
