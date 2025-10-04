-- Lightweight logger for debugging

local RunService = game:GetService("RunService")
local tag = RunService:IsServer() and "Server" or "Client"

local function timestamp()
	local dt = DateTime.now()
	return dt:ToIsoDate()
		.. string.format(
			" %02d:%02d:%02d",
			dt:ToUniversalTime().Hour,
			dt:ToUniversalTime().Minute,
			dt:ToUniversalTime().Second
		)
end

local DebugPrint = {}

local function log(level, msg, ...)
	local ok, text = pcall(string.format, tostring(msg), ...)
	if not ok then
		text = msg
	end
	print(string.format("[%s] [%s] %s", timestamp(), level, text))
end

function DebugPrint.info(msg, ...)
	log(tag .. "/INFO", msg, ...)
end
function DebugPrint.warn(msg, ...)
	warn(string.format("[%s] [%s/WARN] %s", timestamp(), tag, string.format(msg, ...)))
end
function DebugPrint.err(msg, ...)
	warn(string.format("[%s] [%s/ERROR] %s", timestamp(), tag, string.format(msg, ...)))
end
function DebugPrint.debug(msg, ...)
	log(tag .. "/DEBUG", msg, ...)
end

-- showhand call
setmetatable(DebugPrint, {
	__call = function(_, level, msg, ...)
		level = string.upper(level)
		if DebugPrint[level:lower()] then
			DebugPrint[level:lower()](msg, ...)
		else
			log(tag .. "/" .. level, msg, ...)
		end
	end,
})

return DebugPrint
