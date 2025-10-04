--[[
	Custom Import Module
		A simple import utility to dynamically locate and require modules based on directory paths and runtime context
	To-Do:
		Add case-insenitivity
--]]

local RunService = game:GetService("RunService")

local Directory = {
	Packages = {},

	Server = {
		services = {},
		modules = {},
	},
	Client = {
		Controllers = {},
		Modules = {},
	},
	Shared = {},
}

--	Sets alias references for Directory
local function setAliases(modules, aliasType)
	local isShared = aliasType == "Shared" or aliasType == "Packages"

	if isShared then
		Directory[aliasType] = modules
	elseif RunService:IsServer() then
		Directory.Server[aliasType] = modules
	elseif RunService:IsClient() then
		Directory.Client[aliasType] = modules
	end
end

--Traverses the Directory structure using a path like "shared/utils/dprint" and returns the located instance or table
local function solveDirectory(path: string)
	local segments = string.split(path, "/")
	local currentDir = Directory
	local initialized = false

	for _, name in ipairs(segments) do
		if not initialized then
			currentDir = currentDir[name]
			initialized = true
		else
			if typeof(currentDir) == "table" then
				-- Try direct index first
				if currentDir[name] then
					currentDir = currentDir[name]
					continue
				end

				-- Otherwise, search through nested tables or instances
				for _, value in pairs(currentDir) do
					if typeof(value) == "table" then
						for _, subValue in pairs(value) do
							if subValue.Name == name then
								currentDir = subValue
								break
							end
						end
					elseif typeof(value) == "Instance" and value.Name == name then
						currentDir = value
						break
					end
				end
			end
		end
	end

	return currentDir
end

--[[
	Main import function

    import("shared/utils/dprint")
    import("alias:Shared", sharedModules)
--]]
return function(directory: string, modules: Instance?)
	-- Handle alias setting
	if modules and string.find(directory, "alias:") then
		local _, aliasType = unpack(string.split(directory, ":"))
		setAliases(modules, aliasType)
		return
	end

	-- Determine current execution context
	local context = (
		string.find(directory, "^Shared") and "Shared"
		or string.find(directory, "^Packages") and "Packages"
		or (RunService:IsServer() and "Server" or "Client")
	)

	if not Directory[context] then
		warn(`[import] Invalid context: {context}`)
		return
	end

	-- Resolve path based on context
	local fullPath = (context == "Shared" or context == "Packages") and directory or `{context}/{directory}`

	local moduleInstance = solveDirectory(fullPath)

	-- Attempt to require located module
	local success, result = pcall(require, moduleInstance)
	if success then
		return result
	else
		warn(`[import] Failed to require {directory}: {result}`)
	end
end
