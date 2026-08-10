--!strict
--[[
	LiveOpsService — OnStart load + MS subscribe + slow poll; single apply path.
	Followers never write DataStore on apply. Truth then announce via pushOverrides.
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
local pollToken = 0

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
	Read DS once and apply if newer. Used by start, already_started self-heal, pushOverrides.
	No retries here (callers that need a bounded retry do it explicitly).
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

local function pollOnce(): ()
	local result = reconcileFromStore()
	if not result.ok then
		warn(`[LiveOps] poll get failed: {result.error}`)
	end
end

local function startPollLoop(): ()
	pollToken += 1
	local token = pollToken
	local interval = Config.POLL_INTERVAL_SECONDS
	-- Hard guard: poll MUST stay in [45, 60]s (Config should already comply).
	if interval < 45 or interval > 60 then
		warn("[LiveOps] invalid POLL_INTERVAL_SECONDS; clamping to 50")
		interval = 50
	end

	task.spawn(function()
		while started and token == pollToken do
			task.wait(interval)
			if not started or token ~= pollToken then
				break
			end
			pollOnce()
		end
	end)
end

local function ensureSubscribed(): ()
	if subscribed then
		return
	end
	local subResult = Messenger.subscribe(function(payload)
		applyIncoming(payload)
	end)
	if not subResult.ok then
		warn(`[LiveOps] subscribe failed: {subResult.error}`)
		return
	end
	subscribed = true
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
	-- Self-heal if main raced / first load missed DS truth. No second subscribe/poll.
	if started then
		local healed = reconcileFromStore()
		if not healed.ok then
			warn(`[LiveOps] already_started reconcile failed: {healed.error}`)
		end
		return { ok = false, error = "already_started" }
	end
	started = true

	-- 1–2. Load from DataStore (one bounded retry on failure); nil → version 0 + empty overlays.
	local loadResult = loadFromStoreWithOneRetry()
	if not loadResult.ok then
		warn(`[LiveOps] start get failed: {loadResult.error}; localVersion=0 (poll safety net)`)
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

	-- 3. Subscribe MS → same applyIncoming (poll remains safety net if this fails).
	ensureSubscribed()

	-- 4. Slow poll safety net (once).
	startPollLoop()

	return { ok = true, value = nil }
end

--[[
	Admin seam (P5): reconcile local from DS → CAS write → publish → local apply.
	No retry storms; publish failure still converges via poll ≤ ~2 min.
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
