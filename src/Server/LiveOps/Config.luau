--!strict
--[[
	LiveOps constants (server-only). No Roblox I/O service requires.

	Merge rule (deterministic): effectiveStat = liveOpsOverride ?? baseStat

	Scale target: ~20K CCU, ≥5000 concurrent servers.
	Propagation ≤ 2 minutes under normal conditions via MessagingService (primary).
	DataStore poll is a rare backup reconcile only — not the fast path.

	MemoryStore is NOT used.
	At ≥5000 servers it would add another global budget, failure mode, and
	consistency edge case. Durable truth (DataStore) + one Publish fan-out
	(MessagingService) + slow jittered poll already cover durability and reconcile.

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
		Per-key DataStore throughput (~100 Get RPS on a single key) is the hard
		limit. Old design: 5000 servers × (1/50s) ≈ 100 Get RPS amortized on
		"Current" — saturates the key even before aligned spikes.

		New design (MS primary, DS rare backup):
		- POLL_INTERVAL_SECONDS in [180, 300]; default 240s
		  5000 / 240 ≈ 20.8 Get RPS amortized; 5000 / 300 ≈ 16.7 Get RPS
		- Plus POLL_JITTER and MS-recent-apply skip cut actual Gets further
		- START_LOAD_JITTER spreads OnStart Gets so 5K servers do not align

		Tradeoff: DS-only convergence can take several minutes if MS is missed;
		normal patches still propagate in ≤ ~2 minutes via MessagingService.
	]]
	POLL_INTERVAL_SECONDS = 240,

	-- Extra uniform [0, MAX] seconds added each poll cycle (desync servers).
	POLL_JITTER_SECONDS_MAX = 60,

	-- Uniform [0, MAX] wait before first OnStart GetAsync (desync boot storms).
	START_LOAD_JITTER_SECONDS_MAX = 30,

	-- Skip poll GetAsync if MessagingService applied a patch within this window.
	MS_APPLY_SKIP_POLL_SECONDS = 120,

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
		DataStore on apply; they apply locally then rely on rare poll if MS missed.
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
