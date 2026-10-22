--!strict
--[=[
	@class Types
	@private

	Public types shared by `Server`, `Client`, and the package entrypoint.
]=]

local Fusion = require(script.Parent.Parent.Fusion)
local Migrations = require(script.Parent.Migrations)
local Path = require(script.Parent.Path)
local Shared = require(script.Parent.Shared)
local Signal = require(script.Parent.Parent.Signal)

export type Table = Shared.Table
export type Path<Data, V> = Path.Path<Data, V>
export type AnyPath<Data> = Path.AnyPath<Data>
export type Write<Data> = Path.Write<Data>
export type ReadOnly<T> = Path.ReadOnly<T>

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
	path: Path<Data, number> | Path<Data, string>,
	name: string,
	type: LeaderstatType,
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
	privatePaths: { AnyPath<Data> }?,
	validate: ((data: Data) -> (boolean, string?))?,
}

export type MessageHandler = (player: Player, message: Table, processed: () -> ()) -> ()

export type Server<Data> = {
	IsMock: boolean,
	ProfileLoaded: Signal.Signal<Player, Profile<Data>>,
	ProfileReleased: Signal.Signal<Player>,
	FirstJoin: Signal.Signal<Player, Data>,
	DataUpdated: Signal.Signal<Player, string, unknown>,
	PreSave: Signal.Signal<Player, Data>,
	PostSave: Signal.Signal<Player, Data>,
	LastSave: Signal.Signal<Player, LastSaveReason>,
	Migrated: Signal.Signal<Player, Migrations.Report>,
	ProfileLoadFailed: Signal.Signal<Player, string>,
	RolledBack: Signal.Signal<RollbackResult>,

	GetProfile: (self: Server<Data>, player: Player) -> Profile<Data>?,
	GetProfileAsync: (self: Server<Data>, player: Player, timeout: number?) -> Profile<Data>?,
	GetData: (self: Server<Data>, player: Player) -> ReadOnly<Data>?,
	GetDataAsync: (self: Server<Data>, player: Player, timeout: number?) -> ReadOnly<Data>?,
	GetKey: (self: Server<Data>, target: Target) -> string,
	GetStore: (self: Server<Data>) -> ProfileStore<Data>,
	IsReady: (self: Server<Data>, player: Player) -> boolean,

	ReadData: <V>(self: Server<Data>, player: Player, path: Path<Data, V>) -> ReadOnly<V>?,
	UpdateData: <V>(self: Server<Data>, player: Player, path: Path<Data, V>, value: V) -> boolean,
	InsertData: <V>(self: Server<Data>, player: Player, path: Path<Data, { V }>, value: V) -> boolean,
	IncrementData: (self: Server<Data>, player: Player, path: Path<Data, number>, delta: number?) -> boolean,
	DecrementData: (self: Server<Data>, player: Player, path: Path<Data, number>, delta: number?) -> boolean,
	RemoveData: (self: Server<Data>, player: Player, path: AnyPath<Data>) -> boolean,
	UpdateArrayItem: <V>(
		self: Server<Data>,
		player: Player,
		path: Path<Data, { V }>,
		index: number,
		value: V
	) -> boolean,
	RemoveArrayItem: <V>(self: Server<Data>, player: Player, path: Path<Data, { V }>, index: number) -> boolean,
	BatchSetValues: (self: Server<Data>, player: Player, writes: { Write<Data> }) -> number,
	Transaction: (self: Server<Data>, transform: () -> ...boolean) -> boolean,
	Mutate: (self: Server<Data>, player: Player, transform: (draft: Data) -> ...boolean) -> boolean,
	MutateMany: (
		self: Server<Data>,
		players: { Player },
		transform: (drafts: { [Player]: Data }) -> ...boolean
	) -> boolean,

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
	@interface Watcher
	@within Client
	.Value StateObject<ReadOnly<V>?> -- Reactive value at the watched path.
	.get () -> ReadOnly<V>? -- Current value.
	.onChange (self, listener: (newValue: ReadOnly<V>?, oldValue: ReadOnly<V>?) -> ()) -> Connection
	.Destroy (self) -> ()
]=]
export type Watcher<V> = {
	Value: Fusion.StateObject<ReadOnly<V>?>,
	get: () -> ReadOnly<V>?,
	onChange: (
		self: Watcher<V>,
		listener: (newValue: ReadOnly<V>?, oldValue: ReadOnly<V>?) -> ()
	) -> Signal.Connection,
	Destroy: (self: Watcher<V>) -> (),
}

export type Client<Data> = {
	Ready: Ready<ReadOnly<Data>>,
	Updated: Signal.Signal<{ string }, unknown>,

	GetData: (self: Client<Data>) -> ReadOnly<Data>?,
	GetDataState: (self: Client<Data>) -> Fusion.StateObject<ReadOnly<Data>?>,
	GetDataAsync: (self: Client<Data>, timeout: number?) -> ReadOnly<Data>,
	Read: <V>(self: Client<Data>, path: Path<Data, V>) -> ReadOnly<V>?,
	IsReady: (self: Client<Data>) -> boolean,
	OnReady: (self: Client<Data>, callback: (data: ReadOnly<Data>) -> ()) -> Disconnect,
	WatchPath: <V>(self: Client<Data>, path: Path<Data, V>) -> Watcher<V>,
	OnChanged: <V>(
		self: Client<Data>,
		path: Path<Data, V>,
		callback: (newValue: ReadOnly<V>?, oldValue: ReadOnly<V>?) -> ()
	) -> Disconnect,
	Destroy: (self: Client<Data>) -> (),
}

return nil
