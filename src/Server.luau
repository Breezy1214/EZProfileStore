--!strict
--[=[
	@class Server
	@server

	Owns player sessions and replicates server mutations.
]=]

--[=[
	@interface Config
	@within Server
	.storeName string -- ProfileStore name.
	.template { [any]: any } -- Current data template.
	.keyPrefix string? -- Defaults to `"Player_"`.
	.mode "live" | "studio" | "mock"? -- Defaults to `"live"`.
	.useMockInStudio boolean? -- Alias for `mode = "studio"`.
	.store any? -- Injected store for tests.
	.profileStore any? -- Injected ProfileStore module.
	.migrations Migrations | { MigrationInput }? -- Ordered migrations.
	.migrateNewProfiles boolean? -- Defaults to `false`.
	.migrationMetadataKey string? -- Defaults to `"EZProfileStoreVersion"`.
	.remoteParent Instance? -- Defaults to `ReplicatedStorage`.
	.leaderstats { LeaderstatEntry }? -- Mirrored profile paths.
]=]

--[=[
	@interface LeaderstatEntry
	@within Server
	.path KeyPath
	.name string
	.type "IntValue" | "NumberValue" | "StringValue"
]=]

--[=[
	@prop ProfileLoaded Signal<Player, Profile>
	@within Server
	Fires when a profile is ready.
]=]

--[=[
	@prop ProfileReleased Signal<Player>
	@within Server
	Fires when a session ends.
]=]

--[=[
	@prop FirstJoin Signal<Player, { [any]: any }>
	@within Server
	Fires on the first profile session.
]=]

--[=[
	@prop DataUpdated Signal<Player, KeyPath, any>
	@within Server
	Fires after a replicated mutation.
]=]

--[=[
	@prop PreSave Signal<Player, { [any]: any }>
	@within Server
	Forwards `Profile.OnSave`.
]=]

--[=[
	@prop PostSave Signal<Player, { [any]: any }>
	@within Server
	Forwards `Profile.OnAfterSave`.
]=]

--[=[
	@prop LastSave Signal<Player, "Manual" | "External" | "Shutdown">
	@within Server
	Forwards `Profile.OnLastSave`.
]=]

--[=[
	@prop Migrated Signal<Player, MigrationReport>
	@within Server
	Fires after migrations run.
]=]

--[=[
	@prop ProfileLoadFailed Signal<Player, string>
	@within Server
	Fires when loading or migration fails.
]=]

