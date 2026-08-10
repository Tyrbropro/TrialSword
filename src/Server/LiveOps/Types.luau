--!strict
--[[
	LiveOps type exports only. No runtime logic, no DataStore/MessagingService/MemoryStore.
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
	Full document for DataStore + MemoryStore (latest snapshot).
	SchemaVersion = wire/schema; Version = monotonic content integer.
]]
export type LiveOpsDocument = {
	SchemaVersion: number,
	Version: number,
	Overrides: LiveOpsOverrides,
}

export type ApplyResult = "Applied" | "RejectedStale" | "RejectedInvalid"

--[[
	Tiny MessagingService fan-out signal only (≪ 1KiB).
	Full Overrides never go on the MS wire — followers load from MemoryStore (or DS fallback).
]]
export type LiveOpsSignal = {
	SchemaVersion: number,
	Version: number,
}

export type MessengerPayload = LiveOpsSignal

return {}
