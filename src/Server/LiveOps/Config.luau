--!strict
--[[
	LiveOps constants (server-only). No Roblox I/O service requires.

	Merge rule (deterministic): effectiveStat = liveOpsOverride ?? baseStat

	Scale target: ~20K CCU, ≥5000 concurrent servers.
	Propagation ≤ 2 minutes under normal conditions via MessagingService (primary;
	typically seconds). DataStore is truth for admin CAS + OnStart load only.

	MemoryStore is NOT used.
	At ≥5000 servers it would add another global budget, failure mode, and
	consistency edge case. Durable truth (DataStore) + one Publish fan-out
	(MessagingService) cover durability and cross-server apply — no fleet poll.

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
		Per-key DataStore Get throughput is ~100 RPS on a single key ("Current").

		Fleet-wide periodic GetAsync is GONE. Even a slow poll is still O(servers):
		e.g. 5000 servers / 50s ≈ 100 Get RPS forever; 5000 / 300s ≈ 16.7 RPS forever —
		still scales with fleet size and competes with OnStart + admin CAS.

		Steady-state DS reads ≈ OnStart only (server join churn), not 5000/interval.
		Example: if 50 servers start/min → ~0.83 Get RPS on "Current" amortized,
		well under ~100 RPS. START_LOAD_JITTER spreads boot spikes.

		≤2 min propagation = one admin Publish → MessagingService fan-out (primary).
		New servers load truth via OnStart GetAsync. Followers never write DS on apply.
	]]

	-- Uniform [0, MAX] wait before first OnStart GetAsync (desync boot storms).
	START_LOAD_JITTER_SECONDS_MAX = 30,

	--[[
		If MessagingService SubscribeAsync fails at start: one delayed one-shot
		GetAsync (not a fleet poll loop). Only scheduled when subscribe fails.
	]]
	SUBSCRIBE_FAIL_ONESHOT_RECONCILE_SECONDS = 45,

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
		DataStore on apply.
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
