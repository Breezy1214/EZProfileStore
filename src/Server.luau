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
	.privatePaths { KeyPath }? -- Server-only paths that never replicate.
	.validate ((data: { [any]: any }) -> (boolean, string?))? -- Checked on load and by `Mutate`.
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
	@type MessageHandler (player: Player, message: { [any]: any }, processed: () -> ()) -> ()
	@within Server
	Call `processed` once the message is applied; unprocessed messages are redelivered next session.
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
	privatePaths: { Shared.KeyPath }?,
	validate: ((data: { [any]: any }) -> (boolean, string?))?,
}

export type MessageHandler = (player: Player, message: { [any]: any }, processed: () -> ()) -> ()
type MessageHandlerEntry = {
	handler: MessageHandler,
	active: boolean,
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
		_sequences: { [Player]: number },
		_dirtyLeaderstats: { [Player]: true },
		_profileWaits: { [Player]: any },
		_flushScheduled: boolean,
		_privatePaths: { { string } },
		_validate: ((data: { [any]: any }) -> (boolean, string?))?,
		_messageHandlers: { MessageHandlerEntry },
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

local function resolveWritePath(keyPath: Shared.KeyPath): { string }
	local path = Shared.resolveKeyPath(keyPath)
	for _, key in path do
		if not Shared.isValidKey(key) then
			error(
				`EZProfileStore: invalid key path "{Shared.toPathString(keyPath)}"; segments must be non-empty strings without "."`,
				3
			)
		end
	end
	return path
end

local function resolvePrivatePaths(configured: { Shared.KeyPath }?): { { string } }
	local resolved: { { string } } = {}
	if configured == nil then
		return resolved
	end
	for i, keyPath in configured do
		local path = Shared.resolveKeyPath(keyPath)
		assert(#path > 0, `privatePaths[{i}] must not be empty`)
		table.insert(resolved, path)
	end
	return resolved
end

local function checkSavable(method: string, label: string, value: any): boolean
	local ok, reason = Shared.validateValue(value)
	if not ok then
		warn(`EZProfileStore: {method} rejected "{label}": {reason}`)
	end
	return ok
end

local function runValidator(
	validate: ((data: { [any]: any }) -> (boolean, string?))?,
	data: { [any]: any }
): (boolean, string?)
	if validate == nil then
		return true, nil
	end
	local ok, valid, reason = pcall(validate, data)
	if not ok then
		return false, `validate errored: {valid}`
	elseif valid ~= true then
		return false, reason or "validate rejected the data"
	end
	return true, nil
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
	assert(config.validate == nil or typeof(config.validate) == "function", "config.validate must be a function")
	local privatePaths = resolvePrivatePaths(config.privatePaths)
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
		_sequences = {},
		_dirtyLeaderstats = {},
		_profileWaits = {},
		_flushScheduled = false,
		_privatePaths = privatePaths,
		_validate = config.validate,
		_messageHandlers = {},
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

	requestData.OnServerInvoke = function(player: Player): Shared.Snapshot?
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

function Server._waitForProfile(self: Server, player: Player, timeout: number?): Profile?
	local profile = self._profiles[player]
	if isProfileActive(profile) then
		return profile
	end
	if self._isDestroyed or player.Parent ~= Players then
		return nil
	end

	-- Concurrent waiters (including spammed snapshot requests) share one set of listeners.
	local pending = self._profileWaits[player]
	if pending == nil then
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

		local race = Promise.race({ loaded, failed, leaving, destroying })
		self._profileWaits[player] = race
		race:finally(function()
			if self._profileWaits[player] == race then
				self._profileWaits[player] = nil
			end
		end)
		pending = race
	end

	-- Chain before timing out so one caller's timeout cannot cancel the shared wait.
	local waiter = pending:andThen()
	if timeout ~= nil then
		waiter = waiter:timeout(timeout)
	end

	local ok, outcome = waiter:await()
	if not ok or outcome ~= "loaded" then
		return nil
	end

	profile = self._profiles[player]
	return if isProfileActive(profile) then profile else nil
end

function Server._waitForData(self: Server, player: Player): Shared.Snapshot?
	local profile = self:_waitForProfile(player, nil)
	return if profile then self:_consumeSnapshot(player, profile) else nil
end

function Server._consumeSnapshot(self: Server, player: Player, profile: Profile): Shared.Snapshot
	-- Send the open batch now so its sequence number is covered by this snapshot; the
	-- requesting client discards it while any already-initialized mirror still applies it.
	local batch = self._pendingBatches[player]
	if batch then
		self._pendingBatches[player] = nil
		self:_sendBatch(player, batch)
	end

	return {
		seq = self._sequences[player] or 0,
		data = Shared.redact(profile.Data, self._privatePaths),
	}
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
	self._sequences[player] = nil
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
	return runValidator(self._validate, profile.Data)
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
	local prepared, prepareError = self:_prepareProfile(player, profile, key)
	if not prepared then
		local reason = `Profile preparation failed for "{key}": {prepareError}`
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

	for _, entry in self._messageHandlers do
		self:_attachMessageHandler(player, profile, entry)
	end
end

function Server._attachMessageHandler(self: Server, player: Player, profile: Profile, entry: MessageHandlerEntry)
	profile:MessageHandler(function(message, processed)
		if entry.active and self._profiles[player] == profile then
			entry.handler(player, message, processed)
		end
	end)
end

function Server._onPlayerRemoving(self: Server, player: Player)
	self._leaderstats[player] = nil
	self._pendingBatches[player] = nil
	self._sequences[player] = nil

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
	local leaderstatCount = #self._leaderstatsConfig

	for index, entry in self._leaderstatsConfig do
		local instance = Instance.new(entry.type)
		instance.Name = entry.name
		instance.Value = Shared.readPath(data, entry.path)

		local priority = Instance.new("NumberValue")
		priority.Name = "Priority"
		priority.Value = leaderstatCount - index + 1
		priority.Parent = instance

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

function Server._applySet(self: Server, player: Player, data: { [any]: any }, path: { string }, value: any): boolean
	if not Shared.writePath(data, path, value, false) then
		return false
	end
	self:_queueUpdate(player, if value == nil then Shared.OP.Del else Shared.OP.Set, path, value)
	return true
end

-- Sets or deletes one path, then replicates and signals the change.
function Server._commitSet(
	self: Server,
	player: Player,
	data: { [any]: any },
	path: { string },
	keyPath: Shared.KeyPath,
	value: any
): boolean
	if not self:_applySet(player, data, path, value) then
		return false
	end
	self.DataUpdated:Fire(player, keyPath, value)
	return true
end

function Server._isPrivate(self: Server, path: { string }): boolean
	for _, privatePath in self._privatePaths do
		if Shared.isPrefix(privatePath, path) then
			return true
		end
	end
	return false
end

-- Copies at queue time so later in-frame writes cannot leak into this op's payload.
function Server._replicatedCopy(self: Server, path: { string }, value: any, stripPrivate: boolean): any
	local copy = Shared.deepCopy(value)
	if stripPrivate and typeof(copy) == "table" then
		for _, privatePath in self._privatePaths do
			if #privatePath > #path and Shared.isPrefix(path, privatePath) then
				Shared.writePath(copy, table.move(privatePath, #path + 1, #privatePath, 1, {}), nil, false)
			end
		end
	end
	return copy
end

function Server._queueUpdate(
	self: Server,
	player: Player,
	opcode: string,
	path: { string },
	valueOrIndex: any,
	value: any?
)
	if self._leaderstats[player] then
		self._dirtyLeaderstats[player] = true
		self:_scheduleFlush()
	end
	if self:_isPrivate(path) then
		return
	end

	valueOrIndex = self:_replicatedCopy(path, valueOrIndex, opcode == Shared.OP.Set)
	value = self:_replicatedCopy(path, value, false)

	local pathStr = table.concat(path, ".")
	local batch = self._pendingBatches[player]
	if not batch then
		batch = {}
		self._pendingBatches[player] = batch
		self._sequences[player] = (self._sequences[player] or 0) + 1
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

	table.insert(batch, { opcode, pathStr, valueOrIndex, value :: any })
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

	local batches = self._pendingBatches
	self._pendingBatches = {}
	for player, batch in batches do
		self:_sendBatch(player, batch)
	end

	local dirty = self._dirtyLeaderstats
	self._dirtyLeaderstats = {}
	for player in dirty do
		self:_mirrorLeaderstats(player)
	end
end

function Server._sendBatch(self: Server, player: Player, batch: Shared.Batch)
	if #batch > 0 and player.Parent == Players then
		self._dataUpdate:FireClient(player, self._sequences[player], batch)
	end
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
	local path = resolveWritePath(keyPath)
	local data = self:GetData(player)
	if not data then
		return false
	end
	if value ~= nil and not checkSavable("UpdateData", Shared.toPathString(keyPath), value) then
		return false
	end

	return self:_commitSet(player, data, path, keyPath, value)
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
	local path = resolveWritePath(keyPath)
	local data = self:GetData(player)
	if not data then
		return false
	end
	if not checkSavable("InsertData", Shared.toPathString(keyPath), value) then
		return false
	end

	if not Shared.writePath(data, path, value, true) then
		warn(`EZProfileStore: InsertData target at "{Shared.toPathString(keyPath)}" is not a table`)
		return false
	end

	self:_queueUpdate(player, Shared.OP.Ins, path, value)
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
	local path = resolveWritePath(keyPath)
	local data = self:GetData(player)
	if not data then
		return false
	end

	local current = Shared.readPath(data, path)
	if current ~= nil and typeof(current) ~= "number" then
		warn(`EZProfileStore: IncrementData target at "{Shared.toPathString(keyPath)}" is not a number`)
		return false
	end

	local newValue = (current or 0) + (delta or 1)
	if not checkSavable("IncrementData", Shared.toPathString(keyPath), newValue) then
		return false
	end
	if not Shared.writePath(data, path, newValue, false) then
		return false
	end

	self:_queueUpdate(player, Shared.OP.Set, path, newValue)
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
	local path = resolveWritePath(keyPath)
	local data = self:GetData(player)
	if not data then
		return false
	end

	if Shared.readPath(data, path) == nil then
		return false
	end

	if not Shared.writePath(data, path, nil, false) then
		return false
	end

	self:_queueUpdate(player, Shared.OP.Del, path)
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
	local path = resolveWritePath(arrayPath)
	local data = self:GetData(player)
	if not data then
		return false
	end
	if not checkSavable("UpdateArrayItem", Shared.toPathString(arrayPath), value) then
		return false
	end

	if not Shared.arrayUpdate(data, path, index, value) then
		return false
	end

	self:_queueUpdate(player, Shared.OP.AUpd, path, index, value)
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
	local path = resolveWritePath(arrayPath)
	local data = self:GetData(player)
	if not data then
		return false
	end

	if not Shared.arrayRemove(data, path, index) then
		return false
	end

	self:_queueUpdate(player, Shared.OP.ARm, path, index)
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
		local path = resolveWritePath(write.path)
		if write.value ~= nil and not checkSavable("BatchSetValues", Shared.toPathString(write.path), write.value) then
			continue
		end
		if self:_commitSet(player, data, path, write.path, write.value) then
			changed += 1
		end
	end
	return changed
end

--[=[
	Edits a draft copy of the player's data and commits it all-or-nothing.

	The transform must not yield. If it errors, returns `false`, produces unsavable
	values, or fails `config.validate`, live data is untouched. Otherwise the draft is
	diffed against live data and only the changed paths are written and replicated.

	```lua
	store:Mutate(player, function(data)
		if data.Coins < 100 then
			return false
		end
		data.Coins -= 100
		table.insert(data.Inventory, "Sword")
	end)
	```
	@within Server
	@method Mutate
	@param player Player
	@param transform (data: { [any]: any }) -> ...boolean
	@return boolean -- `true` if the draft was committed.
]=]
function Server.Mutate(self: Server, player: Player, transform: (data: { [any]: any }) -> ...boolean): boolean
	assert(typeof(transform) == "function", "Mutate expects a transform function")
	return self:MutateMany({ player }, function(drafts)
		return transform(drafts[player])
	end)
end

--[=[
	Like `Mutate`, but commits drafts for several loaded players together or not at all.

	Use it for trades so a failed check cannot leave one side changed. ProfileStore still
	saves each profile independently, so this is atomic in memory, not across a server crash.
	@within Server
	@method MutateMany
	@param players { Player }
	@param transform (drafts: { [Player]: { [any]: any } }) -> ...boolean
	@return boolean -- `true` if every draft was committed.
]=]
function Server.MutateMany(
	self: Server,
	players: { Player },
	transform: (drafts: { [Player]: { [any]: any } }) -> ...boolean
): boolean
	assert(typeof(players) == "table" and #players > 0, "MutateMany expects a non-empty player list")
	assert(typeof(transform) == "function", "MutateMany expects a transform function")

	local originals: { [Player]: { [any]: any } } = {}
	local drafts: { [Player]: { [any]: any } } = {}
	for _, player in players do
		assert(drafts[player] == nil, "MutateMany players must be unique")
		local data = self:GetData(player)
		if not data then
			return false
		end
		originals[player] = data
		drafts[player] = Shared.deepCopy(data)
	end

	-- A yielding transform could interleave with other writes and commit a stale diff.
	local thread = coroutine.create(transform)
	local ok, result = coroutine.resume(thread, drafts)
	if coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
		warn("EZProfileStore: Mutate transform must not yield; changes were discarded")
		return false
	elseif not ok then
		warn(`EZProfileStore: Mutate transform errored; changes were discarded: {result}`)
		return false
	elseif result == false then
		return false
	end

	local changesByPlayer: { [Player]: { Shared.Change } } = {}
	for _, player in players do
		local draft = drafts[player]
		if typeof(draft) ~= "table" then
			warn("EZProfileStore: Mutate drafts must remain tables")
			return false
		end

		local changes = Shared.diff(originals[player], draft)
		for _, change in changes do
			local key = change.path[1]
			if not Shared.isValidKey(key) then
				warn(`EZProfileStore: Mutate rejected root key {tostring(key)}; keys must be strings without "."`)
				return false
			end
			if change.value ~= nil and not checkSavable("Mutate", table.concat(change.path, "."), change.value) then
				return false
			end
		end

		if #changes > 0 then
			local valid, reason = runValidator(self._validate, draft)
			if not valid then
				warn(`EZProfileStore: Mutate rejected by validate: {reason}`)
				return false
			end
		end
		changesByPlayer[player] = changes
	end

	local committed: { { player: Player, change: Shared.Change } } = {}
	for _, player in players do
		local data = originals[player]
		for _, change in changesByPlayer[player] do
			if self:_applySet(player, data, change.path, change.value) then
				table.insert(committed, { player = player, change = change })
			end
		end
	end

	for _, entry in committed do
		self.DataUpdated:Fire(entry.player, entry.change.path, entry.change.value)
	end
	return true
end

--[=[
	Sends a message to a profile, online or offline, via `ProfileStore:MessageAsync`.
	Useful for gifts and admin grants; handle it with `OnMessage`.
	@within Server
	@method SendMessageAsync
	@yields
	@param target Target
	@param message { [any]: any }
	@return boolean
]=]
function Server.SendMessageAsync(self: Server, target: Target, message: { [any]: any }): boolean
	assert(typeof(message) == "table", "message must be a table")
	local key = self:GetKey(target)
	if not checkSavable("SendMessageAsync", key, message) then
		return false
	end
	return self._store:MessageAsync(key, message) == true
end

--[=[
	Handles messages for loaded profiles, including ones already waiting. Call `processed`
	after applying a message (usually with `Mutate`) so it is not delivered again.

	```lua
	store:OnMessage(function(player, message, processed)
		if message.type == "Gift" and store:Mutate(player, function(data)
			data.Coins += message.coins
		end) then
			processed()
		end
	end)
	```
	@within Server
	@method OnMessage
	@param handler MessageHandler
	@return () -> () -- Disconnects the handler.
]=]
function Server.OnMessage(self: Server, handler: MessageHandler): () -> ()
	assert(typeof(handler) == "function", "OnMessage expects a function")
	local entry: MessageHandlerEntry = { handler = handler, active = true }
	table.insert(self._messageHandlers, entry)
	for player, profile in self._profiles do
		self:_attachMessageHandler(player, profile, entry)
	end

	return function()
		entry.active = false
		local index = table.find(self._messageHandlers, entry)
		if index then
			table.remove(self._messageHandlers, index)
		end
	end
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
	table.clear(self._sequences)
	table.clear(self._rollbackPreviews)
	for _, entry in self._messageHandlers do
		entry.active = false
	end
	table.clear(self._messageHandlers)

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
