--!strict
--[[
	Thin LiveOps barrel. No OnStart / auto-subscribe on require.
]]

local Types = require(script.Types)
local Config = require(script.Config)
local Store = require(script.LiveOpsStore)
local Cache = require(script.LiveOpsCache)
local Messenger = require(script.Messenger)
local Service = require(script.LiveOpsService)

return {
	Types = Types,
	Config = Config,
	Store = Store,
	Cache = Cache,
	Messenger = Messenger,
	Service = Service,
}
