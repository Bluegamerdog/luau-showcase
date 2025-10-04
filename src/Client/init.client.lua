local ReplicatedStorage = game:GetService("ReplicatedStorage")

local import = require(ReplicatedStorage.Shared.import)(script)
import("set:Client", script.Controllers:GetChildren())

if not workspace:GetAttribute("ServerLoadingComplete") then
	workspace:GetAttributeChangedSignal("ServerLoadingComplete"):Wait()
end

local bootstrap = require(ReplicatedStorage.Shared.bootstrap)
bootstrap({
	context = "Client",
	units = script.Controllers
})
