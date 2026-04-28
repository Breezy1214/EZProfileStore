# EZProfileStore

A [ProfileStore](https://github.com/MadStudioRoblox/ProfileStore) wrapper for Roblox with generic key-path updates and automatic client replication.

EZProfileStore handles profile session lifecycle on the server, mirrors each player's profile to a Fusion state object on the client, and exposes a small, pathwise API for both sides — so feature code reads and writes player data through one consistent surface.

## Features

- Drop-in profile lifecycle: sessions, reconciliation, first-join detection.
- Pathwise mutation: `UpdateData(player, "Currency.Coins", 100)` or `{ "Currency", "Coins" }`.
- Numeric helpers: `IncrementData` / `DecrementData`.
- Array index ops: `UpdateArrayItem`, `RemoveArrayItem`, plus existing `InsertData`.
- Generalized leaf removal: `RemoveData`.
- Atomic multi-write: `BatchSetValues({ { path, value }, ... })`.
- Coalesced replication: synchronous bursts of writes ship as a single network event per frame.
- Fusion-native client mirror: bind into Computeds or use `WatchPath` for path-scoped observers.
- Promise-based readiness: `client.Ready:andThen(...)` or yielding/callback wrappers.
- ProfileStore save signal forwards: `PreSave`, `PostSave`, `LastSave`.
- Convenience: `SaveAsync`, `WipeAsync`, `IsReady`.
- `leaderstats` Folder mirror — declare paths and the Roblox built-in player list updates automatically.

## Installation

Add to your [Wally](https://wally.run) manifest:

```toml
[dependencies]
EZProfileStore = "breezy1214/ezprofilestore@0.1.0"
```

Then run `wally install`.

## Quick Start

### Server

```lua
local EZProfileStore = require(Path.To.EZProfileStore)

local store = EZProfileStore.Server.new({
    storeName = "PlayerData_v1",
    template = {
        Coins = 0,
        Inventory = {},
    },
})

store.FirstJoin:Connect(function(player, data)
    data.Coins = 50
end)

store.ProfileLoaded:Connect(function(player, profile)
    print(player.Name, "loaded with", profile.Data.Coins, "coins")
end)

-- Replicated mutations
store:UpdateData(player, "Coins", 100)
store:UpdateData(player, { "Inventory", "SwordOfTruth" }, true)
store:InsertData(player, "Inventory", "Potion")
```

### Client

```lua
local EZProfileStore = require(Path.To.EZProfileStore)

local client = EZProfileStore.Client.new()

client.Ready:andThen(function(data)
    print("Initial coins:", data.Coins)
end)

-- Path-scoped observer backed by Fusion
local coinsWatcher = client:WatchPath("Coins")
coinsWatcher:onChange(function(newValue, oldValue)
    print("Coins:", oldValue, "->", newValue)
end)

-- One-shot read from the local snapshot
local coins = client:Read("Coins")
```

### Leaderstats

Declare which profile paths mirror to `Player.leaderstats` (the Roblox built-in player list):

```lua
local store = EZProfileStore.Server.new({
	storeName = "PlayerData_v1",
	template = { Coins = 0, Stats = { Wins = 0 } },
	leaderstats = {
		{ path = "Coins",      name = "Coins", type = "IntValue" },
		{ path = "Stats.Wins", name = "Wins",  type = "IntValue" },
	},
})
```

Any mutation that changes a tracked path — directly or via a parent write — is reflected in the corresponding `IntValue`/`NumberValue`/`StringValue` on the next frame's flush.

## API Reference

Full API documentation is published with [Moonwave](https://eryn.io/moonwave/).


## License

MIT
