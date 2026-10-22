--!strict
--[=[
	@class Shared
	@private

	Replication and immutable path helpers.
]=]

local Path = require(script.Parent.Path)

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

export type Table = { [unknown]: unknown }

export type Update = { unknown }
export type Batch = { Update }
export type Snapshot = {
	seq: number,
	data: Table,
}

local EMPTY_PATH: { string } = {}
local EMPTY_TRAIL: { string | number } = {}
local EMPTY_SEEN: { [unknown]: boolean } = {}
table.freeze(EMPTY_PATH)
table.freeze(EMPTY_TRAIL)
table.freeze(EMPTY_SEEN)

local PATH_CACHE_LIMIT = 256
local _pathCache: { [string]: { string } } = {}
local _pathCacheSize = 0

function Shared.asTable(value: unknown): Table?
	return if typeof(value) == "table" then value :: Table else nil
end

function Shared.asArray(value: unknown): { unknown }?
	return if typeof(value) == "table" then value :: { unknown } else nil
end

function Shared.deepCopy<T>(value: T): T
	local source = Shared.asTable(value)
	if source == nil then
		return value
	end

	local result: Table = {}
	for key, child in source do
		result[Shared.deepCopy(key)] = Shared.deepCopy(child)
	end
	return (result :: unknown) :: T
end

function Shared.deepEqual(left: unknown, right: unknown): boolean
	if left == right then
		return true
	end
	local leftTable, rightTable = Shared.asTable(left), Shared.asTable(right)
	if leftTable == nil or rightTable == nil then
		return false
	end

	for key, value in leftTable do
		if not Shared.deepEqual(value, rightTable[key]) then
			return false
		end
	end
	for key in rightTable do
		if leftTable[key] == nil then
			return false
		end
	end
	return true
end

local function describePath(path: { string | number }): string
	return if #path == 0 then "" else ` at "{table.concat(path, ".")}"`
end

local function findUnsavable(value: unknown, path: { string | number }, seen: { [unknown]: boolean }): string?
	if typeof(value) == "number" then
		if value ~= value then
			return `NaN cannot be saved{describePath(path)}`
		elseif value == math.huge or value == -math.huge then
			return `infinity cannot be saved{describePath(path)}`
		end
		return nil
	elseif typeof(value) == "string" then
		if utf8.len(value) == nil then
			return `malformed UTF-8 string cannot be saved{describePath(path)}`
		end
		return nil
	elseif typeof(value) == "boolean" or typeof(value) == "buffer" then
		return nil
	end

	local tbl = Shared.asTable(value)
	if tbl == nil then
		return `{typeof(value)} cannot be saved{describePath(path)}`
	end

	if seen[tbl] then
		return `cyclic table cannot be saved{describePath(path)}`
	end
	seen[tbl] = true

	local arrayLength = #tbl
	local hasStringKeys = false
	local hasNumberKeys = false
	for key, child in tbl do
		local segment: string | number
		if typeof(key) == "string" then
			if utf8.len(key) == nil then
				return `malformed UTF-8 key cannot be saved{describePath(path)}`
			end
			hasStringKeys = true
			segment = key
		elseif typeof(key) == "number" then
			if key % 1 ~= 0 or key < 1 or key > arrayLength then
				return `sparse or non-integer array key {key} cannot be saved{describePath(path)}`
			end
			hasNumberKeys = true
			segment = key
		else
			return `{typeof(key)} key cannot be saved{describePath(path)}`
		end

		if hasStringKeys and hasNumberKeys then
			return `mixed array/dictionary table cannot be saved{describePath(path)}`
		end

		table.insert(path, segment)
		local reason = findUnsavable(child, path, seen)
		table.remove(path)
		if reason then
			return reason
		end
	end

	seen[tbl] = nil
	return nil
end

-- Rejects values DataStores cannot encode or remotes cannot replicate faithfully.
function Shared.validateValue(value: unknown): (boolean, string?)
	-- Scalars never touch `path` or `seen`, so skip allocating them on hot write paths.
	local isTable = typeof(value) == "table"
	local reason = findUnsavable(value, if isTable then {} else EMPTY_TRAIL, if isTable then {} else EMPTY_SEEN)
	return reason == nil, reason
end

Shared.isValidKey = Path.isValidKey

function Shared.isPathAddressable(value: unknown): boolean
	local tbl = Shared.asTable(value)
	if tbl == nil then
		return false
	end
	for key in tbl do
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

export type Change = { path: { string }, key: string, value: unknown }

