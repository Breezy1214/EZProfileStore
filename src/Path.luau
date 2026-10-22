--!strict
--[=[
	@class Path

	Typed key paths into profile data, generated from your template.
]=]

--[=[
	@interface Path

	A path to a value of type `V` inside `Data`.
	@within Path
	.__key string -- Segments joined with `"."`.
	.__keys { string } -- Frozen path segments.
]=]
export type Path<Data, V> = {
	read __key: string,
	read __keys: { string },
	read __data: (Data) -> (),
	read __value: (V) -> V,
}

--[=[
	@interface AnyPath
	@within Path
	A path into `Data` whose value type does not matter, such as a `privatePaths` entry.
]=]
export type AnyPath<Data> = {
	read __key: string,
	read __keys: { string },
	read __data: (Data) -> (),
	read __value: (never) -> unknown,
}

--[=[
	@interface Write
	@within Path
	A type-checked set operation for `Server:BatchSetValues`, made with `Path.write`.
]=]
export type Write<Data> = {
	read path: AnyPath<Data>,
	read value: unknown,
	read __write: (Data) -> (),
}

--[=[
	@type PathTree<Data> { [field]: Path<Data, V> & PathTree }

	One path per field of `Data`, indexable by key for `{ [string]: V }` dictionaries.
	@within Path
]=]
export type function PathTree(data: type)
	local keysType =
		types.newtable(nil, { index = types.number, readresult = types.string, writeresult = types.string })

	local function unwrapOptional(value: type): type
		if value:is("union") then
			local found: type? = nil
			for _, component in value:components() do
				if component:is("nil") then
					continue
				elseif found ~= nil then
					return value
				end
				found = component
			end
			return found or value
		end
		return value
	end

	local function node(value: type, isRoot: boolean, depth: number): type
		local result = types.newtable()
		if not isRoot then
			result:setreadproperty(types.singleton("__key"), types.string)
			result:setreadproperty(types.singleton("__keys"), keysType)
			result:setreadproperty(types.singleton("__data"), types.newfunction({ head = { data } }, {}))
			result:setreadproperty(
				types.singleton("__value"),
				types.newfunction({ head = { value } }, { head = { value } })
			)
		end

		local shape = unwrapOptional(value)
		if depth > 0 and shape:is("table") then
			for key, prop in shape:properties() do
				if prop.read then
					result:setreadproperty(key, node(prop.read, false, depth - 1))
				end
			end
			local indexer = shape:indexer()
			if indexer and indexer.index:is("string") then
				result:setindexer(types.string, node(indexer.readresult, false, depth - 1))
			end
		end
		return result
	end

	return node(data, true, 24)
end

--[=[
	@type ReadOnly<T> T

	`T` with every field read-only, recursively.
	@within Path
]=]
export type function ReadOnly(value: type)
	local function convert(current: type, depth: number): type
		if depth == 0 then
			return current
		elseif current:is("union") or current:is("intersection") then
			local components = {}
			for _, component in current:components() do
				table.insert(components, convert(component, depth - 1))
			end
			return if current:is("union")
				then types.unionof(table.unpack(components))
				else types.intersectionof(table.unpack(components))
		elseif not current:is("table") then
			return current
		end

		local result = types.newtable()
		for key, prop in current:properties() do
			if prop.read then
				result:setreadproperty(key, convert(prop.read, depth - 1))
			end
		end
		local indexer = current:indexer()
		if indexer then
			result:setindexer(indexer.index, convert(indexer.readresult, depth - 1))
		end
		return result
	end

	return convert(value, 24)
end

local Path = {}

local function noop(_: unknown) end

--[=[
	Returns whether `key` can be a path segment: a non-empty string without ".".
	@within Path
	@private
	@param key unknown
	@return boolean
]=]
function Path.isValidKey(key: unknown): boolean
	return typeof(key) == "string" and key ~= "" and string.find(key, ".", 1, true) == nil
end

local registry: { [unknown]: true } = setmetatable({}, { __mode = "k" })
local childCache: { [unknown]: { [string]: unknown } } = setmetatable({}, { __mode = "k" })
local WEAK_VALUES = table.freeze({ __mode = "v" })

local NodeMeta = {}

local function newNode(keys: { string }?): unknown
	local node: { [string]: unknown } = {}
	if keys then
		table.freeze(keys)
		node.__key = table.concat(keys, ".")
		node.__keys = keys
		registry[node] = true
	end
	setmetatable(node, NodeMeta)
	table.freeze(node)
	return node
end

function NodeMeta.__index(node: { [string]: unknown }, key: unknown): unknown
	local cache = childCache[node]
	local cached = if cache and typeof(key) == "string" then cache[key] else nil
	if cached ~= nil then
		return cached
	end

	if not Path.isValidKey(key) or string.sub(key :: string, 1, 2) == "__" then
		error(
			`EZProfileStore.Path: invalid key {tostring(key)}; keys must be non-empty strings without "." or a "__" prefix`,
			2
		)
	end

	if cache == nil then
		cache = setmetatable({}, WEAK_VALUES)
		childCache[node] = cache
	end
	local parentKeys = rawget(node, "__keys") :: { string }?
	local keys = if parentKeys then table.clone(parentKeys) else {}
	table.insert(keys, key :: string)
	local child = newNode(keys)
	cache[key :: string] = child
	return child
end

function NodeMeta.__newindex()
	error("EZProfileStore.Path: path trees are read-only", 2)
end

function NodeMeta.__tostring(node: { [string]: unknown }): string
	return `Path({rawget(node, "__key") or "<root>"})`
end

--[=[
	Returns the typed path tree for `template`'s type.
	@within Path
	@param template Data
	@return PathTree<Data>
]=]
function Path.tree<Data>(_template: Data): PathTree<Data>
	return newNode(nil) :: PathTree<Data>
end

--[=[
	Pairs a path with a value of its type for `Server:BatchSetValues`.
	@within Path
	@param path Path<Data, V>
	@param value V
	@return Write<Data>
]=]
function Path.write<Data, V>(path: Path<Data, V>, value: V): Write<Data>
	assert(Path.is(path), "Path.write expects a Path")
	return table.freeze({
		path = path,
		value = value,
		__write = noop,
	})
end

--[=[
	Returns a path's dot-joined key, as passed to `Server.DataUpdated`.
	@within Path
	@param path AnyPath<Data>
	@return string
]=]
function Path.keyOf<Data>(path: AnyPath<Data>): string
	assert(Path.is(path), "Path.keyOf expects a Path")
	return path.__key
end

--[=[
	Returns whether `value` is a path node from `Path.tree`.
	@within Path
	@param value unknown
	@return boolean
]=]
function Path.is(value: unknown): boolean
	return registry[value] == true
end

return table.freeze(Path)
