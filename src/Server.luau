--!strict
--[=[
	@class Server
	@server

	Manages player profile sessions and replicates updates to connected clients.

	```lua
	local EZProfileStore = require(Path.To.EZProfileStore)

	local store = EZProfileStore.Server.new({
		storeName = "PlayerData_v1",
		template = { Coins = 0, Inventory = {} },
	})

	store.ProfileLoaded:Connect(function(player, profile)
		print(player.Name, "loaded")
	end)

	store:UpdateData(player, "Coins", 100)
	store:UpdateData(player, { "Inventory", "SwordOfTruth" }, true)
	store:InsertData(player, "Inventory", "Potion")
	```
]=]

--[=[
	@interface Config
	@within Server
	.storeName string -- Name passed to `ProfileStore.New`.
	.template { [any]: any } -- Default profile data for new players.
	.keyPrefix string? -- Profile key prefix. Defaults to `"Player_"`.
	.useMockInStudio boolean? -- Use the mock store when running in Studio.
	.remoteParent Instance? -- Parent for the replication folder. Defaults to `ReplicatedStorage`.
]=]

--[=[
	@prop ProfileLoaded Signal<Player, Profile>
	@within Server

	Fires after a player's profile loads successfully.
]=]

--[=[
	@prop ProfileReleased Signal<Player>
	@within Server

	Fires when a player's profile session ends.
]=]

--[=[
	@prop FirstJoin Signal<Player, { [any]: any }>
	@within Server

	Fires the first time a player loads a profile in this store. The data
	table is the freshly reconciled profile data and may be mutated
	synchronously to seed defaults.
]=]

