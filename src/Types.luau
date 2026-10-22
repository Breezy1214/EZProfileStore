--!strict
--[=[
	@class Types
	@private

	Public types shared by `Server`, `Client`, and the package entrypoint.
]=]

local Fusion = require(script.Parent.Parent.Fusion)
local Migrations = require(script.Parent.Migrations)
local Shared = require(script.Parent.Shared)
local Signal = require(script.Parent.Parent.Signal)

export type Table = Shared.Table

--[=[
	@type ReadOnly<T> T
	@within EZProfileStore
	`T` with every field read-only, recursively.
]=]
export type function ReadOnly(value: type)
	local function convert(current: type, depth: number): type
		if depth == 0 then
			return current
		elseif current:is("union") or current:is("intersection") then
			local components = {}
			for _, component in current:components() do
				table.insert(components, convert(component, depth - 1))
			end
			return if current:is("union")
				then types.unionof(table.unpack(components))
				else types.intersectionof(table.unpack(components))
		elseif not current:is("table") then
			return current
		end

		local result = types.newtable()
		for key, prop in current:properties() do
			if prop.read then
				result:setreadproperty(key, convert(prop.read, depth - 1))
			end
		end
		local indexer = current:indexer()
		if indexer then
			result:setindexer(indexer.index, convert(indexer.readresult, depth - 1))
		end
		return result
	end

	return convert(value, 24)
end

export type PromiseStatus = "Started" | "Resolved" | "Rejected" | "Cancelled"

export type Promise = {
	andThen: (
		self: Promise,
		onResolved: ((...unknown) -> ...unknown)?,
		onRejected: ((...unknown) -> ...unknown)?
	) -> Promise,
	andThenReturn: (self: Promise, ...unknown) -> Promise,
	catch: (self: Promise, onRejected: (...unknown) -> ...unknown) -> Promise,
	finally: (self: Promise, callback: (status: PromiseStatus) -> ...unknown) -> Promise,
	timeout: (self: Promise, seconds: number, rejectionValue: unknown?) -> Promise,
	await: (self: Promise) -> (boolean, ...unknown),
	expect: (self: Promise) -> ...unknown,
	getStatus: (self: Promise) -> PromiseStatus,
	cancel: (self: Promise) -> (),
}

export type PromiseLibrary = {
	new: (executor: (resolve: (...unknown) -> (), reject: (...unknown) -> ()) -> ()) -> Promise,
	resolve: (...unknown) -> Promise,
	all: (promises: { Promise }) -> Promise,
	race: (promises: { Promise }) -> Promise,
	fromEvent: (event: unknown, predicate: ((...unknown) -> boolean)?) -> Promise,
	Status: {
		Started: PromiseStatus,
		Resolved: PromiseStatus,
		Rejected: PromiseStatus,
		Cancelled: PromiseStatus,
	},
}

export type StoreMode = "live" | "studio" | "mock"
export type Target = Player | number | string
export type LastSaveReason = "Manual" | "External" | "Shutdown"
export type LeaderstatType = "IntValue" | "NumberValue" | "StringValue"

export type VersionSelector = {
	version: string?,
	before: DateTime | number?,
	stepsBack: number?,
}
export type RollbackResult = {
	key: string,
	version: string,
	updatedTime: number,
	data: Table,
}

export type LeaderstatEntry<Data> = {
	name: string,
	type: LeaderstatType,
	value: (data: ReadOnly<Data>) -> number | string,
}

export type ProfileConnection = {
	Disconnect: (self: ProfileConnection) -> (),
}
export type ProfileSignal<T...> = {
	Connect: (self: ProfileSignal<T...>, listener: (T...) -> ()) -> ProfileConnection,
}

export type Profile<Data> = {
	Data: Data,
	Key: string,
	SessionLoadCount: number,
	RobloxMetaData: Table,
	UserIds: { number },
	KeyInfo: DataStoreKeyInfo?,
	OnSave: ProfileSignal<>,
	OnAfterSave: ProfileSignal<Data>,
	OnLastSave: ProfileSignal<LastSaveReason>,
	OnSessionEnd: ProfileSignal<>,
	IsActive: (self: Profile<Data>) -> boolean,
	Reconcile: (self: Profile<Data>) -> (),
	EndSession: (self: Profile<Data>) -> (),
	AddUserId: (self: Profile<Data>, userId: number) -> (),
	MessageHandler: (self: Profile<Data>, handler: (message: Table, processed: () -> ()) -> ()) -> (),
	Save: (self: Profile<Data>) -> (),
	SetAsync: (self: Profile<Data>) -> (),
}

export type VersionQuery<Data> = {
	NextAsync: (self: VersionQuery<Data>) -> Profile<Data>?,
}

export type StartSessionParams = {
	Cancel: (() -> boolean)?,
	Steal: boolean?,
}

export type ProfileStore<Data> = {
	StartSessionAsync: (self: ProfileStore<Data>, key: string, params: StartSessionParams?) -> Profile<Data>?,
	MessageAsync: (self: ProfileStore<Data>, key: string, message: Table) -> boolean,
	GetAsync: (self: ProfileStore<Data>, key: string, version: string?) -> Profile<Data>?,
	VersionQuery: (
		self: ProfileStore<Data>,
		key: string,
		sortDirection: Enum.SortDirection?,
		minDate: (DateTime | number)?,
		maxDate: (DateTime | number)?
	) -> VersionQuery<Data>,
	RemoveAsync: (self: ProfileStore<Data>, key: string) -> boolean,
	Mock: ProfileStore<Data>?,
}