local function diffInto(old: Table, new: Table, prefix: { string }, out: { Change }): unknown
	local isRoot = #prefix == 0
	for key, newChild in new do
		local oldChild = old[key]
		if oldChild == newChild then
			continue
		elseif isRoot and not Shared.isValidKey(key) then
			return key
		end

		local path = table.clone(prefix)
		table.insert(path, key :: string)
		local oldTable, newTable = Shared.asTable(oldChild), Shared.asTable(newChild)
		if oldTable and newTable and Shared.isPathAddressable(oldTable) and Shared.isPathAddressable(newTable) then
			diffInto(oldTable, newTable, path, out)
		elseif not Shared.deepEqual(oldChild, newChild) then
			table.insert(out, { path = path, key = table.concat(path, "."), value = newChild })
		end
	end

	for key in old do
		if new[key] == nil then
			if isRoot and not Shared.isValidKey(key) then
				return key
			end
			local path = table.clone(prefix)
			table.insert(path, key :: string)
			table.insert(out, { path = path, key = table.concat(path, "."), value = nil })
		end
	end
	return nil
end

function Shared.diff(old: Table, new: Table): ({ Change }?, unknown)
	local out: { Change } = {}
	local invalidKey = diffInto(old, new, {}, out)
	if invalidKey ~= nil then
		return nil, invalidKey
	end
	return out, nil
end

function Shared.splitKey(keyPath: string): { string }
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

function Shared.resolvePath(input: unknown): ({ string }, string)
	if not Path.is(input) then
		error(`EZProfileStore: expected a Path from Path.tree, got {typeof(input)}`, 3)
	end
	local path = input :: Path.AnyPath<unknown>
	return path.__keys, path.__key
end

function Shared.readPath(data: unknown, path: { string }): unknown
	local current = data
	for _, key in path do
		local tbl = Shared.asTable(current)
		if tbl == nil then
			return nil
		end
		current = tbl[key]
	end
	return current
end

function Shared.readArray(root: unknown, path: { string }): { unknown }?
	return Shared.asArray(Shared.readPath(root, path))
end

-- Only non-nil set operations create missing parents.
function Shared.writePath(root: Table, path: { string }, value: unknown, isInsert: boolean): boolean
	if #path == 0 then
		return false
	end

	local createMissingParents = not isInsert and value ~= nil
	local target = root
	for i = 1, #path - 1 do
		local key = path[i]
		local child = Shared.asTable(target[key])
		if child == nil then
			if not createMissingParents then
				return false
			end
			child = {}
			target[key] = child
		end
		target = child :: Table
	end

	local finalKey = path[#path]
	if isInsert then
		local array = Shared.asArray(target[finalKey])
		if array == nil then
			return false
		end
		table.insert(array, value)
		return true
	end

	if target[finalKey] == value then
		return false
	end
	target[finalKey] = value
	return true
end

local function isArrayIndex(arr: { unknown }, index: number): boolean
	return index % 1 == 0 and index >= 1 and index <= #arr
end

function Shared.arrayUpdate(root: Table, path: { string }, index: number, value: unknown): boolean
	if #path == 0 then
		return false
	end
	local arr = Shared.readArray(root, path)
	if arr == nil or not isArrayIndex(arr, index) then
		return false
	end
	arr[index] = value
	return true
end

function Shared.arrayRemove(root: Table, path: { string }, index: number): boolean
	if #path == 0 then
		return false
	end
	local arr = Shared.readArray(root, path)
	if arr == nil or not isArrayIndex(arr, index) then
		return false
	end
	table.remove(arr, index)
	return true
end

local function cloneSpine(root: unknown, path: { string }): (Table, Table)
	local newRoot: Table = table.clone(Shared.asTable(root) or {})
	local target = newRoot
	for i = 1, #path - 1 do
		local key = path[i]
		local child: Table = table.clone(Shared.asTable(target[key]) or {})
		target[key] = child
		target = child
	end
	return newRoot, target
end

function Shared.writePathSpine<T>(root: T, path: { string }, value: unknown, isInsert: boolean): T
	if #path == 0 then
		return root
	end

	local finalKey = path[#path]
	if isInsert or value == nil then
		local existing = Shared.readPath(root, path)
		if if isInsert then Shared.asTable(existing) == nil else existing == nil then
			return root
		end
	end

	local newRoot, target = cloneSpine(root, path)
	if isInsert then
		local newArr = table.clone(target[finalKey] :: { unknown })
		table.insert(newArr, value)
		target[finalKey] = newArr
	else
		target[finalKey] = value
	end

	return (newRoot :: unknown) :: T
end

local function arraySpine<T>(root: T, path: { string }, index: number, value: unknown, isRemove: boolean): T
	if #path == 0 then
		return root
	end
	local existing = Shared.readArray(root, path)
	if existing == nil or not isArrayIndex(existing, index) then
		return root
	end

	local newRoot, target = cloneSpine(root, path)
	local finalKey = path[#path]
	local newArr = table.clone(existing)
	if isRemove then
		table.remove(newArr, index)
	else
		newArr[index] = value
	end
	target[finalKey] = newArr

	return (newRoot :: unknown) :: T
end

function Shared.arrayUpdateSpine<T>(root: T, path: { string }, index: number, value: unknown): T
	return arraySpine(root, path, index, value, false)
end

function Shared.arrayRemoveSpine<T>(root: T, path: { string }, index: number): T
	return arraySpine(root, path, index, nil, true)
end

return Shared
