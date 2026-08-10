--!strict
--[[
	LiveOps type exports only. No runtime logic, no DataStore/MessagingService.
]]

export type ItemId = string -- known ids include "Sword"

export type ItemStats = {
	Damage: number,
}

-- Partial overlay: nil fields mean "no override" (keep base).
export type ItemStatsOverride = {
	Damage: number?,
}

export type ItemDefinition = {
	Id: ItemId,
	BaseStats: ItemStats,
}

export type LiveOpsOverrides = { [ItemId]: ItemStatsOverride }

--[[
	Single-key DataStore document (source of truth).
	SchemaVersion = wire/schema; Version = monotonic content integer.
	Keep payload-small for MS fan-out (≪ 1KiB).
]]
export type LiveOpsDocument = {
	SchemaVersion: number,
	Version: number,
	Overrides: LiveOpsOverrides,
}

export type ApplyResult = "Applied" | "RejectedStale" | "RejectedInvalid"

-- Same shape as the DS document for one-topic MessagingService fan-out.
export type MessengerPayload = LiveOpsDocument

return {}
