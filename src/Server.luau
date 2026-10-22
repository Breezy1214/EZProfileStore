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
	.template Data -- Current data template; its type becomes `Data`.
	.keyPrefix string? -- Defaults to `"Player_"`.
	.mode "live" | "studio" | "mock"? -- Defaults to `"live"`.
	.store ProfileStore<Data>? -- Injected store for tests.
	.profileStore ProfileStoreModule? -- Injected ProfileStore module.
	.migrations Migrations | { MigrationInput }? -- Ordered migrations.
	.migrateNewProfiles boolean? -- Defaults to `false`.
	.migrationMetadataKey string? -- Defaults to `"EZProfileStoreVersion"`.
	.remoteParent Instance? -- Defaults to `ReplicatedStorage`.
	.autoLoadPlayers boolean? -- Start sessions for joining players. Defaults to `true`; set `false` in unit tests.
	.leaderstats { LeaderstatEntry<Data> }? -- Mirrored profile paths.
	.privatePaths { AnyPath<Data> }? -- Server-only paths that never replicate.
	.validate ((data: Data) -> (boolean, string?))? -- Checked on load and by `Mutate`.
]=]

--[=[
	@interface LeaderstatEntry
	@within Server
	.path Path<Data, number> | Path<Data, string>
	.name string
	.type "IntValue" | "NumberValue" | "StringValue"
]=]

--[=[
	@prop ProfileLoaded Signal<Player, Profile<Data>>
	@within Server
	Fires when a profile is ready.
]=]

--[=[
	@prop ProfileReleased Signal<Player>
	@within Server
	Fires when a session ends.
]=]

--[=[
	@prop FirstJoin Signal<Player, Data>
	@within Server
	Fires on the first profile session.
]=]

--[=[
	@prop DataUpdated Signal<Player, string, unknown>
	@within Server
	Fires after a replicated mutation with the dot-joined path (compare with `Path.keyOf(path)`) and new value.
]=]

--[=[
	@prop PreSave Signal<Player, Data>
	@within Server
	Forwards `Profile.OnSave`.
]=]

