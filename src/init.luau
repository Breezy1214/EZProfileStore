--!strict
--[=[
	@class EZProfileStore

	A ProfileStore wrapper with automatic client replication.

	- [Server](/api/Server) — manages profile sessions and replicates updates to clients.
	- [Client](/api/Client) — mirrors the player's profile and exposes path-based observers.
]=]

return {
	Server = require(script.Server),
	Client = require(script.Client),
}
