--!strict
--[=[
	@class Shared
	@private

	Internal utilities shared between the Server and Client modules:
	key-path resolution, path read/write helpers, and the well-known
	remote names used to wire up replication.
]=]

local Shared = {}

Shared.REMOTE_FOLDER_NAME = "_EZProfileStore"
Shared.REMOTE_DATA_UPDATE = "DataUpdate"
Shared.REMOTE_REQUEST_DATA = "RequestData"

export type KeyPath = string | { string }

-- Wire-format tuple per replicated update:
--   `{ pathString }`              → delete the key (value is nil)
--   `{ pathString, value }`       → set the value at that path
--   `{ pathString, value, true }` → table.insert `value` into the array at that path
--
-- A `Batch` is `{ Update, Update, ... }`. Sending positional tuples instead
-- of a `{ keyPath = ..., value = ..., isInsert = ... }` dictionary saves the
-- per-key serialization overhead Roblox pays on networked tables.
export type Update = { any }
export type Batch = { Update }

local EMPTY_PATH: { string } = table.freeze({}) :: any

local PATH_CACHE_LIMIT = 256
local _pathCache: { [string]: { string } } = {}
local _pathCacheSize = 0

--[=[
	Resolves a `KeyPath` to its array form. String paths are split on `.` and
	the result is cached so repeated `UpdateData(player, "Stats.XP", ...)` calls
	don't reallocate. The cache is bounded — if it fills, it's dropped wholesale
	rather than evicted entry-by-entry, which is fine because game key-paths are
	overwhelmingly static.

	Callers must treat the returned array as read-only.
]=]
function Shared.resolveKeyPath(keyPath: KeyPath): { string }
	if typeof(keyPath) == "string" then
		if keyPath == "" then
			return EMPTY_PATH
		end

		local cached = _pathCache[keyPath]
		if cached then
			return cached
		end

		local result = string.split(keyPath, ".")
		if _pathCacheSize >= PATH_CACHE_LIMIT then
			_pathCache = {}
			_pathCacheSize = 0
		end

		_pathCache[keyPath] = result
		_pathCacheSize += 1
		return result
	end
	return keyPath
end

--[=[
	Returns the canonical `.`-joined wire string for a `KeyPath`. String
	keypaths are returned untouched (already in wire form); array keypaths
	are concatenated.
]=]
function Shared.toPathString(keyPath: KeyPath): string
	if typeof(keyPath) == "string" then
		return keyPath
	end
	return table.concat(keyPath, ".")
end

--[=[
	Reads the value at a path. Returns nil if any segment doesn't resolve
	or the path passes through a non-table.
]=]
function Shared.readPath(data: any, path: { string }): any
	local current: any = data
	for _, key in path do
		if typeof(current) ~= "table" then
			return nil
		end
		current = current[key]
	end
	return current
end

--[=[
	Mutates `root` in place. Walks `path[1..#-1]`, materializing missing
	intermediate tables, then writes (or inserts) at `path[#path]`.

	Returns true if a real change was made:
	- Non-insert: false if `target[finalKey]` already equals `value`.
	- Insert: false if the target isn't a table (no-op).
	- Empty path: always false.
]=]
function Shared.writePath(root: any, path: { string }, value: any, isInsert: boolean): boolean
	if #path == 0 then
		return false
	end

	local target: any = root
	for i = 1, #path - 1 do
		local key = path[i]
		if typeof(target[key]) ~= "table" then
			target[key] = {}
		end
		target = target[key]
	end

	local finalKey = path[#path]
	if isInsert then
		if typeof(target[finalKey]) ~= "table" then
			return false
		end
		table.insert(target[finalKey], value)
		return true
	end

	if target[finalKey] == value then
		return false
	end
	target[finalKey] = value
	return true
end

--[=[
	Returns a new root with the spine along `path` shallow-cloned and the
	value written at the leaf. Sibling subtrees keep reference identity, so
	downstream Fusion observers only re-evaluate along the changed spine —
	avoids deep-cloning the entire profile on every replicated update.
]=]
function Shared.writePathSpine<T>(root: T, path: { string }, value: any, isInsert: boolean): T
	if #path == 0 then
		return root
	end

	local newRoot: any = if typeof(root) == "table" then table.clone(root :: any) else {}
	local target: any = newRoot

	for i = 1, #path - 1 do
		local key = path[i]
		local existing = target[key]
		target[key] = if typeof(existing) == "table" then table.clone(existing) else {}
		target = target[key]
	end

	local finalKey = path[#path]
	if isInsert then
		local arr = target[finalKey]
		if typeof(arr) == "table" then
			local newArr = table.clone(arr)
			table.insert(newArr, value)
			target[finalKey] = newArr
		end
	else
		target[finalKey] = value
	end

	return newRoot :: T
end

return Shared
