local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local TestEZ = require(ReplicatedStorage.DevPackages.TestEZ)

local results = TestEZ.TestBootstrap:run({ ServerScriptService.Tests })

if results.failureCount > 0 then
	error(`EZProfileStore tests failed: {results.failureCount} failure(s)`)
end
