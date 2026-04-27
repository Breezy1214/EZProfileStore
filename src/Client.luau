--!strict
--[=[
	@class Client
	@client

	Client-side mirror of the player's profile, kept in sync via the remotes
	provisioned by `Server.new`. Maintains a Fusion-backed copy of
	`profile.Data`, queues updates that arrive before the initial payload, and
	exposes path watchers via the existing `breezy1214/pathwatcher` package.

	`client.Ready` is an `evaera/promise` Promise that resolves once with the
	initial snapshot — chain off it directly, or use `OnReady` / `GetDataAsync`
	for callback / yielding wrappers.

	Usage:

	```luau
	local EZProfileStore = require(Path.To.EZProfileStore)

	local client = EZProfileStore.Client.new()

	client.Ready:andThen(function(data)
		print("Initial coins:", data.Coins)
	end)

	-- Long-lived watcher backed by PathWatcher:
	local coinsWatcher = client:WatchPath("Coins")
	coinsWatcher:onChange(function(newValue, oldValue)
		print("Coins:", oldValue, "->", newValue)
	end)

	-- Or one-shot subscribe:
	local disconnect = client:OnChanged("Inventory", function(newValue)
		print("Inventory changed:", newValue)
	end)

	-- Snapshot reads:
	local coins = client:Read("Coins")
	```
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Fusion = require(script.Parent.Parent.Fusion)
local PathWatcher = require(script.Parent.Parent.PathWatcher)
local Promise = require(script.Parent.Parent.Promise)
local Shared = require(script.Parent.Shared)
local Signal = require(script.Parent.Parent.Signal)

local DEFAULT_WAIT_TIMEOUT = 30
local MAX_PENDING_UPDATES = 256

export type Config = {
	remoteParent: Instance?,
	waitTimeout: number?,
}

export type Disconnect = () -> ()
export type PathWatcher = PathWatcher.PathWatcher

export type Client = typeof(setmetatable(
	{} :: {
		_dataValue: Fusion.Value<{ [any]: any }?>,
		_pendingUpdates: { Shared.UpdatePayload },
		_connections: { RBXScriptConnection },
		_scope: any,
		_dataInit: RemoteEvent,
		_dataUpdate: RemoteEvent,
		_requestData: RemoteFunction,
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
	Connects to the replication remotes under `ReplicatedStorage._EZProfileStore`
	(or `config.remoteParent` if provided), pulls the initial snapshot via
	`RequestData`, and keeps the local Fusion mirror in sync.

	@within Client
]=]
function Client.new(config: Config?): Client
	assert(RunService:IsClient(), "EZProfileStore.Client can only be required on the client")
	local resolved: Config = config or {}
	local timeout = resolved.waitTimeout or DEFAULT_WAIT_TIMEOUT

	local remoteParent = resolved.remoteParent or ReplicatedStorage
	local folder = waitForChild(remoteParent, Shared.REMOTE_FOLDER_NAME, "Folder", timeout) :: Folder
	local dataInit = waitForChild(folder, Shared.REMOTE_DATA_INIT, "RemoteEvent", timeout) :: RemoteEvent
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
		_pendingUpdates = {},
		_connections = {},
		_scope = scope,
		_dataInit = dataInit,
		_dataUpdate = dataUpdate,
		_requestData = requestData,
		_resolveReady = resolveReady,
		_rejectReady = rejectReady,
		_isDestroyed = false,
		Ready = readyPromise,
		Updated = Signal.new(),
	}, Client) :: any

	table.insert(
		self._connections,
		dataInit.OnClientEvent:Connect(function(data)
			self:_handleInit(data)
		end)
	)

	table.insert(
		self._connections,
		dataUpdate.OnClientEvent:Connect(function(payload)
			self:_handleUpdate(payload)
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
			warn(`EZProfileStore.Client: snapshot request failed: {snapshot}`)
			return
		end

		if self._isDestroyed or self:_isInitialized() then
			return
		end

		if snapshot ~= nil then
			self:_handleInit(snapshot)
		end
	end)

	return self
end

function Client._isInitialized(self: Client): boolean
	return Fusion.peek(self._dataValue) ~= nil
end

function Client._handleInit(self: Client, data: { [any]: any })
	if self._isDestroyed or self:_isInitialized() then
		return
	end

	self._dataValue:set(data)

	if #self._pendingUpdates > 0 then
		local pending = self._pendingUpdates
		self._pendingUpdates = {}

		for _, payload in pending do
			self:_applyUpdate(payload, false)
		end
	end

	self._resolveReady(Fusion.peek(self._dataValue))
end

function Client._handleUpdate(self: Client, payload: Shared.UpdatePayload)
	if self._isDestroyed then
		return
	end

	if not self:_isInitialized() then
		if #self._pendingUpdates >= MAX_PENDING_UPDATES then
			return
		end

		table.insert(self._pendingUpdates, payload)
		return
	end

	self:_applyUpdate(payload, true)
end

function Client._applyUpdate(self: Client, payload: Shared.UpdatePayload, fireSignal: boolean)
	local current = Fusion.peek(self._dataValue)
	if current == nil then
		return
	end

	local path = payload.keyPath
	if #path == 0 then
		return
	end

	local newData = Shared.writePathSpine(current, path, payload.value, payload.isInsert == true)
	self._dataValue:set(newData)

	if fireSignal then
		self.Updated:Fire(path, payload.value)
	end
end

--[=[
	Returns the local snapshot, or nil if the initial payload hasn't arrived
	yet. Read freely; do not mutate.

	@within Client
]=]
function Client.GetData(self: Client): { [any]: any }?
	return Fusion.peek(self._dataValue)
end

--[=[
	Returns the underlying Fusion.Value for direct binding into Computeds /
	Hydrations elsewhere.

	@within Client
]=]
function Client.GetDataState(self: Client)
	return self._dataValue
end

--[=[
	Yields until the initial payload arrives, then returns it. Errors after
	`timeout` seconds (default 10).

	@within Client
]=]
function Client.GetDataAsync(self: Client, timeout: number?): { [any]: any }
	return self.Ready:timeout(timeout or 10):expect()
end

--[=[
	Reads the value at a key path from the local snapshot. Returns nil if
	the path doesn't resolve or the snapshot hasn't loaded yet.

	@within Client
]=]
function Client.Read(self: Client, keyPath: Shared.KeyPath): any
	local current = Fusion.peek(self._dataValue)
	if current == nil then
		return nil
	end
	return Shared.readPath(current, Shared.resolveKeyPath(keyPath))
end

--[=[
	Returns true if the initial payload has been received.

	@within Client
]=]
function Client.IsReady(self: Client): boolean
	return self.Ready:getStatus() == Promise.Status.Resolved
end

--[=[
	Calls `callback` with the initial snapshot. If already loaded, the
	callback runs on the next frame; otherwise it runs once when the
	snapshot arrives. Returns a disconnect function.

	@within Client
]=]
function Client.OnReady(self: Client, callback: (data: { [any]: any }) -> ()): Disconnect
	local chain = self.Ready:andThen(callback)
	return function()
		chain:cancel()
	end
end

--[=[
	Returns a `PathWatcher` from `breezy1214/pathwatcher` bound to the
	given key path on the local Fusion mirror. Use the watcher's `.Value`
	in Fusion Computeds, or `:onChange(fn)` for callbacks. Call `:Destroy()`
	on the watcher when done.

	@within Client
]=]
function Client.WatchPath(self: Client, keyPath: Shared.KeyPath): PathWatcher
	return PathWatcher.new(self._dataValue :: any, keyPath)
end

--[=[
	Convenience wrapper around `WatchPath`: subscribes `callback` to the
	resulting watcher and returns a disconnect function that destroys the
	watcher.

	@within Client
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
	Disconnects all listeners, cleans up the Fusion scope, and frees the
	local mirror.

	@within Client
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
