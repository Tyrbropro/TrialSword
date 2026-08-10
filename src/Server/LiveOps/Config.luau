--!strict
--[[
	LiveOps constants (server-only). No Roblox I/O service requires.

	Merge rule (deterministic): effectiveStat = liveOpsOverride ?? baseStat

	Scale target: ~20K CCU, ≥5000 concurrent servers.
	Propagation: ≤ 2 minutes (MessagingService primary; poll safety net).

	MemoryStore is NOT used.
	At ≥5000 servers it would add another global budget, failure mode, and
	consistency edge case. Durable truth (DataStore) + one Publish fan-out
	(MessagingService) + slow poll already cover durability and reconcile.

	Studio Command Bar: prefer ServerScriptService.main.LiveOpsBridge Bindables
	after Rojo Source sync; re-require of LiveOpsService is unsafe (fresh state).
]]

local Types = require(script.Parent.Types)

type ItemDefinition = Types.ItemDefinition

local Config = {
	-- ONE DataStore name + ONE key for the versioned LiveOps document.
	DATASTORE_NAME = "LiveOpsItemStats",
	DATASTORE_KEY = "Current",

	-- ONE MessagingService topic for item-stat patch fan-out.
	MESSAGING_TOPIC = "LiveOpsItemStats",

	SCHEMA_VERSION = 1,

	--[[
		Poll interval MUST stay in [45, 60] s.
		Worst-case DS GetAsync load at 5000 servers × (1 / 45s) ≈ 111 RPS amortized
		if every server polls independently; at 60s ≈ 83 RPS. That stays within
		typical experience DataStore read budgets when readers only poll (no
		per-player DS, no confirm writes). Prefer 50s as mid-band.
	]]
	POLL_INTERVAL_SECONDS = 50,

	--[[
		MS payloads MUST be ≪ 1KiB. Soft cap 800 bytes leaves headroom under the
		1KiB practical limit and rejects oversized publishes before send.
		One document for all item overrides (not per-player / per-sword / per-tick).
	]]
	MS_PAYLOAD_SOFT_CAP_BYTES = 800,

	--[[
		One admin Publish after successful CAS fans out to all subscribed servers
		in one MessagingService delivery wave. At ≥5000 servers that is still one
		Publish call from the originator (not N publishes). Followers do not write
		DataStore on apply; they apply locally then rely on poll if MS was missed.
	]]

	-- Server-only allowlist; P5 Admin auth reads this (not client-replicated).
	ADMIN_USER_IDS = { 3057479633 } :: { number },

	-- Placeholder for P5 rate limit (seconds between accepted patches per admin).
	ADMIN_PATCH_COOLDOWN_SECONDS = 5,

	-- Base item defs. Sword Damage = 100 (stat/data only; combat out of scope).
	DEFAULT_ITEMS = {
		{
			Id = "Sword",
			BaseStats = {
				Damage = 100,
			},
		},
	} :: { ItemDefinition },
}

return Config
