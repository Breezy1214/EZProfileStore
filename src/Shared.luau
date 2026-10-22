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

function Shared.isValidKey(key: unknown): boolean
	return typeof(key) == "string" and key ~= "" and string.find(key, ".", 1, true) == nil
end

local function isPathAddressable(tbl: Table): boolean
	for key in tbl do
		if not Shared.isValidKey(key) then
			return false
		end
	end
	return true
end

local function isSequence(value: Table): boolean
	local count = 0
	for _ in value do
		count += 1
	end
	return count == #value
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

export type Change = {
	op: string,
	path: { string },
	key: string,
	value: unknown,
}

local function pushChange(out: { Change }, op: string, path: { string }, value: unknown)
	table.insert(out, { op = op, path = table.clone(path), key = table.concat(path, "."), value = value })
end

local function isAppend(old: Table, new: Table): boolean
	if not isSequence(old) or not isSequence(new) or #new < #old then
		return false
	end
	for i = 1, #old do
		if not Shared.deepEqual(old[i], new[i]) then
			return false
		end
	end
	return true
end

-- Appends `old -> new` as minimal set/del/ins changes at `path` (used as a stack, restored on return).
-- Dictionaries recurse by key, arrays that only grew become inserts, anything else is replaced whole.
function Shared.diff(old: unknown, new: unknown, path: { string }, out: { Change })
	if old == new then
		return
	end

	local oldTable, newTable = Shared.asTable(old), Shared.asTable(new)
	if oldTable == nil or newTable == nil then
		pushChange(out, if new == nil then Shared.OP.Del else Shared.OP.Set, path, new)
		return
	end

	if isPathAddressable(oldTable) and isPathAddressable(newTable) then
		for key, value in newTable do
			table.insert(path, key :: string)
			Shared.diff(oldTable[key], value, path, out)
			table.remove(path)
		end
		for key in oldTable do
			if newTable[key] == nil then
				table.insert(path, key :: string)
				pushChange(out, Shared.OP.Del, path, nil)
				table.remove(path)
			end
		end
	elseif isAppend(oldTable, newTable) then
		for i = #oldTable + 1, #newTable do
			pushChange(out, Shared.OP.Ins, path, newTable[i])
		end
	elseif not Shared.deepEqual(oldTable, newTable) then
		pushChange(out, Shared.OP.Set, path, newTable)
	end
end

local traced: { [unknown]: { string } } = setmetatable({}, { __mode = "k" })
local TracerMeta = {}

local function tracer(keys: { string }): unknown
	local proxy = setmetatable({}, TracerMeta)
	traced[proxy] = keys
	return proxy
end

function TracerMeta.__index(proxy: unknown, key: unknown): unknown
	if not Shared.isValidKey(key) then
		error(`EZProfileStore: invalid key {tostring(key)} in selector`, 2)
	end
	local keys = table.clone(traced[proxy])
	table.insert(keys, key :: string)
	return tracer(keys)
end

-- Records the field path a selector like `function(data) return data.Admin.Notes end` reads.
function Shared.trace<Data>(selector: (data: Data) -> unknown): { string }
	local keys = traced[selector(tracer({}) :: Data)]
	if keys == nil or #keys == 0 then
		error("EZProfileStore: selector must return a field of data, e.g. function(data) return data.Coins end", 3)
	end
	return keys
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

-- Returns `value` with `paths` removed, cloning only the affected spine so untouched subtrees keep identity.
function Shared.redact<T>(value: T, paths: { { string } }): T
	local result: unknown = value
	for _, path in paths do
		if #path > 0 and Shared.readPath(result, path) ~= nil then
			local root = table.clone(result :: Table)
			local target = root
			for i = 1, #path - 1 do
				local nextTarget = table.clone(target[path[i]] :: Table)
				target[path[i]] = nextTarget
				target = nextTarget
			end
			target[path[#path]] = nil
			result = root
		end
	end
	return result :: T
end

return Shared