export type ProfileStoreModule = {
	New: (storeName: string, template: Table) -> ProfileStore<Table>,
}

export type ServerConfig<Data> = {
	storeName: string,
	template: Data,
	keyPrefix: string?,
	mode: StoreMode?,
	store: ProfileStore<Data>?,
	profileStore: ProfileStoreModule?,
	migrations: (Migrations.Migrations | { Migrations.Input })?,
	migrateNewProfiles: boolean?,
	migrationMetadataKey: string?,
	remoteParent: Instance?,
	autoLoadPlayers: boolean?,
	leaderstats: { LeaderstatEntry<Data> }?,
	privatePaths: { (data: Data) -> unknown }?,
	validate: ((data: ReadOnly<Data>) -> (boolean, string?))?,
}

export type MessageHandler = (player: Player, message: Table, processed: () -> ()) -> ()

export type Server<Data> = {
	IsMock: boolean,
	ProfileLoaded: Signal.Signal<Player, Profile<Data>>,
	ProfileReleased: Signal.Signal<Player>,
	FirstJoin: Signal.Signal<Player, Data>,
	Changed: Signal.Signal<Player, ReadOnly<Data>>,
	PreSave: Signal.Signal<Player, Data>,
	PostSave: Signal.Signal<Player, Data>,
	LastSave: Signal.Signal<Player, LastSaveReason>,
	Migrated: Signal.Signal<Player, Migrations.Report>,
	ProfileLoadFailed: Signal.Signal<Player, string>,
	RolledBack: Signal.Signal<RollbackResult>,

	Get: (self: Server<Data>, player: Player) -> ReadOnly<Data>?,
	GetAsync: (self: Server<Data>, player: Player, timeout: number?) -> ReadOnly<Data>?,
	Update: (self: Server<Data>, player: Player, transform: (data: Data) -> ...boolean?) -> boolean,
	UpdateMany: (
		self: Server<Data>,
		players: { Player },
		transform: (drafts: { [Player]: Data }) -> ...boolean?
	) -> boolean,

	GetProfile: (self: Server<Data>, player: Player) -> Profile<Data>?,
	GetProfileAsync: (self: Server<Data>, player: Player, timeout: number?) -> Profile<Data>?,
	GetKey: (self: Server<Data>, target: Target) -> string,
	GetStore: (self: Server<Data>) -> ProfileStore<Data>,
	IsReady: (self: Server<Data>, player: Player) -> boolean,
	SendMessageAsync: (self: Server<Data>, target: Target, message: Table) -> boolean,
	OnMessage: (self: Server<Data>, handler: MessageHandler) -> () -> (),
	SaveAsync: (self: Server<Data>, player: Player) -> boolean,
	PreviewRollbackAsync: (self: Server<Data>, target: Target, selector: VersionSelector?) -> RollbackResult?,
	ApplyRollbackAsync: (self: Server<Data>, preview: RollbackResult) -> RollbackResult,
	RollbackAsync: (self: Server<Data>, target: Target, selector: VersionSelector?) -> RollbackResult?,
	WipeAsync: (self: Server<Data>, target: Target) -> boolean,
	Destroy: (self: Server<Data>) -> (),
}

export type ClientConfig<Data> = {
	remoteParent: Instance?,
	waitTimeout: number?,
	template: Data?,
}

export type Disconnect = () -> ()

export type Ready<T> = {
	andThen: (
		self: Ready<T>,
		onResolved: ((value: T) -> ...unknown)?,
		onRejected: ((reason: unknown) -> ...unknown)?
	) -> Promise,
	catch: (self: Ready<T>, onRejected: (reason: unknown) -> ...unknown) -> Promise,
	finally: (self: Ready<T>, callback: (status: PromiseStatus) -> ...unknown) -> Promise,
	timeout: (self: Ready<T>, seconds: number, rejectionValue: unknown?) -> Ready<T>,
	await: (self: Ready<T>) -> (boolean, unknown),
	expect: (self: Ready<T>) -> T,
	getStatus: (self: Ready<T>) -> PromiseStatus,
}

--[=[
	@interface Selection
	@within Client
	.State StateObject<V?> -- Fusion state for UI.
	.Get (self) -> V?
	.Observe (self, callback: (new: V?, old: V?) -> ()) -> () -> ()
	.Destroy (self) -> ()
]=]
export type Selection<V> = {
	State: Fusion.StateObject<V?>,
	Get: (self: Selection<V>) -> V?,
	Observe: (self: Selection<V>, callback: (new: V?, old: V?) -> ()) -> Disconnect,
	Destroy: (self: Selection<V>) -> (),
}

export type Client<Data> = {
	Ready: Ready<ReadOnly<Data>>,

	Get: (self: Client<Data>) -> ReadOnly<Data>?,
	GetAsync: (self: Client<Data>, timeout: number?) -> ReadOnly<Data>,
	Select: <V>(self: Client<Data>, selector: (data: ReadOnly<Data>) -> V) -> Selection<V>,
	IsReady: (self: Client<Data>) -> boolean,
	OnReady: (self: Client<Data>, callback: (data: ReadOnly<Data>) -> ()) -> Disconnect,
	Destroy: (self: Client<Data>) -> (),
}

return nil
