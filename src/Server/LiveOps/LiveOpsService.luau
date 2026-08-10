--!strict
--[[
	LiveOpsService — MemoryStore-first start + tiny MS signal + single apply path.
	DataStore = durable truth (admin CAS). MemoryStore = latest snapshot. MS = version ping.
	No fleet-wide DataStore poll. Followers never write DS on apply.
]]

local Types = require(script.Parent.Types)
local Config = require(script.Parent.Config)
local LiveOpsStore = require(script.Parent.LiveOpsStore)
local LiveOpsCache = require(script.Parent.LiveOpsCache)
local Messenger = require(script.Parent.Messenger)
local ItemService = require(script.Parent.Parent.ItemService)

type LiveOpsDocument = Types.LiveOpsDocument
type LiveOpsOverrides = Types.LiveOpsOverrides
type LiveOpsSignal = Types.LiveOpsSignal
type ApplyResult = Types.ApplyResult
type StoreResult<T> = LiveOpsStore.StoreResult<T>

export type ServiceResult<T> = { ok: true, value: T } | { ok: false, error: string }

local localVersion: number = 0
local localDocument: LiveOpsDocument? = nil
local started = false
local subscribed = false
local subscribeRetryGeneration = 0

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
	local validated = Messenger.validateDocument(doc)
	if not validated.ok then
		warn("[LiveOps] reject invalid")
		return "RejectedInvalid"
	end

	local clean = validated.value
	if clean.Version <= localVersion then
		warn("[LiveOps] reject stale")
		return "RejectedStale"
	end

	-- Single apply path: local state + ItemService overlays. Never write DS / publish.
	localVersion = clean.Version
	localDocument = copyDocument(clean)
	ItemService.setOverrides(clean.Overrides)
	print(`[LiveOps] applied v{localVersion}`)
	return "Applied"
end

-- ONE DataStore GetAsync → apply if newer (fallback / admin reconcile only).
local function reconcileFromDataStore(): StoreResult<LiveOpsDocument?>
	local result = LiveOpsStore.getAsync()
	if not result.ok then
		return result
	end
	if result.value ~= nil and result.value.Version > localVersion then
		applyIncoming(result.value)
	end
	return result
end

-- Prefer MemoryStore snapshot; on miss/fail, ONE DS GetAsync.
local function fetchLatestAndApply(): ()
	local cacheResult = LiveOpsCache.getAsync()
	if cacheResult.ok and cacheResult.value ~= nil then
		applyIncoming(cacheResult.value)
		return
	end
	if not cacheResult.ok then
		warn(`[LiveOps] MemoryStore get failed: {cacheResult.error}; DS fallback once`)
	end
	local ds = reconcileFromDataStore()
	if not ds.ok then
		warn(`[LiveOps] DataStore fallback get failed: {ds.error}`)
	end
end

local function handleVersionSignal(signal: LiveOpsSignal): ()
	if signal.Version <= localVersion then
		return
	end
	-- Tiny MS ping → load full doc from MemoryStore (or one DS fallback).
	fetchLatestAndApply()
end

local function trySubscribeOnce(): boolean
	local subResult = Messenger.subscribe(handleVersionSignal)
	if not subResult.ok then
		warn(`[LiveOps] subscribe failed: {subResult.error}`)
		return false
	end
	subscribed = true
	print("[LiveOps] subscribed")
	return true
end

-- Soft infinite retries with exponential backoff (cap ~60s). Never busy-loop.
local function startSubscribeWithRetry(): ()
	if subscribed then
		return
	end
	subscribeRetryGeneration += 1
	local generation = subscribeRetryGeneration

	task.spawn(function()
		local delaySeconds = Config.SUBSCRIBE_RETRY_INITIAL_SECONDS
		if delaySeconds < 1 then
			delaySeconds = 1
		end
		local maxDelay = Config.SUBSCRIBE_RETRY_MAX_SECONDS
		if maxDelay < delaySeconds then
			maxDelay = delaySeconds
		end

		while started and generation == subscribeRetryGeneration and not subscribed do
			if trySubscribeOnce() then
				return
			end
			task.wait(delaySeconds)
			delaySeconds = math.min(delaySeconds * 2, maxDelay)
		end
	end)
end

local function loadOnStart(): ()
	-- PRIMARY: MemoryStore. DS only if cache miss/fail (not mass GetAsync("Current")).
	local cacheResult = LiveOpsCache.getAsync()
	if cacheResult.ok and cacheResult.value ~= nil then
		applyIncoming(cacheResult.value)
		return
	end

	if not cacheResult.ok then
		warn(`[LiveOps] start MemoryStore miss/fail: {cacheResult.error}`)
	else
		print("[LiveOps] start: MemoryStore empty; one DataStore fallback")
	end

	local ds = LiveOpsStore.getAsync()
	if not ds.ok then
		warn(`[LiveOps] start DS fallback failed: {ds.error}; localVersion=0`)
		localVersion = 0
		localDocument = nil
		ItemService.clearOverrides()
		return
	end
	if ds.value == nil then
		print("[LiveOps] start: DataStore empty; localVersion=0 (base stats)")
		localVersion = 0
		localDocument = nil
		ItemService.clearOverrides()
		return
	end
	applyIncoming(ds.value)
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
	if started then
		fetchLatestAndApply()
		if not subscribed then
			startSubscribeWithRetry()
		end
		return { ok = false, error = "already_started" }
	end
	started = true

	local startJitterMax = Config.START_LOAD_JITTER_SECONDS_MAX
	if startJitterMax > 0 then
		task.wait(math.random() * startJitterMax)
	end

	loadOnStart()
	startSubscribeWithRetry()

	return { ok = true, value = nil }
end

--[[
	Admin: CAS DS → MemoryStore set → tiny MS signal → local apply.
]]
function LiveOpsService.pushOverrides(overrides: LiveOpsOverrides): StoreResult<LiveOpsDocument>
	-- Rare admin-server reconcile (MemoryStore first, else one DS get).
	fetchLatestAndApply()

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

	local cached = LiveOpsCache.setAsync(committed)
	if not cached.ok then
		warn(`[LiveOps] MemoryStore write failed after CAS: {cached.error}`)
	end

	local signal: LiveOpsSignal = {
		SchemaVersion = committed.SchemaVersion,
		Version = committed.Version,
	}
	local published = Messenger.publish(signal)
	if not published.ok then
		warn(`[LiveOps] publish failed after CAS: {published.error}`)
	end

	applyIncoming(committed)
	return { ok = true, value = committed }
end

return LiveOpsService
