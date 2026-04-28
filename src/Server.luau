--!strict
--[=[
	@class Server
	@server

	Owns ProfileStore sessions for players, exposes path-based mutation helpers, and replicates server-side changes to each player's client mirror.

	`Server.new` connects `Players.PlayerAdded` and `Players.PlayerRemoving` for you. Mutations made through `UpdateData`, `InsertData`, `IncrementData`, `DecrementData`, `RemoveData`, `UpdateArrayItem`, `RemoveArrayItem`, and `BatchSetValues` are persisted through ProfileStore and replicated to the owning client.

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
	.template { [any]: any } -- Default profile data passed to `ProfileStore.New`.
	.keyPrefix string? -- Profile key prefix. Defaults to `"Player_"`.
	.useMockInStudio boolean? -- Use `ProfileStore.Mock` in Studio.
	.remoteParent Instance? -- Parent for the replication folder. Defaults to `ReplicatedStorage`.
	.leaderstats { LeaderstatEntry }? -- Profile paths to mirror into `Player.leaderstats`.
]=]

--[=[
	@interface LeaderstatEntry
	@within Server
	.path KeyPath -- Profile data path to mirror.
	.name string -- Value object name under `Player.leaderstats`.
	.type "IntValue" | "NumberValue" | "StringValue" -- Value object class.
]=]

--[=[
	@prop ProfileLoaded Signal<Player, Profile>
	@within Server

	Fires after a player's profile loads, receives `AddUserId`, and is reconciled. The `profile` argument is the live ProfileStore profile.
]=]

--[=[
	@prop ProfileReleased Signal<Player>
	@within Server

	Fires when EZProfileStore releases a player's profile session.
]=]

--[=[
	@prop FirstJoin Signal<Player, { [any]: any }>
	@within Server

	Fires when `profile.SessionLoadCount == 1`. The data table is the freshly reconciled profile data and may be mutated synchronously to seed defaults.
]=]

--[=[
	@prop DataUpdated Signal<Player, KeyPath, any>
	@within Server

	Fires after a replicated mutation succeeds. The path is the same path value passed to the mutation method.
]=]

--[=[
	@prop PreSave Signal<Player, { [any]: any }>
	@within Server

	Forwards `Profile.OnSave` with the live data table. Handlers should not yield before making final synchronous changes.
]=]

--[=[
	@prop PostSave Signal<Player, { [any]: any }>
	@within Server

	Forwards `Profile.OnAfterSave` with the saved data snapshot.
]=]