--[=[
	@prop RolledBack Signal<RollbackResult>
	@within Server
	Fires after a rollback.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Migrations = require(script.Parent.Migrations)
local Promise = require(script.Parent.Parent.Promise)
local Shared = require(script.Parent.Shared)
local Signal = require(script.Parent.Parent.Signal)

local DEFAULT_KEY_PREFIX = "Player_"
local DEFAULT_MIGRATION_METADATA_KEY = "EZProfileStoreVersion"
local SNAPSHOT_WAIT_TIMEOUT = 30

export type StoreMode = "live" | "studio" | "mock"
export type Target = Player | number | string
export type VersionSelector = {
	version: string?,
	before: DateTime | number?,
	stepsBack: number?,
}
export type RollbackResult = {
	key: string,
	version: string,
	updatedTime: number,
	data: { [any]: any },
}
type RollbackSelection = {
	key: string,
	profile: any,
}

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
	mode: StoreMode?,
	useMockInStudio: boolean?,
	store: any?,
	profileStore: any?,
	migrations: Migrations.Migrations | { Migrations.Input }?,
	migrateNewProfiles: boolean?,
	migrationMetadataKey: string?,
	remoteParent: Instance?,
	leaderstats: { LeaderstatEntry }?,
}

export type Profile = any
type ValueBase = IntValue | NumberValue | StringValue
export type Server = typeof(setmetatable(
	{} :: {
		_store: any,
		_keyPrefix: string,
		_migrations: Migrations.Migrations?,
		_migrateNewProfiles: boolean,
		_migrationMetadataKey: string,
		_profiles: { [Player]: Profile },
		_connections: { RBXScriptConnection },
		_profileConnections: { [Player]: { RBXScriptConnection } },
		_destroyedSignal: Signal.Signal<>,
		_dataUpdate: RemoteEvent,
		_requestData: RemoteFunction,
		_isDestroyed: boolean,
		_pendingBatches: { [Player]: Shared.Batch },
		_flushScheduled: boolean,
		_leaderstatsConfig: { ResolvedLeaderstatEntry },
		_leaderstats: { [Player]: { [string]: ValueBase } },
		_rollbackPreviews: { [RollbackResult]: RollbackSelection },
		IsMock: boolean,
		ProfileLoaded: Signal.Signal<Player, Profile>,
		ProfileReleased: Signal.Signal<Player>,
		FirstJoin: Signal.Signal<Player, { [any]: any }>,
		DataUpdated: Signal.Signal<Player, Shared.KeyPath, any>,
		PreSave: Signal.Signal<Player, { [any]: any }>,
		PostSave: Signal.Signal<Player, { [any]: any }>,
		LastSave: Signal.Signal<Player, "Manual" | "External" | "Shutdown">,
		Migrated: Signal.Signal<Player, Migrations.Report>,
		ProfileLoadFailed: Signal.Signal<Player, string>,
		RolledBack: Signal.Signal<RollbackResult>,
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

local function resolveMigrations(configured: Migrations.Migrations | { Migrations.Input }?): Migrations.Migrations?
	if configured == nil then
		return nil
	end

	if
		typeof((configured :: any).Migrate) == "function"
		and typeof((configured :: any).GetLatestVersion) == "function"
	then
		return configured :: Migrations.Migrations
	end

	return Migrations.new(configured :: { Migrations.Input })
end

local function resolveMode(config: Config): StoreMode
	local mode: StoreMode = config.mode or (if config.useMockInStudio then "studio" else "live")
	assert(mode == "live" or mode == "studio" or mode == "mock", 'config.mode must be "live", "studio", or "mock"')
	return mode
end

local function isProfileActive(profile: Profile?): boolean
	return profile ~= nil and (typeof(profile.IsActive) ~= "function" or profile:IsActive())
end

--[=[
	Creates a store and binds player lifecycle handlers.
	@within Server
	@param config Config
	@return Server
]=]
function Server.new(config: Config): Server
	assert(typeof(config) == "table", "Server.new expects a config table")
	assert(typeof(config.storeName) == "string", "config.storeName must be a string")
	assert(typeof(config.template) == "table", "config.template must be a table")
	assert(RunService:IsServer(), "EZProfileStore.Server can only be required on the server")
	assert(
		config.migrationMetadataKey == nil or typeof(config.migrationMetadataKey) == "string",
		"config.migrationMetadataKey must be a string"
	)
	assert(
		config.migrationMetadataKey == nil or #config.migrationMetadataKey > 0,
		"config.migrationMetadataKey must not be empty"
	)

	local resolvedLeaderstats: { ResolvedLeaderstatEntry } = if config.leaderstats and #config.leaderstats > 0
		then validateLeaderstats(config.template, config.leaderstats)
		else {}
	local migrationRunner = resolveMigrations(config.migrations)
	local mode = resolveMode(config)
	local wantsMock = mode == "mock" or (mode == "studio" and RunService:IsStudio())
	assert(
		not (config.store ~= nil and config.profileStore ~= nil),
		"config.store and config.profileStore are mutually exclusive"
	)
	assert(
		not (config.store ~= nil and mode ~= "live"),
		"an injected config.store cannot be combined with studio/mock mode"
	)

	local store = config.store
	local isMock = config.store == nil and wantsMock
	if store == nil then
		local ProfileStore = config.profileStore or getProfileStore()
		assert(typeof(ProfileStore.New) == "function", "config.profileStore must expose ProfileStore.New")
		store = ProfileStore.New(config.storeName, config.template)
		if isMock then
			assert(store.Mock ~= nil, "ProfileStore-compatible store has no Mock store")
			store = store.Mock
		end
	end

	local remoteParent = config.remoteParent or ReplicatedStorage
	local remoteFolder = ensureRemoteFolder(remoteParent)
	local dataUpdate = ensureChild(remoteFolder, Shared.REMOTE_DATA_UPDATE, "RemoteEvent") :: RemoteEvent
	local requestData = ensureChild(remoteFolder, Shared.REMOTE_REQUEST_DATA, "RemoteFunction") :: RemoteFunction

	local self = setmetatable({
		_store = store,
		_keyPrefix = config.keyPrefix or DEFAULT_KEY_PREFIX,
		_migrations = migrationRunner,
		_migrateNewProfiles = config.migrateNewProfiles == true,
		_migrationMetadataKey = config.migrationMetadataKey or DEFAULT_MIGRATION_METADATA_KEY,
		_profiles = {},
		_connections = {},
		_profileConnections = {},
		_destroyedSignal = Signal.new(),
		_dataUpdate = dataUpdate,
		_requestData = requestData,
		_isDestroyed = false,
		_pendingBatches = {},
		_flushScheduled = false,
		_leaderstatsConfig = resolvedLeaderstats,
		_leaderstats = {},
		_rollbackPreviews = setmetatable({}, { __mode = "k" }),
		IsMock = isMock,
		ProfileLoaded = Signal.new(),
		ProfileReleased = Signal.new(),
		FirstJoin = Signal.new(),
		DataUpdated = Signal.new(),
		PreSave = Signal.new(),
		PostSave = Signal.new(),
		LastSave = Signal.new(),
		Migrated = Signal.new(),
		ProfileLoadFailed = Signal.new(),
		RolledBack = Signal.new(),
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

--[=[
	Creates a store backed by `ProfileStore.Mock`.
	@within Server
	@param config Config
	@return Server
]=]
function Server.mock(config: Config): Server
	assert(typeof(config) == "table", "Server.mock expects a config table")
	local resolved = table.clone(config)
	resolved.mode = "mock"
	resolved.useMockInStudio = nil
	return Server.new(resolved)
end

function Server._waitForProfile(self: Server, player: Player, timeout: number): Profile?
	local profile = self._profiles[player]
	if isProfileActive(profile) then
		return profile
	end
	if self._isDestroyed or player.Parent ~= Players then
		return nil
	end

	local loaded = Promise.fromEvent(self.ProfileLoaded, function(loadedPlayer)
		return loadedPlayer == player
	end):andThenReturn("loaded")
	local failed = Promise.fromEvent(self.ProfileLoadFailed, function(failedPlayer)
		return failedPlayer == player
	end):andThenReturn("failed")
	local leaving = Promise.fromEvent(Players.PlayerRemoving, function(leavingPlayer)
		return leavingPlayer == player
	end):andThenReturn("left")
	local destroying = Promise.fromEvent(self._destroyedSignal):andThenReturn("destroyed")

	local ok, outcome = Promise.race({ loaded, failed, leaving, destroying }):timeout(timeout):await()
	if not ok or outcome ~= "loaded" then
		return nil
	end

	profile = self._profiles[player]
	return if isProfileActive(profile) then profile else nil
end

function Server._waitForData(self: Server, player: Player): { [any]: any }?
	local profile = self:_waitForProfile(player, SNAPSHOT_WAIT_TIMEOUT)
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

function Server._migrateProfile(self: Server, player: Player, profile: Profile, key: string): (boolean, string?)
	local runner = self._migrations
	if runner == nil then
		return true, nil
	end

	if profile.RobloxMetaData == nil then
		profile.RobloxMetaData = {}
	end
	if typeof(profile.RobloxMetaData) ~= "table" then
		return false, "Profile.RobloxMetaData is not a table"
	end

	local metadata = profile.RobloxMetaData
	local storedVersion = metadata[self._migrationMetadataKey]
	local latestVersion = runner:GetLatestVersion()
	if storedVersion == nil then
		storedVersion = if profile.SessionLoadCount == 1 and not self._migrateNewProfiles then latestVersion else 0
	end

	if typeof(storedVersion) ~= "number" or storedVersion < 0 or storedVersion % 1 ~= 0 then
		return false,
			`invalid schema version {tostring(storedVersion)} in Roblox metadata "{self._migrationMetadataKey}"`
	end

	local ok, report = pcall(function()
		return runner:Migrate(profile.Data, storedVersion, {
			key = key,
			userId = if player:IsA("Player") then player.UserId else nil,
		})
	end)
	if not ok then
		return false, tostring(report)
	end

	metadata[self._migrationMetadataKey] = latestVersion
	if #report.applied > 0 then
		self.Migrated:Fire(player, report)
	end
	return true, nil
end

function Server._prepareProfile(self: Server, player: Player, profile: Profile, key: string): (boolean, string?)
	local migrationOk, migrationError = self:_migrateProfile(player, profile, key)
	if not migrationOk then
		return false, migrationError
	end

	profile:Reconcile()
	return true, nil
end

function Server._onPlayerAdded(self: Server, player: Player)
	if self._isDestroyed then
		return
	end

	local key = self:GetKey(player)
	local profile = self._store:StartSessionAsync(key, {
		Cancel = function()
			return player.Parent ~= Players
		end,
	})

	if not profile then
		local reason = "ProfileStore could not start a profile session"
		self.ProfileLoadFailed:Fire(player, reason)
		player:Kick("Failed to load data, please rejoin")
		return
	end

	profile:AddUserId(player.UserId)
	local migrationOk, migrationError = self:_prepareProfile(player, profile, key)
	if not migrationOk then
		local reason = `Schema migration failed for "{key}": {migrationError}`
		warn(`EZProfileStore: {reason}`)
		self.ProfileLoadFailed:Fire(player, reason)
		profile:EndSession()
		if player.Parent == Players then
			player:Kick("Failed to update your saved data safely. Please rejoin.")
		end
		return
	end

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
	Returns the active profile.
	@within Server
	@method GetProfile
	@param player Player
	@return Profile?
]=]
function Server.GetProfile(self: Server, player: Player): Profile?
	local profile = self._profiles[player]
	return if isProfileActive(profile) then profile else nil
end

--[=[
	Yields for an active profile.
	@within Server
	@method GetProfileAsync
	@yields
	@param player Player
	@param timeout number? -- Defaults to `10` seconds.
	@return Profile?
]=]
function Server.GetProfileAsync(self: Server, player: Player, timeout: number?): Profile?
	return self:_waitForProfile(player, timeout or 10)
end

--[=[
	Returns the active profile's data by reference.
	@within Server
	@method GetData
	@param player Player
	@return { [any]: any }?
]=]
function Server.GetData(self: Server, player: Player): { [any]: any }?
	local profile = self:GetProfile(player)
	return profile and profile.Data
end

--[=[
	Yields for active profile data.
	@within Server
	@method GetDataAsync
	@yields
	@param player Player
	@param timeout number?
	@return { [any]: any }?
]=]
function Server.GetDataAsync(self: Server, player: Player, timeout: number?): { [any]: any }?
	if self:GetProfileAsync(player, timeout) == nil then
		return nil
	end
	return self:GetData(player)
end

--[=[
	Resolves a Player, UserId, or exact string key.
	@within Server
	@method GetKey
	@param target Target
	@return string
]=]
function Server.GetKey(self: Server, target: Target): string
	if typeof(target) == "Instance" then
		assert(target:IsA("Player"), "target Instance must be a Player")
		return self._keyPrefix .. tostring((target :: Player).UserId)
	elseif typeof(target) == "number" then
		assert(target % 1 == 0, "numeric target must be an integer UserId")
		return self._keyPrefix .. tostring(target)
	elseif typeof(target) == "string" then
		assert(#target > 0, "target key must not be empty")
		return target
	end

	error("target must be a Player, UserId number, or exact key string", 2)
end

--[=[
	Returns the underlying ProfileStore object.
	@within Server
	@method GetStore
	@return any
]=]
function Server.GetStore(self: Server): any
	return self._store
end

--[=[
	Reads a profile path.
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
	Sets or deletes a profile path.
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
	Appends to an array path.
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
		warn(`EZProfileStore: InsertData target at "{Shared.toPathString(keyPath)}" is not a table`)
		return false
	end

	self:_queueUpdate(player, Shared.OP.Ins, Shared.toPathString(keyPath), value)
	self.DataUpdated:Fire(player, keyPath, value)
	return true
end

--[=[
	Adds `delta` to a numeric path.
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
		warn(`EZProfileStore: IncrementData target at "{Shared.toPathString(keyPath)}" is not a number`)
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
	Subtracts `delta` from a numeric path.
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
	Deletes a profile path.
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
	Replaces an array item by index.
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
	Removes an array item by index.
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
	Applies and batches multiple set/delete operations.
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
	Forces an active profile save.
	@within Server
	@method SaveAsync
	@yields
	@param player Player
	@return boolean
]=]
function Server.SaveAsync(self: Server, player: Player): boolean
	local profile = self:GetProfile(player)
	if not profile then
		return false
	end
	profile:Save()
	return true
end

--[=[
	Returns whether the profile is active.
	@within Server
	@method IsReady
	@param player Player
	@return boolean
]=]
function Server.IsReady(self: Server, player: Player): boolean
	return self:GetProfile(player) ~= nil
end

local function rollbackResult(key: string, profile: any): RollbackResult
	local keyInfo = profile.KeyInfo
	assert(keyInfo ~= nil, "historical profile is missing KeyInfo")
	assert(typeof(keyInfo.Version) == "string", "historical profile KeyInfo is missing Version")
	assert(typeof(keyInfo.UpdatedTime) == "number", "historical profile KeyInfo is missing UpdatedTime")
	assert(typeof(profile.Data) == "table", "historical profile Data must be a table")
	return {
		key = key,
		version = keyInfo.Version,
		updatedTime = keyInfo.UpdatedTime,
		data = Shared.deepCopy(profile.Data),
	}
end

function Server._selectRollback(self: Server, target: Target, selector: VersionSelector?): RollbackSelection?
	local key = self:GetKey(target)
	local resolved: VersionSelector = selector or ({} :: VersionSelector)
	assert(
		resolved.version == nil or (resolved.before == nil and resolved.stepsBack == nil),
		"selector.version cannot be combined with before or stepsBack"
	)

	local profile: any = nil
	if resolved.version ~= nil then
		assert(typeof(resolved.version) == "string" and #resolved.version > 0, "selector.version must be non-empty")
		profile = self._store:GetAsync(key, resolved.version)
	else
		local stepsBack = resolved.stepsBack
		if stepsBack == nil then
			stepsBack = if resolved.before == nil then 1 else 0
		end
		assert(
			typeof(stepsBack) == "number" and stepsBack >= 0 and stepsBack % 1 == 0,
			"selector.stepsBack must be a non-negative integer"
		)

		local query = self._store:VersionQuery(key, Enum.SortDirection.Descending, nil, resolved.before)
		for _ = 0, stepsBack do
			profile = query:NextAsync()
			if profile == nil then
				return nil
			end
		end
	end

	if profile then
		return {
			key = key,
			profile = profile,
		}
	end
	return nil
end

function Server._endActiveSessionForKeyAsync(self: Server, key: string): boolean
	local activePlayer: Player? = nil
	local activeProfile: Profile? = nil
	for player, profile in self._profiles do
		if profile.Key == key or self:GetKey(player) == key then
			activePlayer = player
			activeProfile = profile
			break
		end
	end
	if activePlayer == nil or activeProfile == nil then
		return true
	end

	local released = Promise.fromEvent(self.ProfileReleased, function(player)
		return player == activePlayer
	end)
	local saved = if activeProfile.OnAfterSave then Promise.fromEvent(activeProfile.OnAfterSave) else Promise.resolve()
	activeProfile:EndSession()
	local ok = Promise.all({ released, saved }):timeout(10):await()
	if not ok and self._profiles[activePlayer] == activeProfile then
		self:_releaseProfile(activePlayer, activeProfile, true)
	end
	return ok
end

function Server._applyRollbackAsync(self: Server, selection: RollbackSelection): RollbackResult
	assert(self:_endActiveSessionForKeyAsync(selection.key), "active profile did not finish saving before rollback")
	selection.profile:SetAsync()

	local stored = self._store:GetAsync(selection.key)
	local verified = stored ~= nil
		and Shared.deepEqual(stored.Data, selection.profile.Data)
		and Shared.deepEqual(stored.RobloxMetaData, selection.profile.RobloxMetaData)
		and Shared.deepEqual(stored.UserIds, selection.profile.UserIds)
	assert(verified, `rollback for "{selection.key}" could not be verified`)

	local result = rollbackResult(selection.key, selection.profile)
	self.RolledBack:Fire(result)
	return result
end

--[=[
	Loads a historical version without writing it.
	@within Server
	@method PreviewRollbackAsync
	@yields
	@param target Target
	@param selector VersionSelector?
	@return RollbackResult?
]=]
function Server.PreviewRollbackAsync(self: Server, target: Target, selector: VersionSelector?): RollbackResult?
	local selection = self:_selectRollback(target, selector)
	if selection == nil then
		return nil
	end

	local result = rollbackResult(selection.key, selection.profile)
	self._rollbackPreviews[result] = selection
	return result
end

--[=[
	Applies a preview once without reloading it.
	@within Server
	@method ApplyRollbackAsync
	@yields
	@param preview RollbackResult
	@return RollbackResult
]=]
function Server.ApplyRollbackAsync(self: Server, preview: RollbackResult): RollbackResult
	local selection = self._rollbackPreviews[preview]
	assert(selection ~= nil, "preview is expired, already applied, or belongs to another Server")
	local result = self:_applyRollbackAsync(selection)
	self._rollbackPreviews[preview] = nil
	return result
end

--[=[
	Selects and restores a historical version.
	@within Server
	@method RollbackAsync
	@yields
	@param target Target
	@param selector VersionSelector?
	@return RollbackResult?
]=]
function Server.RollbackAsync(self: Server, target: Target, selector: VersionSelector?): RollbackResult?
	local selection = self:_selectRollback(target, selector)
	if selection == nil then
		return nil
	end
	return self:_applyRollbackAsync(selection)
end

--[=[
	Permanently removes a profile key.
	@within Server
	@method WipeAsync
	@yields
	@param target Target
	@return boolean
]=]
function Server.WipeAsync(self: Server, target: Target): boolean
	local key = self:GetKey(target)
	assert(self:_endActiveSessionForKeyAsync(key), "active profile did not finish saving before wipe")
	return self._store:RemoveAsync(key)
end

--[=[
	Releases sessions, connections, and signals.
	@within Server
	@method Destroy
]=]
function Server.Destroy(self: Server)
	if self._isDestroyed then
		return
	end
	self._isDestroyed = true
	self._destroyedSignal:Fire()

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
	table.clear(self._rollbackPreviews)

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
	self._destroyedSignal:Destroy()
	self.Migrated:Destroy()
	self.ProfileLoadFailed:Destroy()
	self.RolledBack:Destroy()
end

return Server
