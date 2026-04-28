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
- Studio-safe testing option through `ProfileStore.Mock`.

## Installation

Add the package to your [Wally](https://wally.run) manifest:

```toml
[dependencies]
EZProfileStore = "breezy1214/ezprofilestore@0.1.0"
```

Then run:

```sh
wally install
```

EZProfileStore depends on ProfileStore as a server dependency. In Rojo projects, mount `Packages` where shared/client code can require EZProfileStore and mount `ServerPackages` under a server-only service such as `ServerScriptService`.

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
	useMockInStudio = true,
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

## API Overview

### Server

- `Server.new(config)` creates the store and binds player lifecycle handlers.
- `GetProfile(player)` returns the ProfileStore profile, if loaded.
- `GetData(player)` returns the live profile data table, if loaded.
- `ReadData(player, keyPath)` reads a path without mutating.
- `UpdateData(player, keyPath, value)` sets a value. Passing `nil` deletes the path.
- `InsertData(player, keyPath, value)` appends to an array/table at a path.
- `IncrementData(player, keyPath, delta?)` and `DecrementData(player, keyPath, delta?)` update numeric values.
- `RemoveData(player, keyPath)` deletes a value without creating missing parent tables.
- `UpdateArrayItem(player, arrayPath, index, value)` replaces a 1-based array item.
- `RemoveArrayItem(player, arrayPath, index)` removes a 1-based array item with `table.remove`.
- `BatchSetValues(player, writes)` applies multiple set/delete writes in one replication batch.
- `SaveAsync(player)` forces `profile:Save()` for critical checkpoints.
- `WipeAsync(playerOrUserId)` removes the configured ProfileStore key.
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

## Documentation

Moonwave API docs are generated from comments in `src/`.

## License

MIT
