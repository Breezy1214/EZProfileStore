--!strict
--[=[
	@class EZProfileStore

	A ProfileStore wrapper with built-in client replication.

	- `EZProfileStore.Server` — server-side profile lifecycle, generic
	  key-path mutations, automatic per-player replication.
	- `EZProfileStore.Client` — client-side mirror with a Fusion-backed
	  data state, pending-update queue, and `WatchPath` returning a PathWatcher.
]=]

return {
	Server = require(script.Server),
	Client = require(script.Client),
}
