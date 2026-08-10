--!strict
--[[
	Thin LiveOps barrel: re-export Types + Config + Store + Messenger + Service.
	No OnStart / auto-subscribe / poll on require (call LiveOpsService.start explicitly).
]]

local Types = require(script.Types)
local Config = require(script.Config)
local Store = require(script.LiveOpsStore)
local Messenger = require(script.Messenger)
local Service = require(script.LiveOpsService)

return {
	Types = Types,
	Config = Config,
	Store = Store,
	Messenger = Messenger,
	Service = Service,
}
