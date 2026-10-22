--!strict
--[=[
	@class Client
	@client

	Read-only, reactive mirror of the local player's profile.
]=]

--[=[
	@interface Config
	@within Client
	.remoteParent Instance? -- Parent of the replication folder. Defaults to `ReplicatedStorage`.
	.waitTimeout number? -- Seconds to wait for the replication remotes. Defaults to `30`.
	.template Data? -- Your shared template. Only used to infer `Data`; never read at runtime.
]=]

--[=[
	@prop Ready Ready<ReadOnly<Data>>
	@within Client
	Resolves with the initial snapshot.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Fusion = require(script.Parent.Parent.Fusion)
local Shared = require(script.Parent.Shared)
local Types = require(script.Parent.Types)
local Promise = (require(script.Parent.Parent.Promise) :: unknown) :: Types.PromiseLibrary

local DEFAULT_WAIT_TIMEOUT = 30
local MAX_PENDING_ENTRIES = 1024

type Table = Shared.Table

export type Config<Data> = Types.ClientConfig<Data>
export type Disconnect = Types.Disconnect
export type Ready<T> = Types.Ready<T>
export type Selection<V> = Types.Selection<V>
export type Client<Data> = Types.Client<Data>

type PendingBatch = {
	seq: number,
	batch: { unknown },
}

local Client = {}
Client.__index = Client

local Selection = {}
Selection.__index = Selection

type SelectionImpl = typeof(setmetatable(
	{} :: {
		State: Fusion.Computed<unknown>,
		_scope: Fusion.Scope<typeof(Fusion)>,
	},
	Selection
))

local function deepFreeze<T>(value: T): T
	local tbl = Shared.asTable(value)
	if tbl ~= nil and not table.isfrozen(tbl) then
		for _, child in tbl do
			deepFreeze(child)
		end
		table.freeze(tbl)
	end
	return value
end

type Self = typeof(setmetatable(
	{} :: {
		_dataValue: Fusion.Value<Table?>,
		_seq: number,
		_pendingBatches: { PendingBatch },
		_pendingEntryCount: number,
		_overflowWarned: boolean,
		_connections: { RBXScriptConnection },
		_scope: Fusion.Scope<typeof(Fusion)>?,
		_resolveReady: (data: Table) -> (),
		_rejectReady: (reason: unknown) -> (),
		_isDestroyed: boolean,
		Ready: Types.Promise,
	},
	Client
))

local function waitForChild(parent: Instance, name: string, className: string, timeout: number): Instance
	local instance = parent:WaitForChild(name, timeout)
	if not instance then
		error(`EZProfileStore.Client: timed out waiting for "{name}" under {parent:GetFullName()}`, 3)
	end

	if instance.ClassName ~= className then
		error(`EZProfileStore.Client: "{name}" exists but is a {instance.ClassName}, expected {className}`, 3)
	end

	return instance
end

local function construct(config: Config<Table>?): Self
	assert(RunService:IsClient(), "EZProfileStore.Client can only be required on the client")
	local resolved: Config<Table> = config or {}
	local timeout = resolved.waitTimeout or DEFAULT_WAIT_TIMEOUT

	local remoteParent = resolved.remoteParent or ReplicatedStorage
	local folder = waitForChild(remoteParent, Shared.REMOTE_FOLDER_NAME, "Folder", timeout) :: Folder
	local dataUpdate = waitForChild(folder, Shared.REMOTE_DATA_UPDATE, "RemoteEvent", timeout) :: RemoteEvent
	local requestData = waitForChild(folder, Shared.REMOTE_REQUEST_DATA, "RemoteFunction", timeout) :: RemoteFunction

	local scope = Fusion.scoped(Fusion)

	local resolveReady: (data: Table) -> () = function() end
	local rejectReady: (reason: unknown) -> () = function() end
	local readyPromise = Promise.new(function(resolve, reject)
		resolveReady = resolve
		rejectReady = reject
	end)

	local dataValue: Fusion.Value<Table?> = scope:Value(nil :: Table?)
	local self: Self = setmetatable({
		_dataValue = dataValue,
		_seq = 0,
		_pendingBatches = {},
		_pendingEntryCount = 0,
		_overflowWarned = false,
		_connections = {},
		_scope = scope,
		_resolveReady = resolveReady,
		_rejectReady = rejectReady,
		_isDestroyed = false,
		Ready = readyPromise,
	}, Client)

	table.insert(
		self._connections,
		dataUpdate.OnClientEvent:Connect(function(seq: unknown, batch: unknown)
			self:_handleUpdate(seq, batch)
		end)
	)

	task.spawn(function()
		if self._isDestroyed or self:_isInitialized() then
			return
		end

		local ok, response = pcall(function(): unknown
			return requestData:InvokeServer()
		end)

		if not ok then
			local reason = `EZProfileStore.Client: snapshot request failed: {response}`
			warn(reason)
			self:_rejectInit(reason)
			return
		end

		if self._isDestroyed or self:_isInitialized() then
			return
		end

		local snapshot = Shared.asTable(response)
		local seq = if snapshot then snapshot.seq else nil
		local data = if snapshot then Shared.asTable(snapshot.data) else nil
		if typeof(seq) ~= "number" or data == nil then
			self:_rejectInit("EZProfileStore.Client: snapshot request returned no data")
			return
		end

		self:_handleInit({ seq = seq, data = data })
	end)

	return self
end

--[=[
	Creates the local profile mirror. Pass `template` to type it.
	@within Client
	@param config Config<Data>?
	@return Client<Data>
]=]
function Client.new<Data>(config: Config<Data>?): Client<Data>
	local self = construct((config :: unknown) :: Config<Table>?)
	return (self :: unknown) :: Client<Data>
end

function Client._isInitialized(self: Self): boolean
	return Fusion.peek(self._dataValue) ~= nil
end

function Client._rejectInit(self: Self, reason: unknown)
	if self._isDestroyed or self:_isInitialized() then
		return
	end

	self._rejectReady(reason)
end

function Client._handleInit(self: Self, snapshot: Shared.Snapshot)
	if self._isDestroyed or self:_isInitialized() then
		return
	end

	self._dataValue:set(deepFreeze(snapshot.data))
	self._seq = snapshot.seq

	local pending = self._pendingBatches
	self._pendingBatches = {}
	self._pendingEntryCount = 0
	for _, entry in pending do
		-- Batches at or below the snapshot sequence are already contained in it.
		if entry.seq > self._seq then
			self._seq = entry.seq
			self:_applyBatch(entry.batch)
		end
	end

	self._resolveReady(Fusion.peek(self._dataValue) or snapshot.data)
end

function Client._handleUpdate(self: Self, seq: unknown, payload: unknown)
	local batch = Shared.asArray(payload)
	if self._isDestroyed or typeof(seq) ~= "number" or batch == nil then
		return
	end

	if not self:_isInitialized() then
		local incoming = #batch
		if self._pendingEntryCount + incoming > MAX_PENDING_ENTRIES then
			if not self._overflowWarned then
				self._overflowWarned = true
				warn(
					`EZProfileStore.Client: pre-init update buffer full at {MAX_PENDING_ENTRIES} entries; later pre-snapshot updates were dropped`
				)
			end
			return
		end
		table.insert(self._pendingBatches, { seq = seq, batch = batch })
		self._pendingEntryCount += incoming
		return
	end

	if seq <= self._seq then
		return
	end
	self._seq = seq
	self:_applyBatch(batch)
end

-- Copy-on-write per batch: each table on a changed path is cloned once, written in place, and
-- frozen at the end, so untouched subtrees keep their identity for selections.
function Client._applyBatch(self: Self, batch: { unknown })
	local root = Fusion.peek(self._dataValue)
	if root == nil then
		return
	end

	local owned: { [Table]: true } = {}
	local function own(tbl: Table): Table
		if owned[tbl] then
			return tbl
		end
		local copy = table.clone(tbl)
		owned[copy] = true
		return copy
	end

	local received: { unknown } = {}
	for _, item in batch do
		local entry = Shared.asArray(item)
		local opcode = if entry then entry[1] else nil
		local pathStr = if entry then entry[2] else nil
		if
			typeof(pathStr) ~= "string"
			or (opcode ~= Shared.OP.Set and opcode ~= Shared.OP.Del and opcode ~= Shared.OP.Ins)
		then
			continue
		end
		local path = Shared.splitKey(pathStr)
		local value = if opcode == Shared.OP.Del then nil else (entry :: { unknown })[3]
		local isInsert = opcode == Shared.OP.Ins
		local existing = Shared.readPath(root, path)
		if #path == 0 or (isInsert and Shared.asTable(existing) == nil) or (value == nil and existing == nil) then
			continue
		end

		root = own(root :: Table)
		local target = root :: Table
		for i = 1, #path - 1 do
			local current = Shared.asTable(target[path[i]])
			local nextTarget = if current then own(current) else {}
			owned[nextTarget] = true
			target[path[i]] = nextTarget
			target = nextTarget
		end
		local finalKey = path[#path]
		if isInsert then
			local array = own(existing :: Table)
			array[#array + 1] = value
			target[finalKey] = array
		else
			target[finalKey] = value
		end
		if typeof(value) == "table" then
			table.insert(received, value)
		end
	end

	for _, value in received do
		deepFreeze(value)
	end
	for tbl in owned do
		table.freeze(tbl)
	end
	self._dataValue:set(root)
end

-- A promise that follows `Ready`; cancelling or timing it out leaves the shared `Ready` untouched.
local function followReady(self: Self): Types.Promise
	return Promise.new(function(resolve, reject)
		self.Ready:andThen(resolve, reject)
	end)
end

--[=[
	Returns the read-only snapshot, if loaded.
	@within Client
	@method Get
	@return ReadOnly<Data>?
]=]
function Client.Get(self: Self): Table?
	return Fusion.peek(self._dataValue)
end

--[=[
	Yields for the initial snapshot. Errors if it fails to load or `timeout` elapses.
	@within Client
	@method GetAsync
	@yields
	@param timeout number? -- Waits until `Ready` settles by default.
	@return ReadOnly<Data>
]=]
function Client.GetAsync(self: Self, timeout: number?): Table
	local promise = if timeout == nil then self.Ready else followReady(self):timeout(timeout)
	return promise:expect() :: Table
end

--[=[
	Returns a live view of part of the data, e.g. `client:Select(function(data) return data.Coins end)`.
	@within Client
	@method Select
	@param selector (data: ReadOnly<Data>) -> V
	@return Selection<V>
]=]
function Client.Select(self: Self, selector: (data: Table) -> unknown): SelectionImpl
	assert(typeof(selector) == "function", "Select expects a selector function")
	local scope = self._scope
	assert(scope ~= nil, "EZProfileStore.Client was destroyed")

	local inner = scope:innerScope()
	local dataValue = self._dataValue
	local state = inner:Computed(function(use): unknown
		local data = use(dataValue)
		return if data == nil then nil else selector(data)
	end)
	return setmetatable({ State = state, _scope = inner }, Selection)
end

function Selection.Get(self: SelectionImpl): unknown
	return Fusion.peek(self.State)
end

function Selection.Observe(self: SelectionImpl, callback: (new: unknown, old: unknown) -> ()): Disconnect
	local previous = Fusion.peek(self.State)
	local observerScope = self._scope:innerScope()
	observerScope:Observer(self.State):onChange(function()
		local current = Fusion.peek(self.State)
		if current == previous then
			return
		end
		local old = previous
		previous = current
		callback(current, old)
	end)
	return function()
		observerScope:doCleanup()
	end
end

function Selection.Destroy(self: SelectionImpl)
	self._scope:doCleanup()
end

--[=[
	Returns whether the initial snapshot is loaded.
	@within Client
	@method IsReady
	@return boolean
]=]
function Client.IsReady(self: Self): boolean
	return self.Ready:getStatus() == Promise.Status.Resolved
end

--[=[
	Calls `callback` once when the snapshot is ready.
	@within Client
	@method OnReady
	@param callback (data: ReadOnly<Data>) -> ()
	@return Disconnect
]=]
function Client.OnReady(self: Self, callback: (data: Table) -> ()): Disconnect
	local chain = followReady(self):andThen(function(data: unknown)
		callback(data :: Table)
	end)

	return function()
		chain:cancel()
	end
end

--[=[
	Disconnects listeners, releases state and selections, and rejects unresolved `Ready`.
	@within Client
	@method Destroy
]=]
function Client.Destroy(self: Self)
	if self._isDestroyed then
		return
	end
	self._isDestroyed = true

	self._rejectReady("EZProfileStore.Client was destroyed")

	for _, connection in self._connections do
		connection:Disconnect()
	end

	table.clear(self._connections)
	local scope = self._scope
	if scope then
		scope:doCleanup()
		self._scope = nil
	end
end

return Client
