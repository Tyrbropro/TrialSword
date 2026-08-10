--!strict
--[[
	LiveOpsService — OnStart load + MS subscribe; single apply path.
	Followers never write DataStore on apply. Truth then announce via pushOverrides.
	No fleet-wide DS poll (per-key scale). MS is primary fan-out; DS = OnStart + admin CAS.
]]

local Types = require(script.Parent.Types)
local Config = require(script.Parent.Config)
local LiveOpsStore = require(script.Parent.LiveOpsStore)
local Messenger = require(script.Parent.Messenger)
local ItemService = require(script.Parent.Parent.ItemService)

type LiveOpsDocument = Types.LiveOpsDocument
type LiveOpsOverrides = Types.LiveOpsOverrides
type ApplyResult = Types.ApplyResult
type StoreResult<T> = LiveOpsStore.StoreResult<T>

export type ServiceResult<T> = { ok: true, value: T } | { ok: false, error: string }

local START_GET_RETRY_WAIT_SECONDS = 0.75

local localVersion: number = 0
local localDocument: LiveOpsDocument? = nil
local started = false
local subscribed = false

local function copyOverrides(overrides: LiveOpsOverrides): LiveOpsOverrides
	local copy: LiveOpsOverrides = {}
	for itemId, override in overrides do
		copy[itemId] = {
			Damage = override.Damage,
		}
	end
	return copy
end

local function copyDocument(doc: LiveOpsDocument): LiveOpsDocument
	return {
		SchemaVersion = doc.SchemaVersion,
		Version = doc.Version,
		Overrides = copyOverrides(doc.Overrides),
	}
end

local function applyIncoming(doc: LiveOpsDocument): ApplyResult
	local validated = Messenger.validatePayload(doc)
	if not validated.ok then
		warn("[LiveOps] reject invalid")
		return "RejectedInvalid"
	end

	local clean = validated.value
	if clean.Version <= localVersion then
		warn("[LiveOps] reject stale")
		return "RejectedStale"
	end

	-- Single apply path: update local state + ItemService overlays. Never write DS / publish.
	localVersion = clean.Version
	localDocument = copyDocument(clean)
	ItemService.setOverrides(clean.Overrides)
	print(`[LiveOps] applied v{localVersion}`)
	return "Applied"
end

--[[
	Read DS once and apply if newer. Used by start, already_started self-heal, pushOverrides,
	and optional one-shot after subscribe failure. No retries here.
]]
local function reconcileFromStore(): StoreResult<LiveOpsDocument?>
	local result = LiveOpsStore.getAsync()
	if not result.ok then
		return result
	end
	if result.value ~= nil and result.value.Version > localVersion then
		applyIncoming(result.value)
	end
	return result
end

local function loadFromStoreWithOneRetry(): StoreResult<LiveOpsDocument?>
	local first = LiveOpsStore.getAsync()
	if first.ok and first.value ~= nil then
		return first
	end

	if not first.ok then
		warn(`[LiveOps] start get failed: {first.error}; retrying once`)
	else
		-- Studio often returns ok+nil before DS is ready; one bounded retry then accept empty.
		warn("[LiveOps] start get empty; retrying once")
	end

	task.wait(START_GET_RETRY_WAIT_SECONDS)
	return LiveOpsStore.getAsync()
end

-- One delayed GetAsync only when SubscribeAsync failed — not a fleet poll loop.
local function scheduleSubscribeFailOneshotReconcile(): ()
	local delaySeconds = Config.SUBSCRIBE_FAIL_ONESHOT_RECONCILE_SECONDS
	if delaySeconds <= 0 then
		return
	end
	task.spawn(function()
		task.wait(delaySeconds)
		if not started or subscribed then
			return
		end
		local result = reconcileFromStore()
		if not result.ok then
			warn(`[LiveOps] subscribe-fail oneshot reconcile failed: {result.error}`)
		end
	end)
end

local function ensureSubscribed(): boolean
	if subscribed then
		return true
	end
	local subResult = Messenger.subscribe(function(payload)
		applyIncoming(payload)
	end)
	if not subResult.ok then
		warn(`[LiveOps] subscribe failed: {subResult.error}`)
		return false
	end
	subscribed = true
	return true
end

local LiveOpsService = {}

function LiveOpsService.applyIncoming(doc: LiveOpsDocument): ApplyResult
	return applyIncoming(doc)
end

function LiveOpsService.getLocalVersion(): number
	return localVersion
end

function LiveOpsService.getLocalDocument(): LiveOpsDocument?
	if localDocument == nil then
		return nil
	end
	return copyDocument(localDocument)
end

function LiveOpsService.start(): ServiceResult<nil>
	-- Self-heal if main raced / first load missed DS truth. No fleet poll.
	if started then
		local healed = reconcileFromStore()
		if not healed.ok then
			warn(`[LiveOps] already_started reconcile failed: {healed.error}`)
		end
		return { ok = false, error = "already_started" }
	end
	started = true

	-- Spread OnStart Gets across servers (per-key budget); then load DS.
	local startJitterMax = Config.START_LOAD_JITTER_SECONDS_MAX
	if startJitterMax > 0 then
		task.wait(math.random() * startJitterMax)
	end

	-- 1–2. Load from DataStore (one bounded retry on failure); nil → version 0 + empty overlays.
	local loadResult = loadFromStoreWithOneRetry()
	if not loadResult.ok then
		warn(`[LiveOps] start get failed: {loadResult.error}; localVersion=0`)
		localVersion = 0
		localDocument = nil
		ItemService.clearOverrides()
	elseif loadResult.value == nil then
		print("[LiveOps] start: DataStore empty; localVersion=0 (base stats)")
		localVersion = 0
		localDocument = nil
		ItemService.clearOverrides()
	else
		applyIncoming(loadResult.value)
	end

	-- 3. Subscribe MS → same applyIncoming. No periodic DS poll.
	local ok = ensureSubscribed()
	if not ok then
		scheduleSubscribeFailOneshotReconcile()
	end

	return { ok = true, value = nil }
end

--[[
	Admin seam (P5): reconcile local from DS → CAS write → publish → local apply.
	No retry storms; publish failure: peers still get MS from originator; new servers OnStart.
]]
function LiveOpsService.pushOverrides(overrides: LiveOpsOverrides): StoreResult<LiveOpsDocument>
	local reconcile = reconcileFromStore()
	if not reconcile.ok then
		warn(`[LiveOps] pushOverrides reconcile get failed: {reconcile.error}`)
		return { ok = false, error = reconcile.error }
	end

	local nextDoc: LiveOpsDocument = {
		SchemaVersion = Config.SCHEMA_VERSION,
		Version = localVersion + 1,
		Overrides = copyOverrides(overrides),
	}

	local cas = LiveOpsStore.tryCasWrite(nextDoc)
	if not cas.ok then
		return cas
	end

	local committed = cas.value
	local published = Messenger.publish(committed)
	if not published.ok then
		warn(`[LiveOps] publish failed after CAS: {published.error}`)
	end

	applyIncoming(committed)
	return { ok = true, value = committed }
end

return LiveOpsService
