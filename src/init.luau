--!strict
--[=[
	@class EZProfileStore

	Package entrypoint; `Server`, `Client`, and `Migrations` load lazily.
]=]

local Path = require(script.Path)
local Types = require(script.Types)

export type Path<Data, V> = Path.Path<Data, V>
export type AnyPath<Data> = Path.AnyPath<Data>
export type PathTree<Data> = Path.PathTree<Data>
export type ReadOnly<T> = Path.ReadOnly<T>
export type Write<Data> = Path.Write<Data>

export type Server<Data> = Types.Server<Data>
export type ServerConfig<Data> = Types.ServerConfig<Data>
export type Profile<Data> = Types.Profile<Data>
export type ProfileStore<Data> = Types.ProfileStore<Data>
export type LeaderstatEntry<Data> = Types.LeaderstatEntry<Data>
export type Target = Types.Target
export type VersionSelector = Types.VersionSelector
export type RollbackResult = Types.RollbackResult
export type MessageHandler = Types.MessageHandler
export type Client<Data> = Types.Client<Data>
export type ClientConfig<Data> = Types.ClientConfig<Data>
export type Ready<T> = Types.Ready<T>
export type Watcher<V> = Types.Watcher<V>

type Package = {
	Path: typeof(Path),
	Server: typeof(require(script.Server)),
	Client: typeof(require(script.Client)),
	Migrations: typeof(require(script.Migrations)),
}

local LAZY_MODULES: { [string]: true } = {
	Server = true,
	Client = true,
	Migrations = true,
}
table.freeze(LAZY_MODULES)

local requireModule: (module: ModuleScript) -> unknown = require

local EZProfileStore: { [string]: unknown } = {
	Path = Path,
}

local function loadModule(name: string): unknown
	local child = script:FindFirstChild(name)
	if not child or not child:IsA("ModuleScript") then
		error(`EZProfileStore: missing module "{name}"`, 3)
	end

	local module = requireModule(child)
	rawset(EZProfileStore, name, module)
	return module
end

setmetatable(EZProfileStore, {
	__index = function(_, key: unknown): unknown
		if typeof(key) == "string" and LAZY_MODULES[key] then
			return loadModule(key)
		end
		return nil
	end,
})

return (EZProfileStore :: unknown) :: Package
