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

--[=[
	@prop Updated Signal<{ string }, unknown>
	@within Client
	Fires for each replicated path update.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Fusion = require(script.Parent.Parent.Fusion)
local PathWatcher = require(script.Parent.Parent.PathWatcher)
local Shared = require(script.Parent.Shared)
local Signal = require(script.Parent.Parent.Signal)
local Types = require(script.Parent.Types)
local Promise = (require(script.Parent.Parent.Promise) :: unknown) :: Types.PromiseLibrary

local DEFAULT_WAIT_TIMEOUT = 30
local MAX_PENDING_ENTRIES = 1024

type Table = Shared.Table

export type Config<Data> = Types.ClientConfig<Data>
export type Disconnect = Types.Disconnect
export type Ready<T> = Types.Ready<T>
export type Watcher<V> = Types.Watcher<V>
export type Client<Data> = Types.Client<Data>

type PendingBatch = {
	seq: number,
	batch: { unknown },
}

local Client = {}
Client.__index = Client

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
		Updated: Signal.Signal<{ string }, unknown>,
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
		Updated = Signal.new(),
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

	self._dataValue:set(snapshot.data)
	self._seq = snapshot.seq

	local pending = self._pendingBatches
	self._pendingBatches = {}
	self._pendingEntryCount = 0
	for _, entry in pending do
		-- Batches at or below the snapshot sequence are already contained in it.
		if entry.seq > self._seq then
			self._seq = entry.seq
			self:_applyBatch(entry.batch, false)
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
	self:_applyBatch(batch, true)
end

function Client._applyBatch(self: Self, batch: { unknown }, fireSignal: boolean)
	local current = Fusion.peek(self._dataValue)
	if current == nil then
		return
	end

	local newData: Table = current
	local fired: { unknown }? = if fireSignal then table.create(#batch * 2) else nil

	for _, item in batch do
		local entry = Shared.asArray(item)
		if entry == nil then
			continue
		end
		local opcode, pathStr = entry[1], entry[2]
		if typeof(opcode) ~= "string" or typeof(pathStr) ~= "string" then
			continue
		end

		local path = Shared.splitKey(pathStr)
		if #path == 0 then
			continue
		end

		local arg, value = entry[3], entry[4]
		local fireValue: unknown = nil
		if opcode == Shared.OP.Set then
			newData = Shared.writePathSpine(newData, path, arg, false)
			fireValue = arg
		elseif opcode == Shared.OP.Del then
			newData = Shared.writePathSpine(newData, path, nil, false)
		elseif opcode == Shared.OP.Ins then
			newData = Shared.writePathSpine(newData, path, arg, true)
			fireValue = arg
		elseif opcode == Shared.OP.AUpd and typeof(arg) == "number" then
			newData = Shared.arrayUpdateSpine(newData, path, arg, value)
			fireValue = value
		elseif opcode == Shared.OP.ARm and typeof(arg) == "number" then
			newData = Shared.arrayRemoveSpine(newData, path, arg)
		else
			continue
		end

		if fired then
			table.insert(fired, path)
			table.insert(fired, fireValue)
		end
	end

	self._dataValue:set(newData)

	if fired then
		for i = 1, #fired, 2 do
			self.Updated:Fire(fired[i] :: { string }, fired[i + 1])
		end
	end
end

--[=[
	Returns the read-only snapshot, if loaded.
	@within Client
	@method GetData
	@return ReadOnly<Data>?
]=]
function Client.GetData(self: Self): Table?
	return Fusion.peek(self._dataValue)
end

--[=[
	Returns the snapshot's reactive state for Fusion. Treat it as read-only.
	@within Client
	@method GetDataState
	@return StateObject<ReadOnly<Data>?>
]=]
function Client.GetDataState(self: Self): Fusion.Value<Table?>
	return self._dataValue
end

--[=[
	Yields for the initial snapshot. Errors if it fails to load or `timeout` elapses.
	@within Client
	@method GetDataAsync
	@yields
	@param timeout number? -- Waits until `Ready` settles by default.
	@return ReadOnly<Data>
]=]
function Client.GetDataAsync(self: Self, timeout: number?): Table
	local promise = if timeout == nil
		then self.Ready
		else Promise.new(function(resolve, reject)
			self.Ready:andThen(resolve, reject)
		end):timeout(timeout)

	local data = Shared.asTable(promise:expect())
	assert(data ~= nil, "EZProfileStore.Client: snapshot is not a table")
	return data
end

--[=[
	Reads a path from the snapshot.
	@within Client
	@method Read
	@param path Path<Data, V>
	@return ReadOnly<V>?
]=]
function Client.Read(self: Self, path: unknown): unknown
	local current = Fusion.peek(self._dataValue)
	if current == nil then
		return nil
	end
	return Shared.readPath(current, (Shared.resolvePath(path)))
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
	local chain = Promise.new(function(resolve, reject)
		self.Ready:andThen(resolve, reject)
	end):andThen(function(data: unknown)
		local snapshot = Shared.asTable(data)
		if snapshot then
			callback(snapshot)
		end
	end)

	return function()
		chain:cancel()
	end
end

--[=[
	Creates a caller-owned watcher for `path`; destroy it after use.
	@within Client
	@method WatchPath
	@param path Path<Data, V>
	@return Watcher<V>
]=]
function Client.WatchPath(self: Self, path: unknown): PathWatcher.PathWatcher
	local keys = Shared.resolvePath(path)
	local source = (self._dataValue :: unknown) :: Fusion.Value<{ any }>
	return PathWatcher.new(source, keys, nil)
end

--[=[
	Subscribes to a path and returns a disconnect function.
	@within Client
	@method OnChanged
	@param path Path<Data, V>
	@param callback (newValue: ReadOnly<V>?, oldValue: ReadOnly<V>?) -> ()
	@return Disconnect
]=]
function Client.OnChanged(self: Self, path: unknown, callback: (newValue: unknown, oldValue: unknown) -> ()): Disconnect
	local watcher = self:WatchPath(path)
	watcher:onChange(callback)
	return function()
		watcher:Destroy()
	end
end

--[=[
	Disconnects listeners, releases state, and rejects unresolved `Ready`.
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
	self.Updated:Destroy()
end

return Client
