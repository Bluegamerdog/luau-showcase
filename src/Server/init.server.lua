local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local import = require(ReplicatedStorage.Shared.import)(script)
import("alias:Server", script.Services:GetChildren())

import("alias:Shared", ReplicatedStorage.Shared:GetChildren())
import("alias:Utils", ReplicatedStorage.Shared.Utils:GetChildren())
import("alias:Packages", ReplicatedStorage.Packages:GetChildren())

local bootstrap = require(ReplicatedStorage.Shared.bootstrap)
bootstrap({
	context = "Server",
	units = script.Services,
})
