--!strict
--[=[
	@class Shared
	@private

	Replication and immutable path helpers.
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

export type Update = { any }
export type Batch = { Update }
export type Snapshot = {
	seq: number,
	data: { [any]: any },
}

local EMPTY_PATH: { string } = table.freeze({}) :: any
local EMPTY_SEEN: { [any]: boolean } = table.freeze({}) :: any

local PATH_CACHE_LIMIT = 256
local _pathCache: { [string]: { string } } = {}
local _pathCacheSize = 0

function Shared.deepCopy(value: any): any
	if typeof(value) ~= "table" then
		return value
	end

	local result = {}
	for key, child in value do
		result[Shared.deepCopy(key)] = Shared.deepCopy(child)
	end
	return result
end

function Shared.deepEqual(left: any, right: any): boolean
	if left == right then
		return true
	end
	if typeof(left) ~= "table" or typeof(right) ~= "table" then
		return false
	end

	for key, value in left do
		if not Shared.deepEqual(value, right[key]) then
			return false
		end
	end
	for key in right do
		if left[key] == nil then
			return false
		end
	end
	return true
end

local SAVABLE_TYPES = table.freeze({
	boolean = true,
	number = true,
	string = true,
	table = true,
	buffer = true,
})

local function describePath(path: { any }): string
	return if #path == 0 then "" else ` at "{table.concat(path, ".")}"`
end

local function findUnsavable(value: any, path: { any }, seen: { [any]: boolean }): string?
	local valueType = typeof(value)
	if not SAVABLE_TYPES[valueType] then
		return `{valueType} cannot be saved{describePath(path)}`
	end

	if valueType == "number" then
		if value ~= value then
			return `NaN cannot be saved{describePath(path)}`
		elseif value == math.huge or value == -math.huge then
			return `infinity cannot be saved{describePath(path)}`
		end
		return nil
	elseif valueType == "string" then
		if utf8.len(value) == nil then
			return `malformed UTF-8 string cannot be saved{describePath(path)}`
		end
		return nil
	elseif valueType ~= "table" then
		return nil
	end

	if seen[value] then
		return `cyclic table cannot be saved{describePath(path)}`
	end
	seen[value] = true

	local arrayLength = #value
	local hasStringKeys = false
	local hasNumberKeys = false
	for key, child in value do
		if typeof(key) == "string" then
			if utf8.len(key) == nil then
				return `malformed UTF-8 key cannot be saved{describePath(path)}`
			end
			hasStringKeys = true
		elseif typeof(key) == "number" then
			if key % 1 ~= 0 or key < 1 or key > arrayLength then
				return `sparse or non-integer array key {key} cannot be saved{describePath(path)}`
			end
			hasNumberKeys = true
		else
			return `{typeof(key)} key cannot be saved{describePath(path)}`
		end

		if hasStringKeys and hasNumberKeys then
			return `mixed array/dictionary table cannot be saved{describePath(path)}`
		end

		table.insert(path, key)
		local reason = findUnsavable(child, path, seen)
		table.remove(path)
		if reason then
			return reason
		end
	end

	seen[value] = nil
	return nil
end

-- Rejects values DataStores cannot encode or remotes cannot replicate faithfully.
function Shared.validateValue(value: any): (boolean, string?)
	-- Scalars never touch `path` or `seen`, so skip allocating them on hot write paths.
	local isTable = typeof(value) == "table"
	local reason = findUnsavable(value, if isTable then {} else EMPTY_PATH, if isTable then {} else EMPTY_SEEN)
	return reason == nil, reason
end

-- Key path segments must be non-empty strings without ".".
function Shared.isValidKey(key: any): boolean
	return typeof(key) == "string" and key ~= "" and string.find(key, ".", 1, true) == nil
end

function Shared.isPathAddressable(value: any): boolean
	if typeof(value) ~= "table" then
		return false
	end
	for key in value do
		if not Shared.isValidKey(key) then
			return false
		end
	end
	return true
end

function Shared.isPrefix(prefix: { string }, path: { string }): boolean
	if #prefix > #path then
		return false
	end
	for i, key in prefix do
		if path[i] ~= key then
			return false
		end
	end
	return true
end

-- Returns `value` with `paths` removed, cloning only the affected spine.
function Shared.redact<T>(value: T, paths: { { string } }): T
	local result = value
	for _, path in paths do
		result = Shared.writePathSpine(result, path, nil, false)
	end
	return result
end

export type Change = { path: { string }, value: any }

local function diffInto(old: any, new: any, prefix: { string }, out: { Change })
	for key, newChild in new do
		local oldChild = old[key]
		if oldChild == newChild then
			continue
		end

		local path = table.clone(prefix)
		table.insert(path, key)
		if Shared.isPathAddressable(oldChild) and Shared.isPathAddressable(newChild) then
			diffInto(oldChild, newChild, path, out)
		elseif not Shared.deepEqual(oldChild, newChild) then
			table.insert(out, { path = path, value = newChild })
		end
	end

	for key in old do
		if new[key] == nil then
			local path = table.clone(prefix)
			table.insert(path, key)
			table.insert(out, { path = path, value = nil })
		end
	end
end

-- Minimal key-path changes that turn `old` into `new`; both roots must be path-addressable.
function Shared.diff(old: { [any]: any }, new: { [any]: any }): { Change }
	local out: { Change } = {}
	diffInto(old, new, {}, out)
	return out
end

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

function Shared.toPathString(keyPath: KeyPath): string
	if typeof(keyPath) == "string" then
		return keyPath
	end
	return table.concat(keyPath, ".")
end

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

-- Only non-nil set operations create missing parents.
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

function Shared.arrayUpdate(root: any, path: { string }, index: number, value: any): boolean
	if #path == 0 then
		return false
	end
	local arr = navigateToTable(root, path)
	if arr == nil then
		return false
	end
	if index % 1 ~= 0 or index < 1 or index > #arr then
		return false
	end
	arr[index] = value
	return true
end

function Shared.arrayRemove(root: any, path: { string }, index: number): boolean
	if #path == 0 then
		return false
	end
	local arr = navigateToTable(root, path)
	if arr == nil then
		return false
	end
	if index % 1 ~= 0 or index < 1 or index > #arr then
		return false
	end
	table.remove(arr, index)
	return true
end

-- Clones only the changed spine so unaffected Fusion dependencies keep identity.
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
