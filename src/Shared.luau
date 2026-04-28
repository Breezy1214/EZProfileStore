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

Shared.OP = table.freeze({
	Set = "set",
	Del = "del",
	Ins = "ins",
	AUpd = "aupd",
	ARm = "arm",
})

export type KeyPath = string | { string }

-- Wire-format tuple per replicated update (opcode-first):
--   { "set",  pathString, value }
--   { "del",  pathString }
--   { "ins",  pathString, value }
--   { "aupd", pathString, index, value }
--   { "arm",  pathString, index }
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
	- delete: `false` if the path is already missing.
	- insert: `false` if the target is missing or not a table.
	- empty path: always `false`.

	Missing parents are created only for non-nil set operations. Deletes and inserts are no-ops when their parent path does not exist.

	@private
]=]
function Shared.writePath(root: any, path: { string }, value: any, isInsert: boolean): boolean
	if #path == 0 then
		return false
	end

	local createMissingParents = not isInsert and value ~= nil
	local target: any = root
	for i = 1, #path - 1 do
		if typeof(target) ~= "table" then
			return false
		end

		local key = path[i]
		if typeof(target[key]) ~= "table" then
			if not createMissingParents then
				return false
			end
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

local function navigateToTable(root: any, path: { string }): any?
	local target: any = root
	for _, key in path do
		if typeof(target) ~= "table" then
			return nil
		end
		target = target[key]
	end
	if typeof(target) ~= "table" then
		return nil
	end
	return target
end

--[=[
	Replaces `arr[index]` at the array under `path`. Returns `false` when the
	target is missing/not a table, the index is out of bounds, or the path is empty.

	@private
]=]
function Shared.arrayUpdate(root: any, path: { string }, index: number, value: any): boolean
	if #path == 0 then
		return false
	end
	local arr = navigateToTable(root, path)
	if arr == nil then
		return false
	end
	if index < 1 or index > #arr then
		return false
	end
	arr[index] = value
	return true
end

--[=[
	Calls `table.remove(arr, index)` on the array under `path`. Returns `false`
	when the target is missing/not a table, the index is out of bounds, or the
	path is empty.

	@private
]=]
function Shared.arrayRemove(root: any, path: { string }, index: number): boolean
	if #path == 0 then
		return false
	end
	local arr = navigateToTable(root, path)
	if arr == nil then
		return false
	end
	if index < 1 or index > #arr then
		return false
	end
	table.remove(arr, index)
	return true
end

--[=[
	Returns a new root with the spine along `path` shallow-cloned and the
	value written at the leaf. Sibling subtrees keep reference identity so
	Fusion observers only re-evaluate along the changed spine.

	Missing parents are created only for non-nil set operations. Invalid deletes and inserts return the original root reference.

	@private
]=]
function Shared.writePathSpine<T>(root: T, path: { string }, value: any, isInsert: boolean): T
	if #path == 0 then
		return root
	end

	if isInsert or value == nil then
		local existing: any = root
		for i = 1, #path - 1 do
			if typeof(existing) ~= "table" then
				return root
			end
			existing = existing[path[i]]
		end

		if typeof(existing) ~= "table" then
			return root
		end

		local finalKey = path[#path]
		if isInsert then
			if typeof(existing[finalKey]) ~= "table" then
				return root
			end
		elseif existing[finalKey] == nil then
			return root
		end

		local newRoot: any = table.clone(root :: any)
		local target: any = newRoot
		for i = 1, #path - 1 do
			local key = path[i]
			target[key] = table.clone(target[key])
			target = target[key]
		end

		if isInsert then
			local newArr = table.clone(target[finalKey])
			table.insert(newArr, value)
			target[finalKey] = newArr
		else
			target[finalKey] = nil
		end

		return newRoot :: T
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
	target[finalKey] = value

	return newRoot :: T
end

--[=[
	Spine-clones the path down to the array, then replaces `arr[index]`.
	Returns the original root (reference-equal) when the target is missing,
	the index is out of bounds, or the path is empty.

	@private
]=]
function Shared.arrayUpdateSpine<T>(root: T, path: { string }, index: number, value: any): T
	if #path == 0 then
		return root
	end

	local existing: any = root
	for _, key in path do
		if typeof(existing) ~= "table" then
			return root
		end
		existing = existing[key]
	end
	if typeof(existing) ~= "table" or index < 1 or index > #existing then
		return root
	end

	local newRoot: any = if typeof(root) == "table" then table.clone(root :: any) else {}
	local target: any = newRoot
	for i = 1, #path - 1 do
		local key = path[i]
		target[key] = table.clone(target[key])
		target = target[key]
	end

	local finalKey = path[#path]
	local newArr = table.clone(target[finalKey])
	newArr[index] = value
	target[finalKey] = newArr

	return newRoot :: T
end

--[=[
	Spine-clones the path down to the array, then `table.remove`s at `index`.
	Returns the original root (reference-equal) when the target is missing,
	the index is out of bounds, or the path is empty.

	@private
]=]
function Shared.arrayRemoveSpine<T>(root: T, path: { string }, index: number): T
	if #path == 0 then
		return root
	end

	local existing: any = root
	for _, key in path do
		if typeof(existing) ~= "table" then
			return root
		end
		existing = existing[key]
	end
	if typeof(existing) ~= "table" or index < 1 or index > #existing then
		return root
	end

	local newRoot: any = if typeof(root) == "table" then table.clone(root :: any) else {}
	local target: any = newRoot
	for i = 1, #path - 1 do
		local key = path[i]
		target[key] = table.clone(target[key])
		target = target[key]
	end

	local finalKey = path[#path]
	local newArr = table.clone(target[finalKey])
	table.remove(newArr, index)
	target[finalKey] = newArr

	return newRoot :: T
end

return Shared
