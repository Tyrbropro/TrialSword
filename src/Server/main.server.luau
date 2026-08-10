--!strict
--[[
	Bootstrap only: start LiveOps once + Studio LiveOpsBridge seam.
	Command Bar: use script.LiveOpsBridge Bindables after Rojo Source sync;
	re-require of LiveOpsService is unsafe (fresh module state).
]]

local LiveOpsService = require(script.Parent.LiveOps.LiveOpsService)
local ItemService = require(script.Parent.ItemService)
local Admin = require(script.Parent.Admin)

local function installLiveOpsBridge(): ()
	local existing = script:FindFirstChild("LiveOpsBridge")
	if existing ~= nil then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = "LiveOpsBridge"

	local getLocalVersion = Instance.new("BindableFunction")
	getLocalVersion.Name = "GetLocalVersion"
	getLocalVersion.OnInvoke = function(): number
		-- Closure over original require — never re-require here.
		return LiveOpsService.getLocalVersion()
	end
	getLocalVersion.Parent = folder

	local getEffectiveSwordDamage = Instance.new("BindableFunction")
	getEffectiveSwordDamage.Name = "GetEffectiveSwordDamage"
	getEffectiveSwordDamage.OnInvoke = function(): number
		local stats = ItemService.getEffectiveStats("Sword")
		if stats == nil then
			return 0
		end
		return stats.Damage
	end
	getEffectiveSwordDamage.Parent = folder

	local requestPatch = Instance.new("BindableFunction")
	requestPatch.Name = "RequestPatch"
	requestPatch.OnInvoke = function(userId: number, damage: number): string
		local result = Admin.requestPatch(userId, {
			Sword = { Damage = damage },
		})
		if result.ok then
			return "ok"
		end
		return result.error
	end
	requestPatch.Parent = folder

	folder.Parent = script
end

installLiveOpsBridge()

task.spawn(function()
	task.wait(1)
	local startResult = LiveOpsService.start()
	if not startResult.ok then
		warn(`[LiveOps] start failed: {startResult.error}`)
	end
end)
