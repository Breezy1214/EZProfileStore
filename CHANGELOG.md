# Changelog

## 0.1.5 — 2026-10-22

EZProfileStore is now fully typed, and data is written through one API. On the server, `Update` hands you a typed draft of the player's data; edit it as plain Luau and only what changed replicates. On the client, `Select` reads a typed value and notifies you when it changes. Typing requires Luau's new type solver.

### Breaking

- The string-path methods are replaced by `Update` and `UpdateMany`. Removed: `UpdateData`, `InsertData`, `IncrementData`, `DecrementData`, `RemoveData`, `UpdateArrayItem`, `RemoveArrayItem`, `BatchSetValues`, `ReadData`, `Mutate`, and `MutateMany`.
- `GetData` / `GetDataAsync` are renamed `Get` / `GetAsync` on both server and client. The data they return is typed read-only.
- `DataUpdated` is replaced by `Changed(player, data)`, which fires once per committed `Update`.
- Client `Read`, `WatchPath`, `OnChanged`, `Updated`, and `GetDataState` are replaced by `Select(selector)`.
- `leaderstats` entries take a `value` selector instead of `path`.
- `privatePaths` takes selectors (`function(data) return data.Receipts end`) instead of string paths.
- `useMockInStudio` is removed. Use `mode = "studio"`.
- Migrations receive `RawData` (`{ [unknown]: unknown }`) instead of `{ [any]: any }`.
- The `PathWatcher` dependency is removed. The array opcodes (`aupd`, `arm`) are no longer sent.

### Added

- `Server:Update(player, transform)`: edit a draft, commit all-or-nothing. Return `false` to abort. Only touched sections are copied, and the commit sends the minimal set, delete, and append operations.
- `Server:UpdateMany(players, transform)`: atomic updates across players, such as trades.
- `Client:Select(selector)`: a `Selection` with `Get()`, `Observe(callback)`, a Fusion `State`, and `Destroy()`. Selectors can derive values.
- Client data is deep-frozen, so selections of unchanged tables don't re-notify.
- Derived leaderstats, e.g. `value = function(data) return data.Stats.Wins + data.Stats.Losses end`.
- `Server<Data>` and `Client<Data>` types inferred from the template. The package exports `Server`, `Client`, `Selection`, `ReadOnly`, `ServerConfig`, `Profile`, and related types.
- `Client.new({ template = template })` to type the client mirror.
- `autoLoadPlayers` config option. Set it to `false` in unit tests so stores don't start sessions for players in the game.

### Fixed

- A `StartSessionAsync` that throws now fires `ProfileLoadFailed` and kicks the player instead of leaving them waiting for data forever.
- A malformed entry in a replicated batch is skipped instead of aborting the whole batch.
- Leaderstats skip values of the wrong type instead of erroring.

### Migrating from 0.1.4

```lua
store:IncrementData(player, "Stats.Wins")                          -- before
store:BatchSetValues(player, { { path = "Coins", value = 0 } })

store:Update(player, function(data)                                 -- after
	data.Stats.Wins += 1
	data.Coins = 0
end)

client:OnChanged("Stats.Wins", function(new) print(new) end)        -- before

client:Select(function(data) return data.Stats.Wins end)            -- after
	:Observe(function(new) print(new) end)
```
