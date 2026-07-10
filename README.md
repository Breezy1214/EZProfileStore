# EZProfileStore

EZProfileStore is a small [ProfileStore](https://github.com/MadStudioRoblox/ProfileStore) wrapper for Roblox games that want server-owned profile data with automatic client replication.

It owns the ProfileStore session lifecycle on the server, gives gameplay code a path-based mutation API, and mirrors each player's profile into a Fusion state object on the client. The goal is to make common profile reads, writes, UI bindings, and leaderstats setup predictable without hiding ProfileStore's important lifecycle rules.

## Features

- Profile lifecycle handling: `StartSessionAsync`, `AddUserId`, `Reconcile`, `EndSession`, and player leave cleanup.
- Path-based reads and writes using `"Stats.Wins"` or `{ "Stats", "Wins" }`.
- Replicated mutations: set, delete, insert, increment, decrement, array item update/remove, and batch set/delete.
- Per-frame replication batching so bursts of synchronous writes use one remote event.
- Fusion-backed client mirror with `Ready`, `Read`, `WatchPath`, and `OnChanged`.
- ProfileStore save signal forwards: `PreSave`, `PostSave`, and `LastSave`.
- Optional `leaderstats` mirroring from profile paths.
- Ordered, transactional schema migrations with versions stored in Roblox metadata.
- One-call mock stores plus dependency injection for focused unit tests.
- Historical version previews and one-call rollbacks by version, time, or saves-back.
- Server readiness helpers that replace retry loops around profile loading.

## Installation

Add the package to your [Wally](https://wally.run) manifest:

```toml
[dependencies]
EZProfileStore = "breezy1214/ezprofilestore@0.1.0"
```

## Server Quick Start

```lua
local EZProfileStore = require(Path.To.EZProfileStore)

local store = EZProfileStore.Server.new({
	storeName = "PlayerData_v1",
	template = {
		Coins = 0,
		Inventory = {},
		Stats = {
			Wins = 0,
		},
	},
	mode = "studio", -- ProfileStore.Mock in Studio, live data elsewhere
})

store.FirstJoin:Connect(function(player, data)
	data.Coins = 50
end)

store.ProfileLoaded:Connect(function(player, profile)
	print(player.Name, "loaded", profile.SessionLoadCount, "time(s)")
end)

local function givePotion(player)
	if not store:IsReady(player) then
		return
	end

	store:InsertData(player, "Inventory", "Potion")
	store:IncrementData(player, "Stats.Wins")
	store:UpdateData(player, "Coins", (store:ReadData(player, "Coins") or 0) + 25)
end
```

`GetData(player)` returns the live profile table. Direct mutations will save through ProfileStore, but they will not replicate to the client. Use the mutation methods for gameplay writes that UI code needs to observe.

When another service can start before data is ready, use the yielding helper instead of polling:

```lua
local data = store:GetDataAsync(player, 10)
if not data then
	return -- player left or loading timed out
end
```

## Client Quick Start

```lua
local EZProfileStore = require(Path.To.EZProfileStore)

local client = EZProfileStore.Client.new()

client.Ready:andThen(function(data)
	print("Initial coins:", data.Coins)
end)

local disconnectCoins = client:OnChanged("Coins", function(newValue, oldValue)
	print("Coins:", oldValue, "->", newValue)
end)

local inventoryWatcher = client:WatchPath("Inventory")
local inventory = client:Read("Inventory")
```

Treat client data as read-only. Client-side edits only change the local copy and can be overwritten by the next replicated server update.

## Leaderstats

Declare profile paths to mirror into the Roblox player list:

```lua
local store = EZProfileStore.Server.new({
	storeName = "PlayerData_v1",
	template = {
		Coins = 0,
		Stats = {
			Wins = 0,
		},
	},
	leaderstats = {
		{ path = "Coins", name = "Coins", type = "IntValue" },
		{ path = "Stats.Wins", name = "Wins", type = "IntValue" },
	},
})
```

Tracked paths are validated against the template at startup. Updates are mirrored after the same deferred flush used for client replication.

## Schema Migrations

Append one migration whenever the stored shape changes. Positions become versions (`1`, `2`, ...), and EZProfileStore records the applied version in `Profile.RobloxMetaData.EZProfileStoreVersion`, keeping bookkeeping out of replicated player data.

```lua
local migrations = EZProfileStore.Migrations.new({
	{
		name = "move-coins-into-currency",
		up = function(data)
			data.Currency = data.Currency or {}
			data.Currency.Coins = data.Currency.Coins or data.Coins or 0
			data.Coins = nil
		end,
	},
	{
		name = "inventory-v2",
		up = function(data)
			return {
				Currency = data.Currency,
				Inventory = { Items = data.Inventory or {} },
			}
		end,
	},
})

local store = EZProfileStore.Server.new({
	storeName = "PlayerData",
	template = CurrentTemplate,
	migrations = migrations,
})
```

Only migrations newer than a profile's stored version run. Migrations see the raw stored shape before `Profile:Reconcile()` fills current-template defaults, preventing a new default from masking a legacy value. Brand-new profiles skip historical migrations by default because the current template is already the latest schema; set `migrateNewProfiles = true` if your migrations also seed new profiles. A migration may mutate `data` or return a replacement table. If any step errors, the entire run is restored before the load fails, and `ProfileLoadFailed` fires with a diagnostic message.

For small projects, pass the ordered list directly as `migrations = { require(...), require(...) }`. A bare function is shorthand for `{ up = function }`. Optional `down` functions can be exercised with `migrations:Rollback(data, fromVersion, targetVersion)` in migration unit tests.

## Mocks and Tests

Force ProfileStore's isolated in-memory store with one call:

```lua
local store = EZProfileStore.Server.mock({
	storeName = "PlayerData_Test",
	template = Template,
	migrations = migrations,
})

assert(store.IsMock)
```

`mode = "studio"` selects mock data only in Studio; `mode = "mock"` always selects it; `mode = "live"` is the default. The older `useMockInStudio = true` option remains supported.

For unit tests, inject an already-created ProfileStore-compatible object with `store = fakeStore`, or inject a ProfileStore module with `profileStore = fakeProfileStore`. These options are mutually exclusive, and an injected `store` cannot be combined with Studio/mock mode because it is already the final backend. `GetStore()` exposes the resolved underlying store for advanced ProfileStore APIs.

## Safe Rollbacks

Preview a historical save without changing anything, then apply the exact version you inspected:

```lua
local preview = store:PreviewRollbackAsync(userId, { stepsBack = 1 })
if not preview then
	return warn("No older save exists")
end

print(preview.version, preview.updatedTime, preview.data)

-- After inspection/authorization:
local restored = store:ApplyRollbackAsync(preview)
```

Selectors support:

- `{ stepsBack = 1 }` — previous save (also the default selector).
- `{ before = DateTime.fromUnixTimestamp(...) }` — newest version at or before a time. Epoch milliseconds are also accepted.
- `{ version = "..." }` — exact DataStore version id.

Numeric targets are treated as UserIds and use `keyPrefix`; string targets are exact ProfileStore keys. `ApplyRollbackAsync` consumes a preview once without loading its version again. `RollbackAsync(target, selector)` remains a one-call option when no human review is needed. After the historical write, EZProfileStore explicitly ends a matching live session so an online player cannot continue mutating stale pre-rollback data. Prefer preview/apply and keep an audit log around production admin tooling.

ProfileStore does not provide version history through `ProfileStore.Mock`; test rollback workflows by injecting a version-aware fake `store`, while integration-testing real history in a private Studio place with API access.

## API Overview

### Server

- `Server.new(config)` creates the store and binds player lifecycle handlers.
- `Server.mock(config)` creates the same server over ProfileStore's isolated mock store.
- `GetProfile(player)` returns the ProfileStore profile, if loaded.
- `GetProfileAsync(player, timeout?)` yields for a loaded profile without polling.
- `GetData(player)` returns the live profile data table, if loaded.
- `GetDataAsync(player, timeout?)` yields for loaded profile data.
- `GetKey(playerOrUserIdOrExactKey)` resolves the configured ProfileStore key.
- `GetStore()` returns the underlying ProfileStore object.
- `ReadData(player, keyPath)` reads a path without mutating.
- `UpdateData(player, keyPath, value)` sets a value. Passing `nil` deletes the path.
- `InsertData(player, keyPath, value)` appends to an array/table at a path.
- `IncrementData(player, keyPath, delta?)` and `DecrementData(player, keyPath, delta?)` update numeric values.
- `RemoveData(player, keyPath)` deletes a value without creating missing parent tables.
- `UpdateArrayItem(player, arrayPath, index, value)` replaces a 1-based array item.
- `RemoveArrayItem(player, arrayPath, index)` removes a 1-based array item with `table.remove`.
- `BatchSetValues(player, writes)` applies multiple set/delete writes in one replication batch.
- `SaveAsync(player)` forces `profile:Save()` for critical checkpoints.
- `PreviewRollbackAsync(target, selector?)` reads a historical version without writing.
- `ApplyRollbackAsync(preview)` applies a preview once without a second version read.
- `RollbackAsync(target, selector?)` restores a historical version.
- `WipeAsync(target)` permanently removes the configured ProfileStore key.
- `IsReady(player)` reports whether the player's profile is loaded.
- `Destroy()` ends active sessions and disconnects listeners.

### Client

- `Client.new(config?)` connects to replication remotes and requests the initial snapshot.
- `Ready` resolves with the initial profile snapshot.
- `GetData()` returns the local snapshot, if loaded.
- `GetDataState()` returns the underlying Fusion `Value`.
- `GetDataAsync(timeout?)` yields for the initial snapshot.
- `Read(keyPath)` reads a value from the local snapshot.
- `IsReady()` reports whether the initial snapshot has arrived.
- `OnReady(callback)` runs a callback once the snapshot is ready.
- `WatchPath(keyPath)` creates a PathWatcher for Fusion UI code.
- `OnChanged(keyPath, callback)` subscribes to one path and returns a disconnect function.
- `Destroy()` disconnects listeners and cleans up the Fusion scope.

## ProfileStore Notes

EZProfileStore follows ProfileStore's session model. `StartSessionAsync` can fail, sessions must end when players leave, and direct edits are safe only while a profile is active. ProfileStore already auto-saves and performs a final save when `EndSession()` runs, so call `SaveAsync` only for high-value checkpoints such as product receipts.

For lower-level behavior, see the official [ProfileStore API documentation](https://madstudioroblox.github.io/ProfileStore/api/).

## License

MIT
