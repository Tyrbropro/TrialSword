--!strict
--[[
	Admin — server-only auth + rate limit + patch via LiveOpsService.pushOverrides.
	Never writes DataStore or publishes directly. Allowlist stays server-only.
]]

local Types = require(script.Parent.LiveOps.Types)
local Config = require(script.Parent.LiveOps.Config)
local LiveOpsService = require(script.Parent.LiveOps.LiveOpsService)

type LiveOpsDocument = Types.LiveOpsDocument
type LiveOpsOverrides = Types.LiveOpsOverrides
type ItemStatsOverride = Types.ItemStatsOverride

export type AdminResult = { ok: true, value: LiveOpsDocument } | { ok: false, error: string }

local ALLOWED_OVERRIDE_KEYS: { [string]: boolean } = {
	Damage = true,
}

-- Last *accepted* patch time (os.clock) per userId.
local lastAcceptedAt: { [number]: number } = {}

local function isFiniteNumber(value: unknown): boolean
	return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function validateOverride(override: unknown): boolean
	if typeof(override) ~= "table" then
		return false
	end
	local asTable = override :: { [any]: any }
	for key, value in asTable do
		if typeof(key) ~= "string" or ALLOWED_OVERRIDE_KEYS[key] ~= true then
			return false
		end
		if key == "Damage" and value ~= nil and not isFiniteNumber(value) then
			return false
		end
	end
	return true
end

local function validateOverrides(overrides: unknown): LiveOpsOverrides?
	if typeof(overrides) ~= "table" then
		return nil
	end
	local cleaned: LiveOpsOverrides = {}
	for itemId, override in overrides :: { [any]: any } do
		if typeof(itemId) ~= "string" then
			return nil
		end
		if not validateOverride(override) then
			return nil
		end
		local typed = override :: ItemStatsOverride
		cleaned[itemId] = {
			Damage = typed.Damage,
		}
	end
	return cleaned
end

local function buildAllowlistSet(): { [number]: boolean }
	local set: { [number]: boolean } = {}
	for _, userId in Config.ADMIN_USER_IDS do
		set[userId] = true
	end
	return set
end

local allowlistSet = buildAllowlistSet()

local Admin = {}

function Admin.isAuthorized(userId: number): boolean
	return allowlistSet[userId] == true
end

function Admin.getCooldownRemaining(userId: number): number
	local last = lastAcceptedAt[userId]
	if last == nil then
		return 0
	end
	local elapsed = os.clock() - last
	local remaining = Config.ADMIN_PATCH_COOLDOWN_SECONDS - elapsed
	if remaining <= 0 then
		return 0
	end
	return remaining
end

function Admin.requestPatch(userId: number, overrides: LiveOpsOverrides): AdminResult
	if not Admin.isAuthorized(userId) then
		warn("[Admin] unauthorized")
		return { ok = false, error = "unauthorized" }
	end

	local remaining = Admin.getCooldownRemaining(userId)
	if remaining > 0 then
		warn("[Admin] rate_limited")
		return { ok = false, error = "rate_limited" }
	end

	local cleaned = validateOverrides(overrides)
	if cleaned == nil then
		return { ok = false, error = "invalid_overrides" }
	end

	-- Only write/publish path: LiveOpsService (CAS → publish → local apply).
	local result = LiveOpsService.pushOverrides(cleaned)
	if not result.ok then
		warn(`[Admin] patch failed: {result.error}`)
		return { ok = false, error = result.error }
	end

	lastAcceptedAt[userId] = os.clock()
	print(`[Admin] patch ok v{result.value.Version}`)
	return { ok = true, value = result.value }
end

return Admin
