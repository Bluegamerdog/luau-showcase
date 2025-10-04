--[[
	Shared bootstrap for initializing and starting Services (server) or Controllers (client).

	ToDo:
	- Add dependency order (e.g. init before dependent units)
	- Add retry or timeout for failed init/start
	- Add event hooks (BeforeInit, AfterStart)
	- Integrate better logging
	- Allow autorun scripts
--]]

----------------------------------
--		DEPENDENCIES
----------------------------------
local RunService = game:GetService("RunService")

----------------------------------
--		BOOTSTRAP LOGIC
----------------------------------

local function bootstrap(config)
	config = config or {}

	local isServer = RunService:IsServer()
	local tag = config.context or (isServer and "Server" or "Client")
	local unitsFolder = config.units

	assert(unitsFolder, "[bootstrap] Missing `units` folder in config.")
	assert(unitsFolder:IsA("Folder"), "[bootstrap] Config.units must be a Folder.")

	warn(string.format("[%s] Initializing modules...", tag))

	for _, module in ipairs(unitsFolder:GetChildren()) do
		if module:IsA("ModuleScript") then
			local success, result = pcall(function()
				local loadedModule = require(module)
				if typeof(loadedModule) == "table" and typeof(loadedModule.Init) == "function" then
					loadedModule:Init()
				end
			end)
			if not success then
				warn(string.format("[%s] Init failed for %s: %s", tag, module.Name, result))
			end
		end
	end

	warn(string.format("[%s] Starting modules...", tag))

	for _, module in ipairs(unitsFolder:GetChildren()) do
		if module:IsA("ModuleScript") then
			local success, result = pcall(function()
				local loadedModule = require(module)
				if typeof(loadedModule) == "table" and typeof(loadedModule.Start) == "function" then
					loadedModule:Start()
				end
			end)
			if not success then
				warn(string.format("[%s] Start failed for %s: %s", tag, module.Name, result))
			end
		end
	end

	if isServer then
		workspace:SetAttribute("ServerLoadingComplete", true)
	else
		workspace:SetAttribute("ClientLoadingComplete", true)
	end

	warn(string.format("[%s] Bootstrap complete.", tag))
end

return bootstrap
