# EZProfileStore

A typed [ProfileStore](https://github.com/MadStudioRoblox/ProfileStore) wrapper. The server edits player data as plain Luau; only the changes replicate to the client.

## Installation

```toml
[dependencies]
EZProfileStore = "breezy1214/ezprofilestore@0.1.5"
```

Requires Luau's new type solver (luau-lsp: `luau-lsp.fflags.enableNewSolver`).

## Data

Share one template between server and client:

```lua
-- ReplicatedStorage/PlayerData.luau
export type Data = {
	Coins: number,
	Inventory: { string },
	Stats: { Wins: number, Losses: number },
}

local template: Data = {
	Coins = 0,
	Inventory = {},
	Stats = { Wins = 0, Losses = 0 },
}

return { template = template }
```

## Server

```lua
local store = EZProfileStore.Server.new({
	storeName = "PlayerData_v1",
	template = PlayerData.template,
	mode = "studio", -- mock data in Studio, live data elsewhere
})

store:Update(player, function(data)
	if data.Coins < 25 then
		return false -- abort, nothing changes
	end
	data.Coins -= 25
	table.insert(data.Inventory, "Potion")
end)

local data = store:Get(player) -- read-only; change data with Update
```

`Update` commits all-or-nothing. It returns `false` if the function errors, yields, returns `false`, or writes a value DataStores can't save. Use `for k, v in data` (not `pairs`) inside it, and don't keep `data` after it returns.

Trades across players:

```lua
store:UpdateMany({ buyer, seller }, function(drafts)
	if drafts[buyer].Coins < price then
		return false
	end
	drafts[buyer].Coins -= price
	drafts[seller].Coins += price
end)
```

## Client

```lua
local client = EZProfileStore.Client.new({ template = PlayerData.template })

local wins = client:Select(function(data)
	return data.Stats.Wins
end)

wins:Get() -- number?
wins:Observe(function(new, old) end) -- returns a disconnect function
wins.State -- Fusion state, e.g. use(wins.State)
wins:Destroy()
```

## Config

```lua
local config: EZProfileStore.ServerConfig<PlayerData.Data> = {
	storeName = "PlayerData_v1",
	template = PlayerData.template,

	leaderstats = {
		{ name = "Coins", type = "IntValue", value = function(data) return data.Coins end },
		{ name = "Games", type = "IntValue", value = function(data) return data.Stats.Wins + data.Stats.Losses end },
	},

	privatePaths = { -- never sent to the client
		function(data) return data.Inventory end,
	},

	validate = function(data) -- checked on load and before every Update commits
		return data.Coins >= 0, "Coins must not be negative"
	end,
}

local store = EZProfileStore.Server.new(config)
```

Annotating the config as `ServerConfig<Data>` gives the functions inside it full type checking.

Other options: `keyPrefix`, `mode` (`"live"`, `"studio"`, `"mock"`), `migrations`, `migrateNewProfiles`, `remoteParent`, `autoLoadPlayers`, `store`, `profileStore`.

## Migrations

```lua
migrations = EZProfileStore.Migrations.new({
	{
		name = "move-coins",
		up = function(data)
			data.Currency = { Coins = data.Coins or 0 }
			data.Coins = nil
		end,
	},
}),
```

Append a migration whenever the stored shape changes. Only versions newer than the profile's run, before `Reconcile`. New profiles skip them unless `migrateNewProfiles = true`. A failing migration restores the data and fires `ProfileLoadFailed`.

## Testing

```lua
local store = EZProfileStore.Server.mock({
	storeName = "Test",
	template = template,
	autoLoadPlayers = false,
})
```

To fake the backend, pass `store = fakeStore` or `profileStore = fakeModule`.

## API

**Server**

| Member | Description |
| --- | --- |
| `Server.new(config)` / `Server.mock(config)` | Create a store. |
| `Get(player)` / `GetAsync(player, timeout?)` | Read-only data. |
| `Update(player, fn)` / `UpdateMany(players, fn)` | Edit data, all-or-nothing. |
| `Changed`, `FirstJoin`, `ProfileLoaded`, `ProfileReleased`, `ProfileLoadFailed` | Signals. |
| `PreSave`, `PostSave`, `LastSave`, `Migrated`, `RolledBack` | Signals. |
| `GetProfile(player)` / `GetProfileAsync(player, timeout?)` | The ProfileStore profile. |
| `IsReady(player)`, `SaveAsync(player)`, `GetKey(target)`, `GetStore()` | Utilities. |
| `SendMessageAsync(target, message)` / `OnMessage(handler)` | Offline messages. |
| `PreviewRollbackAsync(target, selector?)` / `ApplyRollbackAsync(preview)` / `RollbackAsync(target, selector?)` | Restore an older save. The selector is `{ stepsBack }`, `{ before }`, or `{ version }`. |
| `WipeAsync(target)` | Delete a profile. |
| `Destroy()` | End sessions and disconnect. |

**Client**

| Member | Description |
| --- | --- |
| `Client.new(config?)` | Connect and request the snapshot. |
| `Ready`, `IsReady()`, `OnReady(fn)` | Load state. |
| `Get()` / `GetAsync(timeout?)` | Read-only data. |
| `Select(selector)` | A `Selection` with `Get`, `Observe`, `State`, and `Destroy`. |
| `Destroy()` | Disconnect. |

Exported types: `Server<Data>`, `Client<Data>`, `Selection<V>`, `ReadOnly<T>`, `ServerConfig<Data>`, `ClientConfig<Data>`, `Profile<Data>`, `LeaderstatEntry<Data>`.

## License

MIT
