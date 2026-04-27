--!strict
--[=[
	@class Server
	@server

	Server-side profile lifecycle + automatic client replication using raw
	RemoteEvents.

	Usage:

	```luau
	local EZProfileStore = require(Path.To.EZProfileStore)

	local store = EZProfileStore.Server.new({
		storeName = "PlayerData_v1",
		template = { Coins = 0, Inventory = {} },
	})

	store.ProfileLoaded:Connect(function(player, profile)
		print(player.Name, "loaded")
	end)

	store:UpdateData(somePlayer, "Coins", 100)
	store:UpdateData(somePlayer, { "Inventory", "SwordOfTruth" }, true)
	store:InsertData(somePlayer, "Inventory", "Potion") -- appends to Inventory
	```

	ProfileStore is bundled inside the package — no separate install or
	server-only realm dance required.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ProfileStore = require(script.Parent.Parent.ProfileStore)
local Shared = require(script.Parent.Shared)
local Signal = require(script.Parent.Parent.Signal)

local DEFAULT_KEY_PREFIX = "Player_"

export type Config = {
	storeName: string,
	template: { [any]: any },
	keyPrefix: string?,
	useMockInStudio: boolean?,
	remoteParent: Instance?,
}

export type Profile = any
export type Server = typeof(setmetatable(
	{} :: {
		_store: any,
		_keyPrefix: string,
		_profiles: { [Player]: Profile },
		_connections: { RBXScriptConnection },
		_remoteFolder: Folder,
		_dataInit: RemoteEvent,
		_dataUpdate: RemoteEvent,
		_requestData: RemoteFunction,
		_isDestroyed: boolean,
		ProfileLoaded: Signal.Signal<Player, Profile>,
		ProfileReleased: Signal.Signal<Player>,
		FirstJoin: Signal.Signal<Player, { [any]: any }>,
		DataUpdated: Signal.Signal<Player, Shared.KeyPath, any>,
	},
	{} :: { __index: any }
))

local Server = {}
Server.__index = Server

local function ensureChild(parent: Instance, name: string, className: string): Instance
	local existing = parent:FindFirstChild(name)
	if existing then
		if existing.ClassName ~= className then
			error(
				`EZProfileStore: existing child "{name}" under {parent:GetFullName()} is a {existing.ClassName}, expected {className}`,
				3
			)
		end
		return existing
	end
	local instance = Instance.new(className)
	instance.Name = name
	instance.Parent = parent
	return instance
end

local function ensureRemoteFolder(remoteParent: Instance): Folder
	return ensureChild(remoteParent, Shared.REMOTE_FOLDER_NAME, "Folder") :: Folder
end

--[=[
	Creates a new server-side store. Auto-binds `Players.PlayerAdded` and
	`Players.PlayerRemoving`, picks up players already in the server, and
	provisions the replication remotes under `ReplicatedStorage._EZProfileStore`
	(or under `config.remoteParent` if supplied).

	@within Server
]=]
function Server.new(config: Config): Server
	assert(typeof(config) == "table", "Server.new expects a config table")
	assert(typeof(config.storeName) == "string", "config.storeName must be a string")
	assert(typeof(config.template) == "table", "config.template must be a table")
	assert(RunService:IsServer(), "EZProfileStore.Server can only be required on the server")

	local store = ProfileStore.New(config.storeName, config.template)
	if config.useMockInStudio and RunService:IsStudio() then
		store = store.Mock
	end

	local remoteParent = config.remoteParent or ReplicatedStorage
	local remoteFolder = ensureRemoteFolder(remoteParent)
	local dataInit = ensureChild(remoteFolder, Shared.REMOTE_DATA_INIT, "RemoteEvent") :: RemoteEvent
	local dataUpdate = ensureChild(remoteFolder, Shared.REMOTE_DATA_UPDATE, "RemoteEvent") :: RemoteEvent
	local requestData = ensureChild(remoteFolder, Shared.REMOTE_REQUEST_DATA, "RemoteFunction") :: RemoteFunction

	local self = setmetatable({
		_store = store,
		_keyPrefix = config.keyPrefix or DEFAULT_KEY_PREFIX,
		_profiles = {},
		_connections = {},
		_remoteFolder = remoteFolder,
		_dataInit = dataInit,
		_dataUpdate = dataUpdate,
		_requestData = requestData,
		_isDestroyed = false,
		ProfileLoaded = Signal.new(),
		ProfileReleased = Signal.new(),
		FirstJoin = Signal.new(),
		DataUpdated = Signal.new(),
	}, Server) :: any

	requestData.OnServerInvoke = function(player: Player): { [any]: any }?
		local profile = self._profiles[player]
		return profile and profile.Data or nil
	end

	table.insert(
		self._connections,
		Players.PlayerAdded:Connect(function(player)
			self:_onPlayerAdded(player)
		end)
	)

	table.insert(
		self._connections,
		Players.PlayerRemoving:Connect(function(player)
			self:_onPlayerRemoving(player)
		end)
	)

	for _, player in Players:GetPlayers() do
		task.spawn(function()
			self:_onPlayerAdded(player)
		end)
	end

	return self
end

function Server._onPlayerAdded(self: Server, player: Player)
	if self._isDestroyed then
		return
	end

	local key = self._keyPrefix .. tostring(player.UserId)
	local profile = self._store:StartSessionAsync(key, {
		Cancel = function()
			return player.Parent ~= Players
		end,
	})

	if not profile then
		player:Kick("Failed to load data, please rejoin")
		return
	end

	profile:AddUserId(player.UserId)
	profile:Reconcile()

	if not player:IsDescendantOf(Players) then
		profile:EndSession()
		return
	end

	self._profiles[player] = profile

	profile.OnSessionEnd:Connect(function()
		self._profiles[player] = nil
		self.ProfileReleased:Fire(player)
		if player.Parent == Players then
			player:Kick("Profile session ended - please rejoin")
		end
	end)

	local isFirstJoin = profile.Data._ezpsCreatedAt == nil
	if isFirstJoin then
		profile.Data._ezpsCreatedAt = os.time()
		self.FirstJoin:Fire(player, profile.Data)
	end

	self.ProfileLoaded:Fire(player, profile)
	self._dataInit:FireClient(player, profile.Data)
end

function Server._onPlayerRemoving(self: Server, player: Player)
	local profile = self._profiles[player]
	if profile then
		profile:EndSession()
	end
end

--[=[
	Returns the underlying ProfileStore profile, or nil if the profile hasn't
	loaded yet.

	@within Server
]=]
function Server.GetProfile(self: Server, player: Player): Profile?
	return self._profiles[player]
end

--[=[
	Returns the player's data table (a reference into profile.Data), or nil
	if the profile hasn't loaded yet.

	Mutating this table directly persists on the next save but does NOT
	replicate to the client. Use `UpdateData` for changes that should
	replicate.

	@within Server
]=]
function Server.GetData(self: Server, player: Player): { [any]: any }?
	local profile = self._profiles[player]
	return profile and profile.Data
end

--[=[
	Reads a value at a key path without mutating. Returns nil if the path
	doesn't resolve.

	@within Server
]=]
function Server.ReadData(self: Server, player: Player, keyPath: Shared.KeyPath): any
	local data = self:GetData(player)
	if not data then
		return nil
	end
	return Shared.readPath(data, Shared.resolveKeyPath(keyPath))
end

--[=[
	Sets a value at a key path. Accepts dot-notation strings (`"Currency.Coins"`)
	or array paths (`{ "Currency", "Coins" }`).

	Returns true if the value was actually changed, false if it was already
	equal. Replication and `DataUpdated` only fire on real changes.

	@within Server
]=]
function Server.UpdateData(self: Server, player: Player, keyPath: Shared.KeyPath, value: any): boolean
	local data = self:GetData(player)
	if not data then
		return false
	end

	local path = Shared.resolveKeyPath(keyPath)
	if not Shared.writePath(data, path, value, false) then
		return false
	end

	local payload: Shared.UpdatePayload = {
		keyPath = path,
		value = value,
	}
	self._dataUpdate:FireClient(player, payload)
	self.DataUpdated:Fire(player, keyPath, value)
	return true
end

--[=[
	Appends `value` to the array at `keyPath` via `table.insert`. The target
	must already be a table; if it isn't, this warns and returns false
	without firing replication.

	@within Server
]=]
function Server.InsertData(self: Server, player: Player, keyPath: Shared.KeyPath, value: any): boolean
	local data = self:GetData(player)
	if not data then
		return false
	end

	local path = Shared.resolveKeyPath(keyPath)
	if not Shared.writePath(data, path, value, true) then
		warn(`EZProfileStore: InsertData target at "{table.concat(path, ".")}" is not a table`)
		return false
	end

	local payload: Shared.UpdatePayload = {
		keyPath = path,
		value = value,
		isInsert = true,
	}
	self._dataUpdate:FireClient(player, payload)
	self.DataUpdated:Fire(player, keyPath, value)
	return true
end

--[=[
	Releases all sessions, disconnects player listeners, and cleans up
	signals. The replication remotes under ReplicatedStorage are left in
	place so the client side does not break if you re-create the store.

	@within Server
]=]
function Server.Destroy(self: Server)
	if self._isDestroyed then
		return
	end
	self._isDestroyed = true

	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)

	for player, profile in self._profiles do
		profile:EndSession()
		self._profiles[player] = nil
	end

	self._requestData.OnServerInvoke = function()
		return nil
	end

	self.ProfileLoaded:Destroy()
	self.ProfileReleased:Destroy()
	self.FirstJoin:Destroy()
	self.DataUpdated:Destroy()
end

return Server
