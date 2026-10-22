local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local PackageAlias = ReplicatedStorage.Packages.EZProfileStore

local function withServerPackagesHidden(callback)
	local serverPackages = ServerScriptService:FindFirstChild("ServerPackages")
	local originalParent = if serverPackages then serverPackages.Parent else nil

	if serverPackages then
		serverPackages.Parent = nil
	end

	local ok, result = pcall(callback)

	if serverPackages then
		serverPackages.Parent = originalParent
	end

	if not ok then
		error(result, 2)
	end

	return result
end

return function()
	describe("Wally package entrypoint", function()
		it("loads Client without server packages being mounted", function()
			withServerPackagesHidden(function()
				local ok, clientModule = pcall(function()
					local EZProfileStore = require(PackageAlias)
					return EZProfileStore.Client
				end)

				expect(ok).to.equal(true)
				expect(typeof(clientModule.new)).to.equal("function")
			end)
		end)

		it("loads Server through the Wally ServerPackages mount", function()
			local EZProfileStore = require(PackageAlias)
			local serverModule = EZProfileStore.Server

			expect(typeof(serverModule.new)).to.equal("function")
		end)
	end)
end