--[=[
	@prop PostSave Signal<Player, Data>
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
	@type MessageHandler (player: Player, message: Table, processed: () -> ()) -> ()
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
local Shared = require(script.Parent.Shared)
local Signal = require(script.Parent.Parent.Signal)
local Types = require(script.Parent.Types)
local Promise = (require(script.Parent.Parent.Promise) :: unknown) :: Types.PromiseLibrary

local DEFAULT_KEY_PREFIX = "Player_"
local DEFAULT_MIGRATION_METADATA_KEY = "EZProfileStoreVersion"

type Table = Types.Table
type Path<Data, V> = Types.Path<Data, V>
type AnyPath<Data> = Types.AnyPath<Data>
type Write<Data> = Types.Write<Data>
export type StoreMode = Types.StoreMode
export type Target = Types.Target
type LastSaveReason = Types.LastSaveReason
type LeaderstatType = Types.LeaderstatType
export type VersionSelector = Types.VersionSelector
export type RollbackResult = Types.RollbackResult
export type LeaderstatEntry<Data> = Types.LeaderstatEntry<Data>
type ProfileConnection = Types.ProfileConnection
export type Profile<Data> = Types.Profile<Data>
type ProfileStore<Data> = Types.ProfileStore<Data>
type ProfileStoreModule = Types.ProfileStoreModule
export type Config<Data> = Types.ServerConfig<Data>
export type MessageHandler = Types.MessageHandler
export type Server<Data> = Types.Server<Data>

type RollbackSelection = {
	key: string,
	profile: Profile<Table>,
}

type ResolvedLeaderstatEntry = {
	path: { string },
	pathStr: string,
	name: string,
	type: LeaderstatType,
}

type HeldUpdate = {
	player: Player,
	opcode: string,
	pathStr: string,
	valueOrIndex: unknown,
	value: unknown,
}
type HeldEvent = {
	player: Player,
	pathStr: string,
	value: unknown,
}
type TransactionState = {
	undo: { () -> () },
	updates: { HeldUpdate },
	events: { HeldEvent },
	players: { [Player]: true },
}

type MessageHandlerEntry = {
	handler: MessageHandler,
	active: boolean,
}

type ValueBase = IntValue | NumberValue | StringValue

local Server = {}
Server.__index = Server

type Self = typeof(setmetatable(
	{} :: {
		_store: ProfileStore<Table>,
		_keyPrefix: string,
		_migrations: Migrations.Migrations?,
		_migrateNewProfiles: boolean,
		_migrationMetadataKey: string,
		_profiles: { [Player]: Profile<Table> },
		_connections: { RBXScriptConnection },
		_profileConnections: { [Player]: { ProfileConnection } },
		_destroyedSignal: Signal.Signal<>,
		_dataUpdate: RemoteEvent,
		_requestData: RemoteFunction,
		_isDestroyed: boolean,
		_pendingBatches: { [Player]: Shared.Batch },
		_sequences: { [Player]: number },
		_dirtyLeaderstats: { [Player]: true },
		_profileWaits: { [Player]: Types.Promise },
		_snapshotRequests: { [Player]: true },
		_flushScheduled: boolean,
		_privatePaths: { { string } },
		_validate: ((data: Table) -> (boolean, string?))?,
		_messageHandlers: { MessageHandlerEntry },
		_leaderstatsConfig: { ResolvedLeaderstatEntry },
		_leaderstats: { [Player]: { [string]: ValueBase } },
		_rollbackPreviews: { [RollbackResult]: RollbackSelection },
		_transaction: TransactionState?,
		IsMock: boolean,
		ProfileLoaded: Signal.Signal<Player, Profile<Table>>,
		ProfileReleased: Signal.Signal<Player>,
		FirstJoin: Signal.Signal<Player, Table>,
		DataUpdated: Signal.Signal<Player, string, unknown>,
		PreSave: Signal.Signal<Player, Table>,
		PostSave: Signal.Signal<Player, Table>,
		LastSave: Signal.Signal<Player, LastSaveReason>,
		Migrated: Signal.Signal<Player, Migrations.Report>,
		ProfileLoadFailed: Signal.Signal<Player, string>,
		RolledBack: Signal.Signal<RollbackResult>,
	},
	Server
))

local resolvedProfileStore: ProfileStoreModule? = nil

local requireDynamic: (module: ModuleScript) -> unknown = require

local function requireProfileStoreModule(module: Instance?, location: string): ProfileStoreModule?
	if module == nil then
		return nil
	end
	if not module:IsA("ModuleScript") then
		error(`EZProfileStore.Server: {location} is a {module.ClassName}, expected ModuleScript`, 3)
	end
	local exports = Shared.asTable(requireDynamic(module))
	if exports == nil or typeof(exports.New) ~= "function" then
		error(`EZProfileStore.Server: {location} does not look like ProfileStore (missing New)`, 3)
	end
	return (exports :: unknown) :: ProfileStoreModule
end

local function findProfileStoreInService(serviceName: string): ProfileStoreModule?
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

local function getProfileStore(): ProfileStoreModule
	if resolvedProfileStore ~= nil then
		return resolvedProfileStore
	end

	local packageParent = script.Parent.Parent
	local found = requireProfileStoreModule(
		packageParent:FindFirstChild("ProfileStore"),
		`{packageParent:GetFullName()}.ProfileStore`
	) or findProfileStoreInService("ServerScriptService") or findProfileStoreInService("ServerStorage") or findProfileStoreInService(
		"ReplicatedStorage"
	)

	if found == nil then
		error(
			"EZProfileStore.Server: could not find ProfileStore. Install EZProfileStore with Wally and mount ServerPackages, or place ProfileStore next to the package in _Index.",
			3
		)
	end

	resolvedProfileStore = found
	return found
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

local LEADERSTAT_TYPE_TO_LUA: { [LeaderstatType]: string } = {
	IntValue = "number",
	NumberValue = "number",
	StringValue = "string",
}

local function validateLeaderstats(template: Table, entries: { LeaderstatEntry<Table> }): { ResolvedLeaderstatEntry }
	local resolved: { ResolvedLeaderstatEntry } = {}
	for i, entry in entries do
		assert(typeof(entry) == "table", `leaderstats[{i}] must be a table`)
		assert(typeof(entry.name) == "string" and #entry.name > 0, `leaderstats[{i}].name must be a non-empty string`)
		local expectedType = LEADERSTAT_TYPE_TO_LUA[entry.type]
		assert(expectedType ~= nil, `leaderstats[{i}].type must be IntValue, NumberValue, or StringValue`)

		local path, pathStr = Shared.resolvePath(entry.path)
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

local function resolveMigrations(configured: (Migrations.Migrations | { Migrations.Input })?): Migrations.Migrations?
	local candidate = Shared.asTable(configured)
	if candidate == nil then
		return nil
	end

	if typeof(candidate.Migrate) == "function" and typeof(candidate.GetLatestVersion) == "function" then
		return (candidate :: unknown) :: Migrations.Migrations
	end

	return Migrations.new((candidate :: unknown) :: { Migrations.Input })
end

local function resolvePrivatePaths(configured: { AnyPath<Table> }?): { { string } }
	local resolved: { { string } } = {}
	if configured == nil then
		return resolved
	end
	for i, entry in configured do
		local path = Shared.resolvePath(entry)
		assert(#path > 0, `privatePaths[{i}] must not be empty`)
		table.insert(resolved, path)
	end
	return resolved
end

local function checkSavable(method: string, label: string, value: unknown): boolean
	local ok, reason = Shared.validateValue(value)
	if not ok then
		warn(`EZProfileStore: {method} rejected "{label}": {reason}`)
	end
	return ok
end

local function runValidator(validate: ((data: Table) -> (boolean, string?))?, data: Table): (boolean, string?)
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

local function runTransform<A...>(transform: (A...) -> ...boolean, ...: A...): string?
	local thread = coroutine.create(transform)
	local ok, result = coroutine.resume(thread, ...)
	if coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
		return "transform must not yield"
	elseif not ok then
		return `transform errored: {result}`
	elseif result == false then
		return ""
	end
	return nil
end

local function truncate<T>(list: { T }, length: number)
	for i = #list, length + 1, -1 do
		list[i] = nil
	end
end

local function resolveMode(config: Config<Table>): StoreMode
	local mode: StoreMode = config.mode or "live"
	assert(mode == "live" or mode == "studio" or mode == "mock", 'config.mode must be "live", "studio", or "mock"')
	return mode
end

local function newLeaderstat(kind: LeaderstatType): ValueBase
	if kind == "IntValue" then
		return Instance.new("IntValue")
	elseif kind == "NumberValue" then
		return Instance.new("NumberValue")
	end
	return Instance.new("StringValue")
end

local function writeLeaderstat(instance: ValueBase, value: unknown)
	if instance:IsA("StringValue") then
		local target = instance :: StringValue
		if typeof(value) == "string" and target.Value ~= value then
			target.Value = value
		end
	elseif instance:IsA("IntValue") then
		local target = instance :: IntValue
		if typeof(value) == "number" and target.Value ~= value then
			target.Value = value
		end
	else
		local target = instance :: NumberValue
		if typeof(value) == "number" and target.Value ~= value then
			target.Value = value
		end
	end
end

local function isProfileActive(profile: Profile<Table>?): boolean
	return profile ~= nil and (typeof(profile.IsActive) ~= "function" or profile:IsActive())
end

local function construct(config: Config<Table>): Self
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

	local store: ProfileStore<Table>
	local isMock = config.store == nil and wantsMock
	if config.store ~= nil then
		store = config.store
	else
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

	local self: Self = setmetatable({
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
		_snapshotRequests = {},
		_flushScheduled = false,
		_privatePaths = privatePaths,
		_validate = config.validate,
		_messageHandlers = {},
		_leaderstatsConfig = resolvedLeaderstats,
		_leaderstats = {},
		_rollbackPreviews = {},
		_transaction = nil,
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
	}, Server)
	setmetatable(self._rollbackPreviews, { __mode = "k" })

	requestData.OnServerInvoke = function(player: Player): Shared.Snapshot?
		return self:_serveSnapshotRequest(player)
	end

	table.insert(
		self._connections,
		Players.PlayerRemoving:Connect(function(player)
			self:_onPlayerRemoving(player)
		end)
	)

	if config.autoLoadPlayers ~= false then
		table.insert(
			self._connections,
			Players.PlayerAdded:Connect(function(player)
				self:_onPlayerAdded(player)
			end)
		)

		for _, player in Players:GetPlayers() do
			task.spawn(function()
				self:_onPlayerAdded(player)
			end)
		end
	end

	return self
end

--[=[
	Creates a store and binds player lifecycle handlers. `Data` is inferred from `config.template`.
	@within Server
	@param config Config<Data>
	@return Server<Data>
]=]
function Server.new<Data>(config: Config<Data>): Server<Data>
	local self = construct((config :: unknown) :: Config<Table>)
	return (self :: unknown) :: Server<Data>
end

--[=[
	Creates a store backed by `ProfileStore.Mock`.
	@within Server
	@param config Config<Data>
	@return Server<Data>
]=]
function Server.mock<Data>(config: Config<Data>): Server<Data>
	assert(typeof(config) == "table", "Server.mock expects a config table")
	local resolved = table.clone(config)
	resolved.mode = "mock"
	return Server.new(resolved)
end

function Server._waitForProfile(self: Self, player: Player, timeout: number?): Profile<Table>?
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
		local loaded = Promise.fromEvent(self.ProfileLoaded, function(loadedPlayer: unknown)
			return loadedPlayer == player
		end):andThenReturn("loaded")
		local failed = Promise.fromEvent(self.ProfileLoadFailed, function(failedPlayer: unknown)
			return failedPlayer == player
		end):andThenReturn("failed")
		local leaving = Promise.fromEvent(Players.PlayerRemoving, function(leavingPlayer: unknown)
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

function Server._waitForData(self: Self, player: Player): Shared.Snapshot?
	local profile = self:_waitForProfile(player, nil)
	return if profile then self:_consumeSnapshot(player, profile) else nil
end

function Server._serveSnapshotRequest(self: Self, player: Player): Shared.Snapshot?
	if self._snapshotRequests[player] then
		return nil
	end

	self._snapshotRequests[player] = true
	local ok, snapshot = pcall(self._waitForData, self, player)
	self._snapshotRequests[player] = nil

	if not ok then
		error(snapshot, 0)
	end

	return snapshot
end

function Server._consumeSnapshot(self: Self, player: Player, profile: Profile<Table>): Shared.Snapshot
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

function Server._disconnectProfileConnections(self: Self, player: Player)
	local profileConns = self._profileConnections[player]
	if not profileConns then
		return
	end

	for _, conn in profileConns do
		conn:Disconnect()
	end
	self._profileConnections[player] = nil
end

function Server._releaseProfile(self: Self, player: Player, profile: Profile<Table>, shouldKick: boolean)
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

function Server._migrateProfile(self: Self, player: Player, profile: Profile<Table>, key: string): (boolean, string?)
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
	local rawVersion = metadata[self._migrationMetadataKey]
	local latestVersion = runner:GetLatestVersion()
	local storedVersion: number
	if rawVersion == nil then
		storedVersion = if profile.SessionLoadCount == 1 and not self._migrateNewProfiles then latestVersion else 0
	elseif typeof(rawVersion) == "number" and rawVersion >= 0 and rawVersion % 1 == 0 then
		storedVersion = rawVersion
	else
		return false, `invalid schema version {tostring(rawVersion)} in Roblox metadata "{self._migrationMetadataKey}"`
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

function Server._prepareProfile(self: Self, player: Player, profile: Profile<Table>, key: string): (boolean, string?)
	local migrationOk, migrationError = self:_migrateProfile(player, profile, key)
	if not migrationOk then
		return false, migrationError
	end

	profile:Reconcile()
	return runValidator(self._validate, profile.Data)
end

function Server._onPlayerAdded(self: Self, player: Player)
	if self._isDestroyed then
		return
	end

	local key = self:GetKey(player)
	local params: Types.StartSessionParams = {
		Cancel = function()
			return player.Parent ~= Players
		end,
	}
	local started, result = pcall(self._store.StartSessionAsync, self._store, key, params)
	local profile = if started then result else nil

	if not profile then
		local reason = if started
			then "ProfileStore could not start a profile session"
			else `StartSessionAsync errored for "{key}": {result}`
		if not started then
			warn(`EZProfileStore: {reason}`)
		end
		self.ProfileLoadFailed:Fire(player, reason)
		if player.Parent == Players then
			player:Kick("Failed to load data, please rejoin")
		end
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

function Server._attachMessageHandler(self: Self, player: Player, profile: Profile<Table>, entry: MessageHandlerEntry)
	profile:MessageHandler(function(message, processed)
		if entry.active and self._profiles[player] == profile then
			entry.handler(player, message, processed)
		end
	end)
end

function Server._onPlayerRemoving(self: Self, player: Player)
	self._leaderstats[player] = nil
	self._pendingBatches[player] = nil
	self._sequences[player] = nil
	self._snapshotRequests[player] = nil

	local profile = self._profiles[player]
	if profile then
		profile:EndSession()
		self:_releaseProfile(player, profile, false)
	else
		self:_disconnectProfileConnections(player)
	end
end

function Server._buildLeaderstats(self: Self, player: Player)
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
		local stat = newLeaderstat(entry.type)
		writeLeaderstat(stat, Shared.readPath(data, entry.path))

		local instance: Instance = stat
		instance.Name = entry.name

		local priority = Instance.new("NumberValue")
		priority.Name = "Priority"
		priority.Value = leaderstatCount - index + 1
		priority.Parent = instance

		instance.Parent = folder
		mirror[entry.pathStr] = stat
	end

	self._leaderstats[player] = mirror
	folder.Parent = player
end

function Server._mirrorLeaderstats(self: Self, player: Player)
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
			writeLeaderstat(instance, Shared.readPath(data, entry.path))
		end
	end
end

local function captureSetUndo(data: Table, path: { string }): () -> ()
	local target = data
	for i = 1, #path - 1 do
		local key = path[i]
		local child = Shared.asTable(target[key])
		if child == nil then
			local parent, old = target, target[key]
			return function()
				parent[key] = old
			end
		end
		target = child
	end

	local parent, key = target, path[#path]
	local old = parent[key]
	return function()
		parent[key] = old
	end
end

function Server._recordUndo(self: Self, player: Player, undo: () -> ())
	local transaction = self._transaction
	if transaction then
		table.insert(transaction.undo, undo)
		transaction.players[player] = true
	end
end

function Server._write(
	self: Self,
	player: Player,
	data: Table,
	path: { string },
	value: unknown,
	isInsert: boolean
): boolean
	local transaction = self._transaction
	local insertTarget = if transaction and isInsert then Shared.readArray(data, path) else nil
	local setUndo = if transaction and not isInsert then captureSetUndo(data, path) else nil

	if not Shared.writePath(data, path, value, isInsert) then
		return false
	end
	if insertTarget then
		self:_recordUndo(player, function()
			table.remove(insertTarget)
		end)
	elseif setUndo then
		self:_recordUndo(player, setUndo)
	end
	return true
end

function Server._arrayWrite(
	self: Self,
	player: Player,
	data: Table,
	path: { string },
	index: number,
	value: unknown,
	isRemove: boolean
): boolean
	local array = if self._transaction then Shared.readArray(data, path) else nil
	local old = if array then array[index] else nil
	local changed = if isRemove
		then Shared.arrayRemove(data, path, index)
		else Shared.arrayUpdate(data, path, index, value)
	if not changed then
		return false
	end

	if array then
		self:_recordUndo(player, function()
			if isRemove then
				table.insert(array, index, old)
			else
				array[index] = old
			end
		end)
	end
	return true
end

function Server._validatePlayers(self: Self, players: { [Player]: true }): string?
	for player in players do
		local data = self:GetData(player)
		if data then
			local valid, reason = runValidator(self._validate, data)
			if not valid then
				return `rejected by validate: {reason}`
			end
		end
	end
	return nil
end

function Server._emitUpdated(self: Self, player: Player, pathStr: string, value: unknown)
	local transaction = self._transaction
	if transaction then
		table.insert(transaction.events, { player = player, pathStr = pathStr, value = value })
	else
		self.DataUpdated:Fire(player, pathStr, value)
	end
end

function Server._applySet(
	self: Self,
	player: Player,
	data: Table,
	path: { string },
	pathStr: string,
	value: unknown
): boolean
	if not self:_write(player, data, path, value, false) then
		return false
	end
	self:_queueUpdate(player, if value == nil then Shared.OP.Del else Shared.OP.Set, path, pathStr, value)
	return true
end

-- Sets or deletes one path, then replicates and signals the change.
function Server._commitSet(
	self: Self,
	player: Player,
	data: Table,
	path: { string },
	pathStr: string,
	value: unknown
): boolean
	if not self:_applySet(player, data, path, pathStr, value) then
		return false
	end
	self:_emitUpdated(player, pathStr, value)
	return true
end

function Server._isPrivate(self: Self, path: { string }): boolean
	for _, privatePath in self._privatePaths do
		if Shared.isPrefix(privatePath, path) then
			return true
		end
	end
	return false
end

-- Copies at queue time so later in-frame writes cannot leak into this op's payload.
function Server._replicatedCopy(self: Self, path: { string }, value: unknown, stripPrivate: boolean): unknown
	local copy = Shared.deepCopy(value)
	local copyTable = Shared.asTable(copy)
	if stripPrivate and copyTable then
		for _, privatePath in self._privatePaths do
			if #privatePath > #path and Shared.isPrefix(path, privatePath) then
				Shared.writePath(copyTable, table.move(privatePath, #path + 1, #privatePath, 1, {}), nil, false)
			end
		end
	end
	return copy
end

function Server._queueUpdate(
	self: Self,
	player: Player,
	opcode: string,
	path: { string },
	pathStr: string,
	valueOrIndex: unknown?,
	value: unknown?
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

	local transaction = self._transaction
	if transaction then
		table.insert(transaction.updates, {
			player = player,
			opcode = opcode,
			pathStr = pathStr,
			valueOrIndex = valueOrIndex,
			value = value,
		})
		return
	end
	self:_appendToBatch(player, opcode, pathStr, valueOrIndex, value)
end

function Server._appendToBatch(
	self: Self,
	player: Player,
	opcode: string,
	pathStr: string,
	valueOrIndex: unknown,
	value: unknown
)
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

	local entry: Shared.Update = { opcode, pathStr, valueOrIndex, value }
	table.insert(batch, entry)
	self:_scheduleFlush()
end

function Server._scheduleFlush(self: Self)
	if self._flushScheduled or self._isDestroyed then
		return
	end

	self._flushScheduled = true
	task.defer(function()
		self:_flushUpdates()
	end)
end

function Server._flushUpdates(self: Self)
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

function Server._sendBatch(self: Self, player: Player, batch: Shared.Batch)
	if #batch > 0 and player.Parent == Players then
		self._dataUpdate:FireClient(player, self._sequences[player], batch)
	end
end

--[=[
	Returns the active profile.
	@within Server
	@method GetProfile
	@param player Player
	@return Profile<Data>?
]=]
function Server.GetProfile(self: Self, player: Player): Profile<Table>?
	local profile = self._profiles[player]
	return if isProfileActive(profile) then profile else nil
end

--[=[
	Yields for an active profile.
	@within Server
	@method GetProfileAsync
	@yields
	@param player Player
	@param timeout number? -- Waits until the profile loads, fails, or the player leaves by default.
	@return Profile<Data>?
]=]
function Server.GetProfileAsync(self: Self, player: Player, timeout: number?): Profile<Table>?
	return self:_waitForProfile(player, timeout)
end

--[=[
	Returns the active profile's data, typed read-only.
	@within Server
	@method GetData
	@param player Player
	@return ReadOnly<Data>?
]=]
function Server.GetData(self: Self, player: Player): Table?
	local profile = self:GetProfile(player)
	return if profile then profile.Data else nil
end

--[=[
	Yields for active profile data.
	@within Server
	@method GetDataAsync
	@yields
	@param player Player
	@param timeout number? -- Waits until the profile loads, fails, or the player leaves by default.
	@return ReadOnly<Data>?
]=]
function Server.GetDataAsync(self: Self, player: Player, timeout: number?): Table?
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
function Server.GetKey(self: Self, target: Target): string
	if typeof(target) == "Instance" then
		assert(target:IsA("Player"), "target Instance must be a Player")
		return self._keyPrefix .. tostring(target.UserId)
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
	@return ProfileStore<Data>
]=]
function Server.GetStore(self: Self): ProfileStore<Table>
	return self._store
end

--[=[
	Reads a profile path.
	@within Server
	@method ReadData
	@param player Player
	@param path Path<Data, V>
	@return ReadOnly<V>?
]=]
function Server.ReadData(self: Self, player: Player, path: unknown): unknown
	local data = self:GetData(player)
	if not data then
		return nil
	end
	return Shared.readPath(data, (Shared.resolvePath(path)))
end

--[=[
	Sets a profile path. Use `RemoveData` to delete one.
	@within Server
	@method UpdateData
	@param player Player
	@param path Path<Data, V>
	@param value V
	@return boolean -- `true` if the value changed, `false` otherwise.
]=]
function Server.UpdateData(self: Self, player: Player, path: unknown, value: unknown): boolean
	local keys, pathStr = Shared.resolvePath(path)
	local data = self:GetData(player)
	if not data then
		return false
	end
	if value ~= nil and not checkSavable("UpdateData", pathStr, value) then
		return false
	end

	return self:_commitSet(player, data, keys, pathStr, value)
end

--[=[
	Appends to an array path.
	@within Server
	@method InsertData
	@param player Player
	@param path Path<Data, { V }>
	@param value V
	@return boolean -- `true` on success, `false` if the target is not a table.
]=]
function Server.InsertData(self: Self, player: Player, path: unknown, value: unknown): boolean
	local keys, pathStr = Shared.resolvePath(path)
	local data = self:GetData(player)
	if not data then
		return false
	end
	if not checkSavable("InsertData", pathStr, value) then
		return false
	end

	if not self:_write(player, data, keys, value, true) then
		warn(`EZProfileStore: InsertData target at "{pathStr}" is not a table`)
		return false
	end

	self:_queueUpdate(player, Shared.OP.Ins, keys, pathStr, value)
	self:_emitUpdated(player, pathStr, value)
	return true
end

--[=[
	Adds `delta` to a numeric path.
	@within Server
	@method IncrementData
	@param player Player
	@param path Path<Data, number>
	@param delta number? -- Defaults to `1`.
	@return boolean
]=]
function Server.IncrementData(self: Self, player: Player, path: unknown, delta: number?): boolean
	local keys, pathStr = Shared.resolvePath(path)
	local data = self:GetData(player)
	if not data then
		return false
	end

	local current = Shared.readPath(data, keys)
	local base: number
	if current == nil then
		base = 0
	elseif typeof(current) == "number" then
		base = current
	else
		warn(`EZProfileStore: IncrementData target at "{pathStr}" is not a number`)
		return false
	end

	local newValue = base + (delta or 1)
	if not checkSavable("IncrementData", pathStr, newValue) then
		return false
	end
	return self:_commitSet(player, data, keys, pathStr, newValue)
end

--[=[
	Subtracts `delta` from a numeric path.
	@within Server
	@method DecrementData
	@param player Player
	@param path Path<Data, number>
	@param delta number? -- Defaults to `1`.
	@return boolean
]=]
function Server.DecrementData(self: Self, player: Player, path: unknown, delta: number?): boolean
	return self:IncrementData(player, path, -(delta or 1))
end

--[=[
	Deletes a profile path.
	@within Server
	@method RemoveData
	@param player Player
	@param path AnyPath<Data>
	@return boolean
]=]
function Server.RemoveData(self: Self, player: Player, path: unknown): boolean
	local keys, pathStr = Shared.resolvePath(path)
	local data = self:GetData(player)
	if not data then
		return false
	end

	return self:_commitSet(player, data, keys, pathStr, nil)
end

--[=[
	Replaces an array item by index.
	@within Server
	@method UpdateArrayItem
	@param player Player
	@param path Path<Data, { V }> -- Path to the array.
	@param index number
	@param value V
	@return boolean
]=]
function Server.UpdateArrayItem(self: Self, player: Player, path: unknown, index: number, value: unknown): boolean
	local keys, pathStr = Shared.resolvePath(path)
	local data = self:GetData(player)
	if not data then
		return false
	end
	if not checkSavable("UpdateArrayItem", pathStr, value) then
		return false
	end

	if not self:_arrayWrite(player, data, keys, index, value, false) then
		return false
	end

	self:_queueUpdate(player, Shared.OP.AUpd, keys, pathStr, index, value)
	self:_emitUpdated(player, pathStr, value)
	return true
end

--[=[
	Removes an array item by index.
	@within Server
	@method RemoveArrayItem
	@param player Player
	@param path Path<Data, { V }>
	@param index number
	@return boolean
]=]
function Server.RemoveArrayItem(self: Self, player: Player, path: unknown, index: number): boolean
	local keys, pathStr = Shared.resolvePath(path)
	local data = self:GetData(player)
	if not data then
		return false
	end

	if not self:_arrayWrite(player, data, keys, index, nil, true) then
		return false
	end

	self:_queueUpdate(player, Shared.OP.ARm, keys, pathStr, index)
	self:_emitUpdated(player, pathStr, nil)
	return true
end

--[=[
	Applies several `Path.write` entries in one replication batch.
	@within Server
	@method BatchSetValues
	@param player Player
	@param writes { Write<Data> }
	@return number -- How many paths changed.
]=]
function Server.BatchSetValues(self: Self, player: Player, writes: { Write<Table> }): number
	local data = self:GetData(player)
	if not data then
		return 0
	end

	local changed = 0
	for _, write in writes do
		local keys, pathStr = Shared.resolvePath(write.path)
		if write.value ~= nil and not checkSavable("BatchSetValues", pathStr, write.value) then
			continue
		end
		if self:_commitSet(player, data, keys, pathStr, write.value) then
			changed += 1
		end
	end
	return changed
end

--[=[
	Edits a copy of the player's data and commits the changed paths all-or-nothing.
	@within Server
	@method Mutate
	@param player Player
	@param transform (draft: Data) -> ...boolean
	@return boolean -- `true` if the draft was committed.
]=]
function Server.Mutate(self: Self, player: Player, transform: (draft: Table) -> ...boolean): boolean
	assert(typeof(transform) == "function", "Mutate expects a transform function")
	return self:MutateMany({ player }, function(drafts)
		return transform(drafts[player])
	end)
end

--[=[
	Like `Mutate`, for several loaded players at once.
	@within Server
	@method MutateMany
	@param players { Player }
	@param transform (drafts: { [Player]: Data }) -> ...boolean
	@return boolean -- `true` if every draft was committed.
]=]
function Server.MutateMany(
	self: Self,
	players: { Player },
	transform: (drafts: { [Player]: Table }) -> ...boolean
): boolean
	assert(typeof(players) == "table" and #players > 0, "MutateMany expects a non-empty player list")
	assert(typeof(transform) == "function", "MutateMany expects a transform function")

	local originals: { [Player]: Table } = {}
	local drafts: { [Player]: Table } = {}
	for _, player in players do
		assert(drafts[player] == nil, "MutateMany players must be unique")
		local data = self:GetData(player)
		if not data then
			return false
		end
		originals[player] = data
		drafts[player] = Shared.deepCopy(data)
	end

	local failure = runTransform(transform, drafts)
	if failure ~= nil then
		if failure ~= "" then
			warn(`EZProfileStore: Mutate {failure}; changes were discarded`)
		end
		return false
	end

	local changesByPlayer: { [Player]: { Shared.Change } } = {}
	for _, player in players do
		local draft = Shared.asTable(drafts[player])
		if draft == nil then
			warn("EZProfileStore: Mutate drafts must remain tables")
			return false
		end

		local changes, invalidKey = Shared.diff(originals[player], draft)
		if changes == nil then
			warn(`EZProfileStore: Mutate rejected key {tostring(invalidKey)}; keys must be strings without "."`)
			return false
		end
		for _, change in changes do
			if change.value ~= nil and not checkSavable("Mutate", change.key, change.value) then
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
			if self:_applySet(player, data, change.path, change.key, change.value) then
				table.insert(committed, { player = player, change = change })
			end
		end
	end

	for _, entry in committed do
		self:_emitUpdated(entry.player, entry.change.key, entry.change.value)
	end
	return true
end

--[=[
	Makes the mutations inside `transform` all-or-nothing; replication waits until commit.
	@within Server
	@method Transaction
	@param transform () -> ...boolean
	@return boolean -- `true` if the writes were committed.
]=]
function Server.Transaction(self: Self, transform: () -> ...boolean): boolean
	assert(typeof(transform) == "function", "Transaction expects a transform function")

	local outer = self._transaction
	local transaction: TransactionState = outer or { undo = {}, updates = {}, events = {}, players = {} }
	local undoMark, updateMark, eventMark = #transaction.undo, #transaction.updates, #transaction.events
	self._transaction = transaction

	local failure = runTransform(transform)
	if failure == nil and outer == nil then
		failure = self:_validatePlayers(transaction.players)
	end

	if failure ~= nil then
		for i = #transaction.undo, undoMark + 1, -1 do
			transaction.undo[i]()
		end
		truncate(transaction.undo, undoMark)
		truncate(transaction.updates, updateMark)
		truncate(transaction.events, eventMark)
		self._transaction = outer
		if failure ~= "" then
			warn(`EZProfileStore: Transaction {failure}; changes were rolled back`)
		end
		return false
	elseif outer ~= nil then
		return true
	end

	self._transaction = nil
	for _, update in transaction.updates do
		self:_appendToBatch(update.player, update.opcode, update.pathStr, update.valueOrIndex, update.value)
	end
	for _, event in transaction.events do
		self.DataUpdated:Fire(event.player, event.pathStr, event.value)
	end
	return true
end

--[=[
	Sends a message to a profile, online or offline, via `ProfileStore:MessageAsync`.
	@within Server
	@method SendMessageAsync
	@yields
	@param target Target
	@param message Table
	@return boolean
]=]
function Server.SendMessageAsync(self: Self, target: Target, message: Table): boolean
	assert(typeof(message) == "table", "message must be a table")
	local key = self:GetKey(target)
	if not checkSavable("SendMessageAsync", key, message) then
		return false
	end
	return self._store:MessageAsync(key, message) == true
end

--[=[
	Handles profile messages; call `processed` once a message is applied.
	@within Server
	@method OnMessage
	@param handler MessageHandler
	@return () -> () -- Disconnects the handler.
]=]
function Server.OnMessage(self: Self, handler: MessageHandler): () -> ()
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
function Server.SaveAsync(self: Self, player: Player): boolean
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
function Server.IsReady(self: Self, player: Player): boolean
	return self:GetProfile(player) ~= nil
end

local function rollbackResult(key: string, profile: Profile<Table>): RollbackResult
	local keyInfo = profile.KeyInfo
	assert(keyInfo ~= nil, "historical profile is missing KeyInfo")
	assert(typeof(keyInfo.Version) == "string", "historical profile KeyInfo is missing Version")
	assert(typeof(keyInfo.UpdatedTime) == "number", "historical profile KeyInfo is missing UpdatedTime")
	assert(Shared.asTable(profile.Data) ~= nil, "historical profile Data must be a table")
	return {
		key = key,
		version = keyInfo.Version,
		updatedTime = keyInfo.UpdatedTime,
		data = Shared.deepCopy(profile.Data),
	}
end

function Server._selectRollback(self: Self, target: Target, selector: VersionSelector?): RollbackSelection?
	local key = self:GetKey(target)
	local resolved: VersionSelector = selector or ({} :: VersionSelector)
	assert(
		resolved.version == nil or (resolved.before == nil and resolved.stepsBack == nil),
		"selector.version cannot be combined with before or stepsBack"
	)

	local profile: Profile<Table>? = nil
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

function Server._endActiveSessionForKeyAsync(self: Self, key: string): boolean
	local activePlayer: Player? = nil
	local activeProfile: Profile<Table>? = nil
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

	local released = Promise.fromEvent(self.ProfileReleased, function(player: unknown)
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

function Server._applyRollbackAsync(self: Self, selection: RollbackSelection): RollbackResult
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
function Server.PreviewRollbackAsync(self: Self, target: Target, selector: VersionSelector?): RollbackResult?
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
function Server.ApplyRollbackAsync(self: Self, preview: RollbackResult): RollbackResult
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
function Server.RollbackAsync(self: Self, target: Target, selector: VersionSelector?): RollbackResult?
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
function Server.WipeAsync(self: Self, target: Target): boolean
	local key = self:GetKey(target)
	assert(self:_endActiveSessionForKeyAsync(key), "active profile did not finish saving before wipe")
	return self._store:RemoveAsync(key)
end

--[=[
	Releases sessions, connections, and signals.
	@within Server
	@method Destroy
]=]
function Server.Destroy(self: Self)
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
	table.clear(self._snapshotRequests)
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