--[=[
	@prop DataUpdated Signal<Player, KeyPath, any>
	@within Server

	Fires after a successful `UpdateData` or `InsertData` call.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ProfileStore = require(script.Parent.Parent.ProfileStore)
local Promise = require(script.Parent.Parent.Promise)
local Shared = require(script.Parent.Shared)
local Signal = require(script.Parent.Parent.Signal)

local DEFAULT_KEY_PREFIX = "Player_"
local SNAPSHOT_WAIT_TIMEOUT = 30

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
		_dataUpdate: RemoteEvent,
		_requestData: RemoteFunction,
		_isDestroyed: boolean,
		_pendingBatches: { [Player]: Shared.Batch },
		_flushScheduled: boolean,
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
	Creates a new server-side store. Binds player join/leave handlers,
	processes players already in the server, and provisions the replication
	remotes under `config.remoteParent` (defaults to `ReplicatedStorage`).

	@within Server
	@param config Config
	@return Server
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
	local dataUpdate = ensureChild(remoteFolder, Shared.REMOTE_DATA_UPDATE, "RemoteEvent") :: RemoteEvent
	local requestData = ensureChild(remoteFolder, Shared.REMOTE_REQUEST_DATA, "RemoteFunction") :: RemoteFunction

	local self = setmetatable({
		_store = store,
		_keyPrefix = config.keyPrefix or DEFAULT_KEY_PREFIX,
		_profiles = {},
		_connections = {},
		_remoteFolder = remoteFolder,
		_dataUpdate = dataUpdate,
		_requestData = requestData,
		_isDestroyed = false,
		_pendingBatches = {},
		_flushScheduled = false,
		ProfileLoaded = Signal.new(),
		ProfileReleased = Signal.new(),
		FirstJoin = Signal.new(),
		DataUpdated = Signal.new(),
	}, Server) :: any

	requestData.OnServerInvoke = function(player: Player): { [any]: any }?
		return self:_waitForData(player)
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

function Server._waitForData(self: Server, player: Player): { [any]: any }?
	if self._isDestroyed then
		return nil
	end

	local profile = self._profiles[player]
	if profile then
		return profile.Data
	end

	local ok = Promise.fromEvent(self.ProfileLoaded, function(loadedPlayer)
		return loadedPlayer == player
	end)
		:timeout(SNAPSHOT_WAIT_TIMEOUT)
		:await()

	if not ok or self._isDestroyed or player.Parent ~= Players then
		return nil
	end

	profile = self._profiles[player]
	return profile and profile.Data or nil
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
		self._pendingBatches[player] = nil
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
end

function Server._onPlayerRemoving(self: Server, player: Player)
	self._pendingBatches[player] = nil
	local profile = self._profiles[player]
	if profile then
		profile:EndSession()
	end
end

function Server._queueUpdate(self: Server, player: Player, pathStr: string, value: any, isInsert: boolean)
	local batch = self._pendingBatches[player]
	if not batch then
		batch = {}
		self._pendingBatches[player] = batch
	end

	if isInsert then
		local entry: Shared.Update = { pathStr, value, true }
		table.insert(batch, entry)
	else
		local coalesced = false
		for i = #batch, 1, -1 do
			local entry = batch[i]
			if entry[1] == pathStr then
				if entry[3] == true then
					-- Don't coalesce past an insert — would reorder ops.
					break
				end
				entry[2] = value
				coalesced = true
				break
			end
		end
		if not coalesced then
			local entry: Shared.Update = if value == nil then { pathStr } else { pathStr, value }
			table.insert(batch, entry)
		end
	end

	self:_scheduleFlush()
end

function Server._scheduleFlush(self: Server)
	if self._flushScheduled or self._isDestroyed then
		return
	end

	self._flushScheduled = true
	task.defer(function()
		self:_flushUpdates()
	end)
end

function Server._flushUpdates(self: Server)
	self._flushScheduled = false
	if self._isDestroyed then
		return
	end

	for player, batch in self._pendingBatches do
		if #batch > 0 and player.Parent == Players then
			self._dataUpdate:FireClient(player, batch)
		end
	end
	table.clear(self._pendingBatches)
end

--[=[
	Returns the underlying ProfileStore profile for `player`, or `nil` if no
	profile has loaded.

	@within Server
	@method GetProfile
	@param player Player
	@return Profile?
]=]
function Server.GetProfile(self: Server, player: Player): Profile?
	return self._profiles[player]
end

--[=[
	Returns the player's data table by reference, or `nil` if no profile has
	loaded.

	Direct mutations persist on the next save but do **not** replicate to the
	client. Use [Server:UpdateData] or [Server:InsertData] for replicated
	changes.

	@within Server
	@method GetData
	@param player Player
	@return { [any]: any }?
]=]
function Server.GetData(self: Server, player: Player): { [any]: any }?
	local profile = self._profiles[player]
	return profile and profile.Data
end

--[=[
	Reads the value at `keyPath`. Returns `nil` if the path does not resolve
	or the profile has not loaded.

	@within Server
	@method ReadData
	@param player Player
	@param keyPath KeyPath -- Dot-notation string or array of segments.
	@return any
]=]
function Server.ReadData(self: Server, player: Player, keyPath: Shared.KeyPath): any
	local data = self:GetData(player)
	if not data then
		return nil
	end
	return Shared.readPath(data, Shared.resolveKeyPath(keyPath))
end

--[=[
	Sets a value at `keyPath`. Accepts dot-notation strings
	(`"Currency.Coins"`) or array paths (`{ "Currency", "Coins" }`).

	Replication and the [Server.DataUpdated] signal only fire when the value
	actually changes. Replication is deferred to the end of the current frame,
	so synchronous bursts of writes are coalesced into a single network event.

	@within Server
	@method UpdateData
	@param player Player
	@param keyPath KeyPath
	@param value any
	@return boolean -- `true` if the value changed, `false` otherwise.
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

	self:_queueUpdate(player, Shared.toPathString(keyPath), value, false)
	self.DataUpdated:Fire(player, keyPath, value)
	return true
end

--[=[
	Appends `value` to the array at `keyPath`. The target must be a table; if
	it isn't, this warns and returns `false` without replicating.

	@within Server
	@method InsertData
	@param player Player
	@param keyPath KeyPath
	@param value any
	@return boolean -- `true` on success, `false` if the target is not a table.
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

	self:_queueUpdate(player, Shared.toPathString(keyPath), value, true)
	self.DataUpdated:Fire(player, keyPath, value)
	return true
end

--[=[
	Ends all active profile sessions, disconnects player listeners, and
	releases signals. The replication remotes are not removed.

	@within Server
	@method Destroy
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
	table.clear(self._pendingBatches)

	self._requestData.OnServerInvoke = function()
		return nil
	end

	self.ProfileLoaded:Destroy()
	self.ProfileReleased:Destroy()
	self.FirstJoin:Destroy()
	self.DataUpdated:Destroy()
end

return Server
