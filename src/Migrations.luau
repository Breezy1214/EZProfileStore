--!strict
--[=[
	@class Migrations
	@server

	Ordered, transactional profile schema migrations.
]=]

local Shared = require(script.Parent.Shared)

export type ContextInput = {
	key: string?,
	userId: number?,
}
export type Context = {
	key: string?,
	userId: number?,
	version: number,
	name: string,
	direction: "up" | "down",
}
export type MigrationFunction = (data: { [any]: any }, context: Context) -> { [any]: any }?
export type Definition = {
	name: string?,
	up: MigrationFunction,
	down: MigrationFunction?,
}
export type Input = MigrationFunction | Definition
export type AppliedMigration = {
	name: string,
	version: number,
	direction: "up" | "down",
}
export type Report = {
	fromVersion: number,
	toVersion: number,
	applied: { AppliedMigration },
}

type ResolvedDefinition = {
	name: string,
	version: number,
	up: MigrationFunction,
	down: MigrationFunction?,
}

export type Migrations = typeof(setmetatable(
	{} :: {
		_definitions: { ResolvedDefinition },
	},
	{} :: { __index: any }
))

local Migrations = {}
Migrations.__index = Migrations

local function replaceTable(target: { [any]: any }, source: { [any]: any })
	table.clear(target)
	for key, value in source do
		target[key] = value
	end
end

local function assertVersion(value: number, name: string)
	assert(value >= 0 and value % 1 == 0, `{name} must be a non-negative integer`)
end

local function resolveDefinition(input: Input, version: number): ResolvedDefinition
	if typeof(input) == "function" then
		return {
			name = `migration-{version}`,
			version = version,
			up = input,
		}
	end

	assert(typeof(input) == "table", `migration {version} must be a function or definition table`)
	assert(typeof(input.up) == "function", `migration {version}.up must be a function`)
	assert(input.down == nil or typeof(input.down) == "function", `migration {version}.down must be a function`)
	assert(
		input.name == nil or (typeof(input.name) == "string" and #input.name > 0),
		`migration {version}.name must be non-empty`
	)

	return {
		name = input.name or `migration-{version}`,
		version = version,
		up = input.up,
		down = input.down,
	}
end

local function migrationContext(base: ContextInput?, definition: ResolvedDefinition, direction: "up" | "down"): Context
	return {
		key = if base then base.key else nil,
		userId = if base then base.userId else nil,
		version = definition.version,
		name = definition.name,
		direction = direction,
	}
end

local function runMigration(
	data: { [any]: any },
	definition: ResolvedDefinition,
	direction: "up" | "down",
	context: ContextInput?
)
	local migrate = if direction == "up" then definition.up else definition.down
	assert(migrate ~= nil, `migration {definition.version} ("{definition.name}") has no down function`)

	local ok, replacement = pcall(migrate, data, migrationContext(context, definition, direction))
	if not ok then
		error(
			`migration {definition.version} ("{definition.name}") failed while migrating {direction}: {replacement}`,
			0
		)
	end

	if replacement ~= nil and replacement ~= data then
		assert(typeof(replacement) == "table", `migration {definition.version} returned a non-table value`)
		replaceTable(data, replacement)
	end
end

local function runTransaction(
	self: Migrations,
	data: { [any]: any },
	firstVersion: number,
	lastVersion: number,
	step: number,
	direction: "up" | "down",
	context: ContextInput?
): { AppliedMigration }
	local snapshot = Shared.deepCopy(data)
	local applied: { AppliedMigration } = {}
	local ok, failure = pcall(function()
		for version = firstVersion, lastVersion, step do
			local definition = self._definitions[version]
			runMigration(data, definition, direction, context)
			table.insert(applied, {
				name = definition.name,
				version = version,
				direction = direction,
			})
		end
	end)

	if not ok then
		replaceTable(data, snapshot)
		error(failure, 3)
	end
	return applied
end

--[=[
	Creates an ordered migration set.
	@within Migrations
	@param definitions { Input }?
	@return Migrations
]=]
function Migrations.new(definitions: { Input }?): Migrations
	local self = setmetatable({
		_definitions = {},
	}, Migrations) :: any

	local initial: { Input } = definitions or ({} :: { Input })
	for _, definition in initial do
		self:Add(definition)
	end

	return self
end

--[=[
	Appends a migration.
	@within Migrations
	@method Add
	@param definition Input | string
	@param up MigrationFunction?
	@param down MigrationFunction?
	@return Migrations
]=]
function Migrations.Add(
	self: Migrations,
	definition: Input | string,
	up: MigrationFunction?,
	down: MigrationFunction?
): Migrations
	local version = #self._definitions + 1
	local input: Input
	if typeof(definition) == "string" then
		assert(typeof(up) == "function", "Migrations:Add(name, up) requires an up function")
		input = {
			name = definition,
			up = up,
			down = down,
		}
	else
		assert(up == nil and down == nil, "up/down arguments are only valid with a migration name")
		input = definition
	end

	table.insert(self._definitions, resolveDefinition(input, version))
	return self
end

--[=[
	Returns the latest schema version.
	@within Migrations
	@method GetLatestVersion
	@return number
]=]
function Migrations.GetLatestVersion(self: Migrations): number
	return #self._definitions
end

--[=[
	Runs migrations after `fromVersion`; restores `data` on failure.
	@within Migrations
	@method Migrate
	@param data { [any]: any }
	@param fromVersion number?
	@param context ContextInput?
	@return Report
]=]
function Migrations.Migrate(
	self: Migrations,
	data: { [any]: any },
	fromVersion: number?,
	context: ContextInput?
): Report
	assert(typeof(data) == "table", "Migrations:Migrate data must be a table")
	local current = fromVersion or 0
	local latestVersion = self:GetLatestVersion()
	assertVersion(current, "fromVersion")
	assert(
		current <= latestVersion,
		`profile schema version {current} is newer than this server's latest migration ({latestVersion})`
	)
	if current == latestVersion then
		return {
			fromVersion = current,
			toVersion = latestVersion,
			applied = {},
		}
	end

	return {
		fromVersion = current,
		toVersion = latestVersion,
		applied = runTransaction(self, data, current + 1, latestVersion, 1, "up", context),
	}
end

--[=[
	Runs `down` migrations to `targetVersion`; restores `data` on failure.
	@within Migrations
	@method Rollback
	@param data { [any]: any }
	@param fromVersion number
	@param targetVersion number?
	@param context ContextInput?
	@return Report
]=]
function Migrations.Rollback(
	self: Migrations,
	data: { [any]: any },
	fromVersion: number,
	targetVersion: number?,
	context: ContextInput?
): Report
	assert(typeof(data) == "table", "Migrations:Rollback data must be a table")
	local target = targetVersion or math.max(0, fromVersion - 1)
	assertVersion(fromVersion, "fromVersion")
	assertVersion(target, "targetVersion")
	assert(fromVersion <= self:GetLatestVersion(), "fromVersion exceeds the latest migration")
	assert(target <= fromVersion, "targetVersion must not exceed fromVersion")
	if target == fromVersion then
		return {
			fromVersion = fromVersion,
			toVersion = target,
			applied = {},
		}
	end

	for version = fromVersion, target + 1, -1 do
		local definition = self._definitions[version]
		assert(definition.down ~= nil, `migration {version} ("{definition.name}") has no down function`)
	end

	return {
		fromVersion = fromVersion,
		toVersion = target,
		applied = runTransaction(self, data, fromVersion, target + 1, -1, "down", context),
	}
end

return Migrations
