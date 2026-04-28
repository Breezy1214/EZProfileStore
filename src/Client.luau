--!strict
--[=[
	@class Client
	@client

	Mirrors the local player's profile in a Fusion state object and exposes read-only, path-based observers for UI code.

	[Client.Ready](#Ready) is a Promise that resolves with the initial
	snapshot. Use [Client:OnReady] or [Client:GetDataAsync] as callback or
	yielding alternatives.

	```lua
	local EZProfileStore = require(Path.To.EZProfileStore)

	local client = EZProfileStore.Client.new()

	client.Ready:andThen(function(data)
		print("Initial coins:", data.Coins)
	end)

	local coinsWatcher = client:WatchPath("Coins")
	coinsWatcher:onChange(function(newValue, oldValue)
		print("Coins:", oldValue, "->", newValue)
	end)

	local disconnect = client:OnChanged("Inventory", function(newValue)
		print("Inventory changed:", newValue)
	end)

	local coins = client:Read("Coins")
	```
]=]

--[=[
	@interface Config
	@within Client
	.remoteParent Instance? -- Parent of the replication folder. Defaults to `ReplicatedStorage`.
	.waitTimeout number? -- Seconds to wait for the replication remotes. Defaults to `30`.
]=]

--[=[
	@prop Ready Promise<{ [any]: any }>
	@within Client

	Resolves with the initial profile snapshot. Rejects if the client is destroyed or the server cannot provide a snapshot.
]=]

--[=[
	@prop Updated Signal<{ string }, any>
	@within Client

	Fires for each path/value pair applied from a server update. Path is the resolved array form. This signal is useful for diagnostics or broad observers; use [Client:WatchPath] or [Client:OnChanged] for most UI code.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Fusion = require(script.Parent.Parent.Fusion)
local PathWatcher = require(script.Parent.Parent.PathWatcher)
local Promise = require(script.Parent.Parent.Promise)
local Shared = require(script.Parent.Shared)
local Signal = require(script.Parent.Parent.Signal)

local DEFAULT_WAIT_TIMEOUT = 30
local MAX_PENDING_ENTRIES = 1024

export type Config = {
	remoteParent: Instance?,
	waitTimeout: number?,
}

export type Disconnect = () -> ()
export type PathWatcher = PathWatcher.PathWatcher

export type Client = typeof(setmetatable(
	{} :: {
		_dataValue: Fusion.Value<{ [any]: any }?>,
		_pendingBatches: { Shared.Batch },
		_pendingEntryCount: number,
		_overflowWarned: boolean,
		_connections: { RBXScriptConnection },
		_scope: any,
		_resolveReady: (data: { [any]: any }) -> (),
		_rejectReady: (reason: any) -> (),
		_isDestroyed: boolean,
		Ready: any,
		Updated: Signal.Signal<{ string }, any>,
	},
	{} :: { __index: any }
))

local Client = {}
Client.__index = Client

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

--[=[
	Connects to the server's replication remotes, requests the initial
	snapshot, and begins applying updates to the local Fusion mirror.

	@within Client
	@param config Config?
	@return Client
]=]
function Client.new(config: Config?): Client
	assert(RunService:IsClient(), "EZProfileStore.Client can only be required on the client")
	local resolved: Config = config or {}
	local timeout = resolved.waitTimeout or DEFAULT_WAIT_TIMEOUT

	local remoteParent = resolved.remoteParent or ReplicatedStorage
	local folder = waitForChild(remoteParent, Shared.REMOTE_FOLDER_NAME, "Folder", timeout) :: Folder
	local dataUpdate = waitForChild(folder, Shared.REMOTE_DATA_UPDATE, "RemoteEvent", timeout) :: RemoteEvent
	local requestData = waitForChild(folder, Shared.REMOTE_REQUEST_DATA, "RemoteFunction", timeout) :: RemoteFunction

	local scope = Fusion.scoped(Fusion)

	local resolveReady, rejectReady
	local readyPromise = Promise.new(function(resolve, reject)
		resolveReady = resolve
		rejectReady = reject
	end)

	local self = setmetatable({
		_dataValue = scope:Value(nil),
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
	}, Client) :: any

	table.insert(
		self._connections,
		dataUpdate.OnClientEvent:Connect(function(batch)
			self:_handleUpdate(batch)
		end)
	)

	task.spawn(function()
		if self._isDestroyed or self:_isInitialized() then
			return
		end

		local ok, snapshot = pcall(function()
			return requestData:InvokeServer()
		end)

		if not ok then
			local reason = `EZProfileStore.Client: snapshot request failed: {snapshot}`
			warn(reason)
			self:_rejectInit(reason)
			return
		end

		if self._isDestroyed or self:_isInitialized() then
			return
		end

		if snapshot == nil then
			self:_rejectInit("EZProfileStore.Client: snapshot request returned nil")
			return
		end

		self:_handleInit(snapshot)
	end)

	return self
end

function Client._isInitialized(self: Client): boolean
	return Fusion.peek(self._dataValue) ~= nil
end

function Client._rejectInit(self: Client, reason: any)
	if self._isDestroyed or self:_isInitialized() then
		return
	end

	self._rejectReady(reason)
end

function Client._handleInit(self: Client, data: { [any]: any })
	if self._isDestroyed or self:_isInitialized() then
		return
	end

	self._dataValue:set(data)

	if #self._pendingBatches > 0 then
		local pending = self._pendingBatches
		self._pendingBatches = {}
		self._pendingEntryCount = 0

		for _, batch in pending do
			self:_applyBatch(batch, false)
		end
	end

	self._resolveReady(Fusion.peek(self._dataValue))
end

function Client._handleUpdate(self: Client, batch: Shared.Batch)
	if self._isDestroyed or typeof(batch) ~= "table" then
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
		table.insert(self._pendingBatches, batch)
		self._pendingEntryCount += incoming
		return
	end

	self:_applyBatch(batch, true)
end

function Client._applyBatch(self: Client, batch: Shared.Batch, fireSignal: boolean)
	local current = Fusion.peek(self._dataValue)
	if current == nil then
		return
	end

	local newData: any = current
	local toFire: { any }? = if fireSignal then table.create(#batch * 2) else nil

	for _, entry in batch do
		local opcode = entry[1]
		local pathStr = entry[2]
		if typeof(opcode) ~= "string" or typeof(pathStr) ~= "string" then
			continue
		end

		local path = Shared.resolveKeyPath(pathStr)
		if #path == 0 then
			continue
		end

		local fireValue: any = nil
		if opcode == Shared.OP.Set then
			newData = Shared.writePathSpine(newData, path, entry[3], false)
			fireValue = entry[3]
		elseif opcode == Shared.OP.Del then
			newData = Shared.writePathSpine(newData, path, nil, false)
			fireValue = nil
		elseif opcode == Shared.OP.Ins then
			newData = Shared.writePathSpine(newData, path, entry[3], true)
			fireValue = entry[3]
		elseif opcode == Shared.OP.AUpd then
			newData = Shared.arrayUpdateSpine(newData, path, entry[3], entry[4])
			fireValue = entry[4]
		elseif opcode == Shared.OP.ARm then
			newData = Shared.arrayRemoveSpine(newData, path, entry[3])
			fireValue = nil
		else
			continue
		end

		if toFire then
			table.insert(toFire, path)
			table.insert(toFire, fireValue)
		end
	end

	self._dataValue:set(newData)

	if toFire then
		for i = 1, #toFire, 2 do
			self.Updated:Fire(toFire[i], toFire[i + 1])
		end
	end
end

--[=[
	Returns the local snapshot, or `nil` if the initial payload has not arrived. Treat the returned table as read-only. Client mutations are local only and will be overwritten by later server updates.

	@within Client
	@method GetData
	@return { [any]: any }?
]=]
function Client.GetData(self: Client): { [any]: any }?
	return Fusion.peek(self._dataValue)
end

--[=[
	Returns the underlying `Fusion.Value` holding the snapshot. Bind it into Computeds or hydrate UI directly. Treat the contained table as read-only.

	@within Client
	@method GetDataState
	@return Fusion.Value<{ [any]: any }?>
]=]
function Client.GetDataState(self: Client)
	return self._dataValue
end

--[=[
	Yields until the initial payload arrives, then returns it. Errors after `timeout` seconds. Use this when imperative code needs a loaded snapshot before continuing.

	@within Client
	@method GetDataAsync
	@yields
	@param timeout number? -- Defaults to `10`.
	@return { [any]: any }
]=]
function Client.GetDataAsync(self: Client, timeout: number?): { [any]: any }
	return self.Ready:timeout(timeout or 10):expect()
end

--[=[
	Reads the value at `keyPath` from the local snapshot. Returns `nil` if
	the path does not resolve or the snapshot has not loaded.

	@within Client
	@method Read
	@param keyPath KeyPath -- Dot-notation string or array of segments.
	@return any
]=]
function Client.Read(self: Client, keyPath: Shared.KeyPath): any
	local current = Fusion.peek(self._dataValue)
	if current == nil then
		return nil
	end
	return Shared.readPath(current, Shared.resolveKeyPath(keyPath))
end

--[=[
	Returns `true` once the initial payload has been received.

	@within Client
	@method IsReady
	@return boolean
]=]
function Client.IsReady(self: Client): boolean
	return self.Ready:getStatus() == Promise.Status.Resolved
end

--[=[
	Calls `callback` once with the initial snapshot. Runs on the next frame if already loaded, otherwise when the snapshot arrives. The returned function cancels the pending callback.

	@within Client
	@method OnReady
	@param callback (data: { [any]: any }) -> ()
	@return Disconnect
]=]
function Client.OnReady(self: Client, callback: (data: { [any]: any }) -> ()): Disconnect
	local chain = self.Ready:andThen(callback)
	return function()
		chain:cancel()
	end
end

--[=[
	Returns a `PathWatcher` bound to `keyPath` on the local Fusion mirror. Use the watcher's `.Value` inside Fusion Computeds or `:onChange(fn)` for callbacks. Call `:Destroy()` on the watcher when the UI owner unmounts.

	@within Client
	@method WatchPath
	@param keyPath KeyPath
	@return PathWatcher
]=]
function Client.WatchPath(self: Client, keyPath: Shared.KeyPath): PathWatcher
	return PathWatcher.new(self._dataValue :: any, keyPath)
end

--[=[
	Subscribes `callback` to changes at `keyPath`. Returns a disconnect
	function that destroys the underlying watcher.

	@within Client
	@method OnChanged
	@param keyPath KeyPath
	@param callback (newValue: any, oldValue: any) -> ()
	@return Disconnect
]=]
function Client.OnChanged(
	self: Client,
	keyPath: Shared.KeyPath,
	callback: (newValue: any, oldValue: any) -> ()
): Disconnect
	local watcher = self:WatchPath(keyPath)
	watcher:onChange(callback)
	return function()
		watcher:Destroy()
	end
end

--[=[
	Disconnects listeners, cleans up the Fusion scope, and rejects
	[Client.Ready](#Ready) if it has not yet resolved.

	@within Client
	@method Destroy
]=]
function Client.Destroy(self: Client)
	if self._isDestroyed then
		return
	end
	self._isDestroyed = true

	self._rejectReady("EZProfileStore.Client was destroyed")

	for _, connection in self._connections do
		connection:Disconnect()
	end

	table.clear(self._connections)
	if self._scope then
		self._scope:doCleanup()
		self._scope = nil
	end
	self.Updated:Destroy()
end

return Client