--[=[
	@prop LastSave Signal<Player, "Manual" | "External" | "Shutdown">
	@within Server

	Forwards `Profile.OnLastSave` with ProfileStore's final-save reason.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Promise = require(script.Parent.Parent.Promise)
local Shared = require(script.Parent.Shared)
local Signal = require(script.Parent.Parent.Signal)

local DEFAULT_KEY_PREFIX = "Player_"
local SNAPSHOT_WAIT_TIMEOUT = 30

export type LeaderstatEntry = {
	path: Shared.KeyPath,
	name: string,
	type: "IntValue" | "NumberValue" | "StringValue",
}

type ResolvedLeaderstatEntry = {
	path: { string },
	pathStr: string,
	name: string,
	type: "IntValue" | "NumberValue" | "StringValue",
}

export type Config = {
	storeName: string,
	template: { [any]: any },
	keyPrefix: string?,
	useMockInStudio: boolean?,
	remoteParent: Instance?,
	leaderstats: { LeaderstatEntry }?,
}

export type Profile = any
type ValueBase = IntValue | NumberValue | StringValue
export type Server = typeof(setmetatable(
	{} :: {
		_store: any,
		_keyPrefix: string,
		_profiles: { [Player]: Profile },
		_connections: { RBXScriptConnection },
		_profileConnections: { [Player]: { RBXScriptConnection } },
		_dataUpdate: RemoteEvent,
		_requestData: RemoteFunction,
		_isDestroyed: boolean,
		_pendingBatches: { [Player]: Shared.Batch },
		_flushScheduled: boolean,
		_leaderstatsConfig: { ResolvedLeaderstatEntry },
		_leaderstats: { [Player]: { [string]: ValueBase } },
		ProfileLoaded: Signal.Signal<Player, Profile>,
		ProfileReleased: Signal.Signal<Player>,
		FirstJoin: Signal.Signal<Player, { [any]: any }>,
		DataUpdated: Signal.Signal<Player, Shared.KeyPath, any>,
		PreSave: Signal.Signal<Player, { [any]: any }>,
		PostSave: Signal.Signal<Player, { [any]: any }>,
		LastSave: Signal.Signal<Player, "Manual" | "External" | "Shutdown">,
	},
	{} :: { __index: any }
))

local Server = {}
Server.__index = Server

local resolvedProfileStore: any? = nil

local function requireProfileStoreModule(module: Instance?, location: string): any?
	if module == nil then
		return nil
	end
	if not module:IsA("ModuleScript") then
		error(`EZProfileStore.Server: {location} is a {module.ClassName}, expected ModuleScript`, 3)
	end
	return require(module)
end

local function findProfileStoreInService(serviceName: string): any?
	local ok, service = pcall(function()
		return game:GetService(serviceName)
	end)
	if not ok then
		return nil
	end

	local serverPackages = service:FindFirstChild("ServerPackages")
	if not serverPackages then
		return nil
	end

	return requireProfileStoreModule(
		serverPackages:FindFirstChild("ProfileStore"),
		`{serviceName}.ServerPackages.ProfileStore`
	)
end

local function getProfileStore(): any
	if resolvedProfileStore ~= nil then
		return resolvedProfileStore
	end

	local packageParent = script.Parent.Parent
	resolvedProfileStore = requireProfileStoreModule(
		packageParent:FindFirstChild("ProfileStore"),
		`{packageParent:GetFullName()}.ProfileStore`
	)
	if resolvedProfileStore ~= nil then
		return resolvedProfileStore
	end

	resolvedProfileStore = findProfileStoreInService("ServerScriptService")
		or findProfileStoreInService("ServerStorage")
		or findProfileStoreInService("ReplicatedStorage")

	if resolvedProfileStore == nil then
		error(
			"EZProfileStore.Server: could not find ProfileStore. Install EZProfileStore with Wally and mount ServerPackages, or place ProfileStore next to the package in _Index.",
			3
		)
	end

	return resolvedProfileStore
end

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

local LEADERSTAT_TYPE_TO_LUA: { [string]: string } = {
	IntValue = "number",
	NumberValue = "number",
	StringValue = "string",
}

local function validateLeaderstats(template: { [any]: any }, entries: { LeaderstatEntry }): { ResolvedLeaderstatEntry }
	local resolved: { ResolvedLeaderstatEntry } = {}
	for i, entry in entries do
		assert(typeof(entry) == "table", `leaderstats[{i}] must be a table`)
		assert(typeof(entry.name) == "string" and #entry.name > 0, `leaderstats[{i}].name must be a non-empty string`)
		local expectedType = LEADERSTAT_TYPE_TO_LUA[entry.type]
		assert(expectedType ~= nil, `leaderstats[{i}].type must be IntValue, NumberValue, or StringValue`)

		local path = Shared.resolveKeyPath(entry.path)
		local pathStr = Shared.toPathString(entry.path)
		local current = Shared.readPath(template, path)
		assert(current ~= nil, `leaderstats[{i}].path "{pathStr}" does not exist in template`)
		assert(
			typeof(current) == expectedType,
			`leaderstats[{i}].path "{pathStr}" is {typeof(current)} but declared {entry.type}`
		)

		table.insert(resolved, {
			path = path,
			pathStr = pathStr,
			name = entry.name,
			type = entry.type,
		})
	end
	return resolved
end

--[=[
	Creates a new server-side store. Binds player join/leave handlers,
	processes players already in the server, and provisions the replication
	remotes under `config.remoteParent` (defaults to `ReplicatedStorage`).
	Use `useMockInStudio = true` to opt into `ProfileStore.Mock` while testing
	in Studio.

	@within Server
	@param config Config
	@return Server
]=]
function Server.new(config: Config): Server
	assert(typeof(config) == "table", "Server.new expects a config table")
	assert(typeof(config.storeName) == "string", "config.storeName must be a string")
	assert(typeof(config.template) == "table", "config.template must be a table")
	assert(RunService:IsServer(), "EZProfileStore.Server can only be required on the server")

	local resolvedLeaderstats: { ResolvedLeaderstatEntry } = if config.leaderstats and #config.leaderstats > 0
		then validateLeaderstats(config.template, config.leaderstats)
		else {}

	local ProfileStore = getProfileStore()
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
		_profileConnections = {},
		_dataUpdate = dataUpdate,
		_requestData = requestData,
		_isDestroyed = false,
		_pendingBatches = {},
		_flushScheduled = false,
		_leaderstatsConfig = resolvedLeaderstats,
		_leaderstats = {},
		ProfileLoaded = Signal.new(),
		ProfileReleased = Signal.new(),
		FirstJoin = Signal.new(),
		DataUpdated = Signal.new(),
		PreSave = Signal.new(),
		PostSave = Signal.new(),
		LastSave = Signal.new(),
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
		return self:_consumeSnapshot(player, profile)
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
	return if profile then self:_consumeSnapshot(player, profile) else nil
end

function Server._consumeSnapshot(self: Server, player: Player, profile: Profile): { [any]: any }
	self._pendingBatches[player] = nil
	return profile.Data
end

function Server._disconnectProfileConnections(self: Server, player: Player)
	local profileConns = self._profileConnections[player]
	if not profileConns then
		return
	end

	for _, conn in profileConns do
		conn:Disconnect()
	end
	self._profileConnections[player] = nil
end

function Server._releaseProfile(self: Server, player: Player, profile: Profile, shouldKick: boolean)
	if self._profiles[player] ~= profile then
		return
	end

	self._profiles[player] = nil
	self._pendingBatches[player] = nil
	self._leaderstats[player] = nil
	self:_disconnectProfileConnections(player)
	self.ProfileReleased:Fire(player)

	if shouldKick and player.Parent == Players then
		player:Kick("Profile session ended - please rejoin")
	end
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

	self._profileConnections[player] = {
		profile.OnSave:Connect(function()
			self.PreSave:Fire(player, profile.Data)
		end),
		profile.OnAfterSave:Connect(function(saved)
			self.PostSave:Fire(player, saved)
		end),
		profile.OnLastSave:Connect(function(reason)
			self.LastSave:Fire(player, reason)
		end),
		profile.OnSessionEnd:Connect(function()
			self:_releaseProfile(player, profile, not self._isDestroyed)
		end),
	}

	if profile.SessionLoadCount == 1 then
		self.FirstJoin:Fire(player, profile.Data)
	end

	self.ProfileLoaded:Fire(player, profile)
	self:_buildLeaderstats(player)
end

function Server._onPlayerRemoving(self: Server, player: Player)
	self._leaderstats[player] = nil
	self._pendingBatches[player] = nil

	local profile = self._profiles[player]
	if profile then
		profile:EndSession()
		self:_releaseProfile(player, profile, false)
	else
		self:_disconnectProfileConnections(player)
	end
end

function Server._buildLeaderstats(self: Server, player: Player)
	if #self._leaderstatsConfig == 0 then
		return
	end

	local data = self:GetData(player)
	if not data then
		return
	end

	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"

	local mirror: { [string]: ValueBase } = {}
	for _, entry in self._leaderstatsConfig do
		local instance = Instance.new(entry.type)
		instance.Name = entry.name
		instance.Value = Shared.readPath(data, entry.path)
		instance.Parent = folder
		mirror[entry.pathStr] = instance
	end

	self._leaderstats[player] = mirror
	folder.Parent = player
end

function Server._mirrorLeaderstats(self: Server, player: Player)
	local mirror = self._leaderstats[player]
	if not mirror then
		return
	end

	local data = self:GetData(player)
	if not data then
		return
	end

	for _, entry in self._leaderstatsConfig do
		local instance = mirror[entry.pathStr]
		if instance then
			local current = Shared.readPath(data, entry.path)
			if current ~= nil and instance.Value ~= current then
				instance.Value = current
			end
		end
	end
end

function Server._queueUpdate(
	self: Server,
	player: Player,
	opcode: string,
	pathStr: string,
	valueOrIndex: any,
	value: any?
)
	local batch = self._pendingBatches[player]
	if not batch then
		batch = {}
		self._pendingBatches[player] = batch
	end

	-- Stop at first non-set/del to preserve order against ins/aupd/arm.
	if opcode == Shared.OP.Set or opcode == Shared.OP.Del then
		for i = #batch, 1, -1 do
			local entry = batch[i]
			local entryOp = entry[1]
			if entryOp ~= Shared.OP.Set and entryOp ~= Shared.OP.Del then
				break
			end
			if entry[2] == pathStr then
				entry[1] = opcode
				entry[3] = valueOrIndex
				self:_scheduleFlush()
				return
			end
		end
	end

	if opcode == Shared.OP.Set then
		table.insert(batch, { Shared.OP.Set, pathStr, valueOrIndex })
	elseif opcode == Shared.OP.Del then
		table.insert(batch, { Shared.OP.Del, pathStr })
	elseif opcode == Shared.OP.Ins then
		table.insert(batch, { Shared.OP.Ins, pathStr, valueOrIndex })
	elseif opcode == Shared.OP.AUpd then
		table.insert(batch, { Shared.OP.AUpd, pathStr, valueOrIndex, value })
	elseif opcode == Shared.OP.ARm then
		table.insert(batch, { Shared.OP.ARm, pathStr, valueOrIndex })
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
			if self._leaderstats[player] then
				self:_mirrorLeaderstats(player)
			end
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

	Direct mutations persist on the next ProfileStore save, but they do **not** replicate to the client and they do not fire [Server.DataUpdated]. Use the mutation methods for gameplay writes that clients need to observe.

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
	Reads the value at `keyPath`. Returns `nil` if the path does not resolve or the profile has not loaded. `keyPath` may be a dot string like `"Stats.Wins"` or an array like `{ "Stats", "Wins" }`.

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
	@param value any -- Passing `nil` deletes the path.
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

	local opcode = if value == nil then Shared.OP.Del else Shared.OP.Set
	self:_queueUpdate(player, opcode, Shared.toPathString(keyPath), value)
	self.DataUpdated:Fire(player, keyPath, value)
	return true
end

--[=[
	Appends `value` to the array at `keyPath`. The target must be a table; if it is missing or not a table, this warns and returns `false` without mutating or replicating.

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

	self:_queueUpdate(player, Shared.OP.Ins, Shared.toPathString(keyPath), value)
	self.DataUpdated:Fire(player, keyPath, value)
	return true
end

--[=[
	Adds `delta` (default `1`) to the numeric value at `keyPath`. A `nil`
	current value is treated as `0`. Returns `false` if the profile is not
	loaded, or the existing value is non-nil and non-numeric (in which case
	the call warns and is a no-op).

	@within Server
	@method IncrementData
	@param player Player
	@param keyPath KeyPath
	@param delta number? -- Defaults to `1`.
	@return boolean
]=]
function Server.IncrementData(self: Server, player: Player, keyPath: Shared.KeyPath, delta: number?): boolean
	local data = self:GetData(player)
	if not data then
		return false
	end

	local path = Shared.resolveKeyPath(keyPath)
	local current = Shared.readPath(data, path)
	if current ~= nil and typeof(current) ~= "number" then
		warn(`EZProfileStore: IncrementData target at "{table.concat(path, ".")}" is not a number`)
		return false
	end

	local newValue = (current or 0) + (delta or 1)
	if not Shared.writePath(data, path, newValue, false) then
		return false
	end

	self:_queueUpdate(player, Shared.OP.Set, Shared.toPathString(keyPath), newValue)
	self.DataUpdated:Fire(player, keyPath, newValue)
	return true
end

--[=[
	Subtracts `delta` (default `1`) from the numeric value at `keyPath`.
	Equivalent to `IncrementData(player, keyPath, -(delta or 1))`.

	@within Server
	@method DecrementData
	@param player Player
	@param keyPath KeyPath
	@param delta number? -- Defaults to `1`.
	@return boolean
]=]
function Server.DecrementData(self: Server, player: Player, keyPath: Shared.KeyPath, delta: number?): boolean
	return self:IncrementData(player, keyPath, -(delta or 1))
end

--[=[
	Sets the value at `keyPath` to `nil`. Returns `false` when no profile is loaded or the path is already `nil`. Missing parent tables are not created.

	@within Server
	@method RemoveData
	@param player Player
	@param keyPath KeyPath
	@return boolean
]=]
function Server.RemoveData(self: Server, player: Player, keyPath: Shared.KeyPath): boolean
	local data = self:GetData(player)
	if not data then
		return false
	end

	local path = Shared.resolveKeyPath(keyPath)
	if Shared.readPath(data, path) == nil then
		return false
	end

	if not Shared.writePath(data, path, nil, false) then
		return false
	end

	self:_queueUpdate(player, Shared.OP.Del, Shared.toPathString(keyPath))
	self.DataUpdated:Fire(player, keyPath, nil)
	return true
end

--[=[
	Replaces the array element at `index` (1-based) under `arrayPath`.
	Returns `false` if the profile is not loaded, the target is not an array,
	or `index` is out of bounds (`< 1` or `> #arr`).

	@within Server
	@method UpdateArrayItem
	@param player Player
	@param arrayPath KeyPath -- Path to the array.
	@param index number
	@param value any
	@return boolean
]=]
function Server.UpdateArrayItem(
	self: Server,
	player: Player,
	arrayPath: Shared.KeyPath,
	index: number,
	value: any
): boolean
	local data = self:GetData(player)
	if not data then
		return false
	end

	local path = Shared.resolveKeyPath(arrayPath)
	if not Shared.arrayUpdate(data, path, index, value) then
		return false
	end

	self:_queueUpdate(player, Shared.OP.AUpd, Shared.toPathString(arrayPath), index, value)
	self.DataUpdated:Fire(player, arrayPath, value)
	return true
end

--[=[
	Removes the array element at `index` (1-based) under `arrayPath` via
	`table.remove`. Returns `false` if the profile is not loaded, the target
	is not an array, or `index` is out of bounds.

	@within Server
	@method RemoveArrayItem
	@param player Player
	@param arrayPath KeyPath
	@param index number
	@return boolean
]=]
function Server.RemoveArrayItem(self: Server, player: Player, arrayPath: Shared.KeyPath, index: number): boolean
	local data = self:GetData(player)
	if not data then
		return false
	end

	local path = Shared.resolveKeyPath(arrayPath)
	if not Shared.arrayRemove(data, path, index) then
		return false
	end

	self:_queueUpdate(player, Shared.OP.ARm, Shared.toPathString(arrayPath), index)
	self.DataUpdated:Fire(player, arrayPath, nil)
	return true
end

--[=[
	Applies multiple set/del writes to the player's profile in one frame.
	Each entry's `value` follows the same semantics as `UpdateData`: `nil` deletes, anything else sets. Returns the number of paths that actually changed.

	All wire entries from a single call will batch into the same network
	event since they're queued before the next deferred flush.

	@within Server
	@method BatchSetValues
	@param player Player
	@param writes { { path: KeyPath, value: any } }
	@return number
]=]
function Server.BatchSetValues(self: Server, player: Player, writes: { { path: Shared.KeyPath, value: any } }): number
	local data = self:GetData(player)
	if not data then
		return 0
	end

	local changed = 0
	for _, write in writes do
		local path = Shared.resolveKeyPath(write.path)
		if Shared.writePath(data, path, write.value, false) then
			local opcode = if write.value == nil then Shared.OP.Del else Shared.OP.Set
			self:_queueUpdate(player, opcode, Shared.toPathString(write.path), write.value)
			self.DataUpdated:Fire(player, write.path, write.value)
			changed += 1
		end
	end
	return changed
end

--[=[
	Forces an immediate save via `profile:Save()`. Returns `false` when no
	profile is loaded for `player`. ProfileStore already auto-saves and saves when sessions end, so reserve this for critical checkpoints such as product receipts.

	@within Server
	@method SaveAsync
	@yields
	@param player Player
	@return boolean
]=]
function Server.SaveAsync(self: Server, player: Player): boolean
	local profile = self._profiles[player]
	if not profile then
		return false
	end
	profile:Save()
	return true
end

--[=[
	Returns `true` when a profile is loaded for `player`.

	@within Server
	@method IsReady
	@param player Player
	@return boolean
]=]
function Server.IsReady(self: Server, player: Player): boolean
	return self._profiles[player] ~= nil
end

--[=[
	Removes the player's stored data via `ProfileStore:RemoveAsync`. Accepts either a `Player` (whose active session, if any, is ended first) or a raw `UserId` (offline wipe). Use carefully: this erases the ProfileStore key for the configured store and key prefix.

	@within Server
	@method WipeAsync
	@yields
	@param target Player | number
	@return boolean
]=]
function Server.WipeAsync(self: Server, target: Player | number): boolean
	local userId: number
	if typeof(target) == "Instance" then
		userId = target.UserId
		local profile = self._profiles[target]
		if profile then
			profile:EndSession()
		end
	else
		userId = target
	end

	local key = self._keyPrefix .. tostring(userId)
	return self._store:RemoveAsync(key)
end

--[=[
	Ends all active profile sessions, disconnects player listeners, and releases signals. Save-related ProfileStore signals remain connected while sessions are being ended. The replication remotes are not removed.

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

	for player, profile in table.clone(self._profiles) do
		profile:EndSession()
		self:_releaseProfile(player, profile, false)
	end
	table.clear(self._profileConnections)
	table.clear(self._pendingBatches)

	self._requestData.OnServerInvoke = function()
		return nil
	end

	self.ProfileLoaded:Destroy()
	self.ProfileReleased:Destroy()
	self.FirstJoin:Destroy()
	self.DataUpdated:Destroy()
	self.PreSave:Destroy()
	self.PostSave:Destroy()
	self.LastSave:Destroy()
end

return Server
