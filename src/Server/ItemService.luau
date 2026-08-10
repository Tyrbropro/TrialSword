--!strict
--[[
	Base item definitions ⊕ in-memory LiveOps overlay.
	Merge: effectiveStat = liveOpsOverride ?? baseStat
	Never talks to DataStore / MessagingService / MemoryStore.
]]

local Types = require(script.Parent.LiveOps.Types)
local Config = require(script.Parent.LiveOps.Config)

type ItemId = Types.ItemId
type ItemStats = Types.ItemStats
type ItemStatsOverride = Types.ItemStatsOverride
type ItemDefinition = Types.ItemDefinition
type LiveOpsOverrides = Types.LiveOpsOverrides

local baseById: { [ItemId]: ItemDefinition } = {}
for _, def in Config.DEFAULT_ITEMS do
	baseById[def.Id] = {
		Id = def.Id,
		BaseStats = {
			Damage = def.BaseStats.Damage,
		},
	}
end

local overlays: LiveOpsOverrides = {}

local function mergeStats(base: ItemStats, override: ItemStatsOverride?): ItemStats
	if override == nil then
		return {
			Damage = base.Damage,
		}
	end
	-- effectiveStat = liveOpsOverride ?? baseStat
	local damage = override.Damage
	if damage == nil then
		damage = base.Damage
	end
	return {
		Damage = damage,
	}
end

local function shallowCopyOverrides(source: LiveOpsOverrides): LiveOpsOverrides
	local copy: LiveOpsOverrides = {}
	for itemId, override in source do
		copy[itemId] = {
			Damage = override.Damage,
		}
	end
	return copy
end

local ItemService = {}

function ItemService.getBaseDefinition(itemId: ItemId): ItemDefinition?
	local def = baseById[itemId]
	if def == nil then
		return nil
	end
	return {
		Id = def.Id,
		BaseStats = {
			Damage = def.BaseStats.Damage,
		},
	}
end

function ItemService.getBaseStats(itemId: ItemId): ItemStats?
	local def = baseById[itemId]
	if def == nil then
		return nil
	end
	return {
		Damage = def.BaseStats.Damage,
	}
end

function ItemService.getOverride(itemId: ItemId): ItemStatsOverride?
	local override = overlays[itemId]
	if override == nil then
		return nil
	end
	return {
		Damage = override.Damage,
	}
end

function ItemService.getEffectiveStats(itemId: ItemId): ItemStats?
	local def = baseById[itemId]
	if def == nil then
		return nil
	end
	return mergeStats(def.BaseStats, overlays[itemId])
end

function ItemService.setOverrides(overrides: LiveOpsOverrides): ()
	overlays = shallowCopyOverrides(overrides)
end

function ItemService.clearOverrides(): ()
	overlays = {}
end

function ItemService.getLocalOverlaySnapshot(): LiveOpsOverrides
	return shallowCopyOverrides(overlays)
end

return ItemService
