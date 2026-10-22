# EZProfileStore

EZProfileStore is a small [ProfileStore](https://github.com/MadStudioRoblox/ProfileStore) wrapper for Roblox games that want server-owned profile data with automatic client replication.

It owns the ProfileStore session lifecycle on the server, gives gameplay code a typed path-based mutation API generated from your template, and mirrors each player's profile into a Fusion state object on the client. The goal is to make common profile reads, writes, UI bindings, and leaderstats setup predictable without hiding ProfileStore's important lifecycle rules.

## Features

- Fully typed: the server, client, signals, and callbacks are typed by your data, and the paths you read and write are checked against it.
- A path tree generated from your template: `Paths.Stats.Wins`, `Paths.Pets[petId].Level`. You declare nothing per field.
- Read-only data views, so `store:GetData(player).Coins = 5` (which would skip replication) is a type error.
- Profile lifecycle handling: `StartSessionAsync`, `AddUserId`, `Reconcile`, `EndSession`, and player leave cleanup.
- Replicated mutations: set, delete, insert, increment, decrement, array item update/remove, and batch set.
- All-or-nothing `Transaction`s with O(changes) cost, plus `Mutate` / `MutateMany` draft transforms, all checked by an optional `validate` hook.
- Per-frame replication batching so bursts of synchronous writes use one remote event.
- Save-safety checks that reject NaN, infinity, Instances, malformed UTF-8, mixed or sparse tables, and cycles before they can break a save.
- `privatePaths` for server-only data that never reaches the client.
- Offline messages (gifts, admin grants) through ProfileStore's `MessageAsync`.
- Fusion-backed client mirror with `Ready`, `Read`, `WatchPath`, and `OnChanged`.
- ProfileStore save signal forwards: `PreSave`, `PostSave`, and `LastSave`.
- Optional `leaderstats` mirroring from profile paths.
- Ordered, transactional schema migrations with versions stored in Roblox metadata.
- One-call mock stores plus dependency injection for focused unit tests.
- Historical version previews and one-call rollbacks by version, time, or saves-back.

## Installation

Add the package to your [Wally](https://wally.run) manifest:

```toml
[dependencies]
EZProfileStore = "breezy1214/ezprofilestore@0.1.5"
```

Requires Luau's **new type solver** (in luau-lsp, set `luau-lsp.fflags.enableNewSolver`).

## Define Your Data Once

Put the data type, template, and path tree in a module both server and client require:

```lua
-- ReplicatedStorage/PlayerData.luau
local EZProfileStore = require(Path.To.EZProfileStore)

export type Pet = { Level: number, Nickname: string }
export type Data = {
	Coins: number,
	Inventory: { string },
	Stats: { Wins: number },
	Pets: { [string]: Pet },
	Settings: { Music: boolean }?,
}

local template: Data = {
	Coins = 0,
	Inventory = {},
	Stats = { Wins = 0 },
	Pets = {},
}

return {
	template = template,
	Paths = EZProfileStore.Path.tree(template),
}
```

Paths are created as you index the tree, including optional fields and dictionary keys (`Paths.Pets[petId]`). Every method takes these paths; keys starting with `__` are reserved.

## Server Quick Start

```lua
local EZProfileStore = require(Path.To.EZProfileStore)
local PlayerData = require(ReplicatedStorage.PlayerData)
local Paths = PlayerData.Paths

local store = EZProfileStore.Server.new({
	storeName = "PlayerData_v1",
	template = PlayerData.template,
	mode = "studio", -- ProfileStore.Mock in Studio, live data elsewhere
})

store.FirstJoin:Connect(function(player, data)
	data.Coins = 50
end)

local function givePotion(player: Player)
	store:InsertData(player, Paths.Inventory, "Potion")
	store:IncrementData(player, Paths.Stats.Wins)
	store:UpdateData(player, Paths.Pets["starter"], { Level = 1, Nickname = "Rex" })

	store:UpdateData(player, Paths.Coins, "25") -- type error: Coins is a number
	store:IncrementData(player, Paths.Inventory) -- type error: Inventory is not a number
end
```

`GetData` and `ReadData` return live data typed read-only; write through the mutation methods, `Transaction`, or `Mutate` so changes replicate.

To name the store's type in your own functions, use `EZProfileStore.Server<Data>`:

```lua
local function award(store: EZProfileStore.Server<PlayerData.Data>, player: Player)
	store:IncrementData(player, Paths.Coins, 10)
end
```

When another service can start before data is ready, use the yielding helper instead of polling:

```lua
local data = store:GetDataAsync(player, 10)
if not data then
	return -- player left or loading timed out
end
```

`DataUpdated` fires with the player, the dot-joined key, and the new value. Compare keys with `EZProfileStore.Path.keyOf(Paths.Stats.Wins)`.

## Client Quick Start

```lua
local EZProfileStore = require(Path.To.EZProfileStore)
local PlayerData = require(ReplicatedStorage.PlayerData)
local Paths = PlayerData.Paths

local client = EZProfileStore.Client.new({ template = PlayerData.template })

client.Ready:andThen(function(data)
	print("Initial coins:", data.Coins)
end)

local coins = client:Read(Paths.Coins) -- number?

client:WatchPath(Paths.Stats.Wins):onChange(function(newValue, oldValue)
	print("Wins:", oldValue, "->", newValue) -- both number?
end)
```

`template` is only used to infer `Data`. `OnChanged(path, callback)` also works, but annotate its callback parameters; `WatchPath(path):onChange(...)` infers them.

## Transactions

`Transaction` makes several writes all-or-nothing. They can span any players of the store. Inside the transform, the normal mutation methods apply immediately and each one records an undo entry. Replication and `DataUpdated` are held until commit.

```lua
local traded = store:Transaction(function()
	if (store:ReadData(buyer, Paths.Coins) or 0) < price then
		return false -- abort; nothing changes
	end
	store:IncrementData(buyer, Paths.Coins, -price)
	store:IncrementData(seller, Paths.Coins, price)
	store:RemoveData(seller, Paths.Pets[petId])
	store:UpdateData(buyer, Paths.Pets[petId], pet)
	return true
end)
```

If the transform errors, yields, returns `false`, or fails `validate`, every write is undone and nothing replicates. It costs O(writes), and nested calls act as savepoints. It is atomic in memory, not across a server crash.

`Mutate(player, transform)` edits a typed copy of the data and commits only the changed paths. It costs O(data size), so prefer `Transaction` on hot paths.

```lua
local bought = store:Mutate(player, function(data)
	if data.Coins < 100 then
		return false
	end
	data.Coins -= 100
	table.insert(data.Inventory, "Sword")
	return true
end)
```

`MutateMany(players, transform)` does the same for several players at once.

## Validation

Add `validate` to the config to enforce invariants. It runs:

- when a profile loads (after migrations and `Reconcile`),
- before every `Mutate` / `MutateMany` commit, and
- for every player a `Transaction` touched.

A failed load fires `ProfileLoadFailed` and kicks the player. Single-path helpers called outside a transaction only run the save-safety checks.

```lua
validate = function(data)
	if data.Coins < 0 then
		return false, "Coins must not be negative"
	end
	return true
end,
```

## Leaderstats

Mirror profile paths into the Roblox player list:

```lua
local store = EZProfileStore.Server.new({
	storeName = "PlayerData_v1",
	template = PlayerData.template,
	leaderstats = {
		{ path = Paths.Coins, name = "Coins", type = "IntValue" },
		{ path = Paths.Stats.Wins, name = "Wins", type = "IntValue" },
	},
})
```

Tracked paths are validated against the template at startup. Stats appear in the same order as their entries in the `leaderstats` array. Updates are mirrored after the same deferred flush used for client replication.

## Save Safety

A value that DataStores cannot encode makes every later save of that profile fail, so a single bad write can silently roll a player back. This is a known exploit when client input reaches profile data. Every mutation method checks values before writing. Rejected writes return `false` and warn with the reason:

- `NaN` and `±math.huge`
- Instances, functions, threads, and other Roblox types
- Strings or keys that are not valid UTF-8 (for example `"\255"`)
- Mixed array/dictionary tables, sparse arrays, non-integer or non-string keys
- Cyclic tables

Key path segments must be non-empty strings without `.`. Invalid paths raise an error because they indicate a programming mistake. Types do not exist at runtime, so still type-check and bound-check remote arguments before they reach the store.

## Private Paths

Keep server-only data such as receipts or moderation notes off the client:

```lua
privatePaths = { Paths.PurchaseHistory, Paths.Moderation.Notes },
```

Private paths are removed from the initial snapshot. Writes inside them never replicate, and writes to a parent table replicate with the private children stripped. Leaderstats inside private paths still update on the server.

## Offline Messages

Send data to any profile, online or offline, and apply it when that profile loads:

```lua
store:OnMessage(function(player, message, processed)
	local coins = message.coins
	if message.type == "Gift" and typeof(coins) == "number" and store:IncrementData(player, Paths.Coins, coins) then
		processed() -- only mark processed once applied
	end
end)

store:SendMessageAsync(recipientUserId, { type = "Gift", coins = 100 })
```

Messages that have not been processed are delivered again in the next session.

## Schema Migrations

Append one migration whenever the stored shape changes. Positions become versions (`1`, `2`, ...), and EZProfileStore records the applied version in `Profile.RobloxMetaData.EZProfileStoreVersion`, keeping bookkeeping out of replicated player data.

```lua
local migrations = EZProfileStore.Migrations.new({
	{
		name = "move-coins-into-currency",
		up = function(data)
			local coins = data.Coins
			data.Currency = { Coins = if typeof(coins) == "number" then coins else 0 }
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

Migrations receive `RawData` (`{ [unknown]: unknown }`), not `Data`, because stored profiles still have their old shape. Narrow values before using them, e.g. `local coins = data.Coins; if typeof(coins) == "number" then ... end`.

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

`mode = "studio"` selects mock data only in Studio; `mode = "mock"` always selects it; `mode = "live"` is the default.

In unit tests, also pass `autoLoadPlayers = false`. Otherwise every store a test creates starts a session for each player in the game, including you during a Play-mode test run. Seed or load profiles explicitly instead.

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

- `Server.new(config)` creates the store and binds player lifecycle handlers. `Data` is inferred from `config.template`.
- `Server.mock(config)` creates the same server over ProfileStore's isolated mock store.
- `GetProfile(player)` returns the ProfileStore profile, if loaded.
- `GetProfileAsync(player, timeout?)` yields for a loaded profile without polling.
- `GetData(player)` returns the live profile data (typed read-only), if loaded.
- `GetDataAsync(player, timeout?)` yields for loaded profile data.
- `GetKey(playerOrUserIdOrExactKey)` resolves the configured ProfileStore key.
- `GetStore()` returns the underlying ProfileStore object.
- `ReadData(player, path)` reads a path without mutating.
- `UpdateData(player, path, value)` sets a value of the path's type.
- `InsertData(player, arrayPath, value)` appends to an array.
- `IncrementData(player, numberPath, delta?)` and `DecrementData(player, numberPath, delta?)` update numeric values.
- `RemoveData(player, path)` deletes a value without creating missing parent tables.
- `UpdateArrayItem(player, arrayPath, index, value)` replaces a 1-based array item.
- `RemoveArrayItem(player, arrayPath, index)` removes a 1-based array item with `table.remove`.
- `BatchSetValues(player, { Path.write(path, value), ... })` applies several sets in one replication batch.
- `Transaction(transform)` makes the writes inside `transform` all-or-nothing, at O(changes) cost.
- `Mutate(player, transform)` commits a transformed copy of the data, or nothing.
- `MutateMany(players, transform)` commits transformed copies for several players, or nothing.
- `SendMessageAsync(target, message)` queues a message for a profile via ProfileStore.
- `OnMessage(handler)` handles messages for loaded profiles and returns a disconnect function.
- `SaveAsync(player)` forces `profile:Save()` for critical checkpoints.
- `PreviewRollbackAsync(target, selector?)` reads a historical version without writing.
- `ApplyRollbackAsync(preview)` applies a preview once without a second version read.
- `RollbackAsync(target, selector?)` restores a historical version.
- `WipeAsync(target)` permanently removes the configured ProfileStore key.
- `IsReady(player)` reports whether the player's profile is loaded.
- `Destroy()` ends active sessions and disconnects listeners.

### Client

- `Client.new(config?)` connects to replication remotes and requests the initial snapshot. Pass `template` to type it.
- `Ready` resolves with the initial profile snapshot.
- `GetData()` returns the local snapshot, if loaded.
- `GetDataState()` returns the underlying Fusion state.
- `GetDataAsync(timeout?)` yields for the initial snapshot.
- `Read(path)` reads a value from the local snapshot.
- `IsReady()` reports whether the initial snapshot has arrived.
- `OnReady(callback)` runs a callback once the snapshot is ready.
- `WatchPath(path)` creates a typed watcher for Fusion UI code.
- `OnChanged(path, callback)` subscribes to one path and returns a disconnect function.
- `Destroy()` disconnects listeners and cleans up the Fusion scope.

### Path

- `Path.tree(template)` returns the typed path tree for your data.
- `Path.write(path, value)` builds a typed entry for `BatchSetValues`.
- `Path.keyOf(path)` returns the dot-joined key used by `DataUpdated`.
- `Path.is(value)` reports whether a value is a path.

### Types

The package exports `Server<Data>`, `Client<Data>`, `Path<Data, V>`, `PathTree<Data>`, `ReadOnly<T>`, `Profile<Data>`, `ServerConfig<Data>`, `ClientConfig<Data>`, `Watcher<V>`, and related types, e.g. `EZProfileStore.Server<Data>`.

## ProfileStore Notes

EZProfileStore follows ProfileStore's session model. `StartSessionAsync` can fail, sessions must end when players leave, and direct edits are safe only while a profile is active. ProfileStore already auto-saves and performs a final save when `EndSession()` runs, so call `SaveAsync` only for high-value checkpoints such as product receipts.

For lower-level behavior, see the official [ProfileStore API documentation](https://madstudioroblox.github.io/ProfileStore/api/).

## License

MIT
