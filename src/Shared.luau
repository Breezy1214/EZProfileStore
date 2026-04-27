--!strict
--[=[
	@class Shared
	@private

	Internal helpers shared between [Server] and [Client]: key-path
	resolution, path read/write utilities, and the names used to wire up
	the replication remotes.
]=]

local Shared = {}

Shared.REMOTE_FOLDER_NAME = "_EZProfileStore"
Shared.REMOTE_DATA_UPDATE = "DataUpdate"
Shared.REMOTE_REQUEST_DATA = "RequestData"

export type KeyPath = string | { string }

-- Wire-format tuple per replicated update:
--   { pathString }              → delete
--   { pathString, value }       → set
--   { pathString, value, true } → table.insert into array at path
export type Update = { any }
export type Batch = { Update }

local EMPTY_PATH: { string } = table.freeze({}) :: any

local PATH_CACHE_LIMIT = 256
local _pathCache: { [string]: { string } } = {}
local _pathCacheSize = 0

--[=[
	Resolves a `KeyPath` to its array form. String paths are split on `.` and
	cached. The returned array must be treated as read-only.

	@private
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
	Returns the canonical `.`-joined wire string for a `KeyPath`.

	@private
]=]
function Shared.toPathString(keyPath: KeyPath): string
	if typeof(keyPath) == "string" then
		return keyPath
	end
	return table.concat(keyPath, ".")
end

--[=[
	Reads the value at `path`. Returns `nil` if any segment fails to resolve.

	@private
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
	Mutates `root` in place, materializing missing intermediate tables.
	Returns `true` only when a real change is made:
	- set: `false` if the target already equals `value`.
	- insert: `false` if the target is not a table.
	- empty path: always `false`.

	@private
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
	value written at the leaf. Sibling subtrees keep reference identity so
	Fusion observers only re-evaluate along the changed spine.

	@private
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
