--!strict
--[[
	LiveOps constants (server-only). No Roblox I/O service requires.

	Merge rule (deterministic): effectiveStat = liveOpsOverride ?? baseStat

	Scale target: ~20K CCU, ≥5000 concurrent servers.
	Propagation ≤ 2 minutes under normal conditions via tiny MessagingService
	signal (typically seconds) + MemoryStore snapshot read.

	Studio Command Bar: prefer ServerScriptService.main.LiveOpsBridge Bindables
	after Rojo Source sync; re-require of LiveOpsService is unsafe (fresh state).
]]

local Types = require(script.Parent.Types)

type ItemDefinition = Types.ItemDefinition

local Config = {
	-- ONE DataStore name + ONE key — durable truth; admin CAS writes only.
	DATASTORE_NAME = "LiveOpsItemStats",
	DATASTORE_KEY = "Current",

	--[[
		MemoryStore: ONE hash map + ONE key holding the latest LiveOpsDocument.
		Not per-player. Fast shared read so OnStart / MS handlers do not hammer
		DataStore per-key (~100 Get RPS on "Current").

		Budget: mass restart of 5000 servers reading MemoryStore (separate budget)
		avoids 5000 simultaneous GetAsync("Current"). DS fallback is rare
		(cache miss / cold) — not the primary boot path.
		Example: if 5% of 5000 boots miss cache → ~250 DS Gets once, not 5000.
	]]
	MEMORYSTORE_MAP_NAME = "LiveOpsItemStats",
	MEMORYSTORE_KEY = "Current",
	-- Refresh TTL on each admin Set; keeps latest snapshot available between patches.
	MEMORYSTORE_TTL_SECONDS = 604800, -- 7 days

	-- ONE MessagingService topic — tiny version signals only.
	MESSAGING_TOPIC = "LiveOpsItemStats",

	SCHEMA_VERSION = 1,

	--[[
		MS soft cap ≪ 1KiB. Wire payload is LiveOpsSignal only, e.g.
		{"SchemaVersion":1,"Version":12} ≈ 40 bytes — never full Overrides.
		One admin Publish fans out to ≥5000 servers (one Publish, not N).
	]]
	MS_PAYLOAD_SOFT_CAP_BYTES = 800,

	-- Optional small boot jitter (desync); PRIMARY read is MemoryStore, not DS.
	START_LOAD_JITTER_SECONDS_MAX = 5,

	-- SubscribeAsync retry: exponential backoff 1 → 2 → 4 … capped at 60s.
	SUBSCRIBE_RETRY_INITIAL_SECONDS = 1,
	SUBSCRIBE_RETRY_MAX_SECONDS = 60,

	-- Server-only allowlist; P5 Admin auth reads this (not client-replicated).
	ADMIN_USER_IDS = { 3057479633 } :: { number },

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
