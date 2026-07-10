--!strict
--[=[
	@class EZProfileStore

	Lazy package entrypoint for `Server`, `Client`, and `Migrations`.
]=]

local loaded: { [string]: any } = {}
local EZProfileStore = {}

local function loadModule(name: string): any
	local cached = loaded[name]
	if cached ~= nil then
		return cached
	end

	local child = script:FindFirstChild(name)
	if not child or not child:IsA("ModuleScript") then
		error(`EZProfileStore: missing module "{name}"`, 3)
	end

	local module = require(child)
	loaded[name] = module
	rawset(EZProfileStore, name, module)
	return module
end

return setmetatable(EZProfileStore, {
	__index = function(_, key: any)
		if key == "Server" or key == "Client" or key == "Migrations" then
			return loadModule(key :: string)
		end
		return nil
	end,
})
