--!strict
--[[
	LiveOpsCache — single-key MemoryStore snapshot of the latest LiveOpsDocument.
	No DataStore. No MessagingService. No per-player keys.
]]

local MemoryStoreService = game:GetService("MemoryStoreService")

local Types = require(script.Parent.Types)
local Config = require(script.Parent.Config)

type LiveOpsDocument = Types.LiveOpsDocument
type LiveOpsOverrides = Types.LiveOpsOverrides

export type CacheResult<T> = { ok: true, value: T } | { ok: false, error: string }

export type MemoryStoreAdapter = {
	GetAsync: (key: string) -> any,
	SetAsync: (key: string, value: any, expirationSeconds: number) -> (),
}

export type LiveOpsCacheApi = {
	getAsync: (self: LiveOpsCacheApi) -> CacheResult<LiveOpsDocument?>,
	setAsync: (self: LiveOpsCacheApi, doc: LiveOpsDocument) -> CacheResult<nil>,
}

local function createDefaultAdapter(): MemoryStoreAdapter
	local map = MemoryStoreService:GetHashMap(Config.MEMORYSTORE_MAP_NAME)
	return {
		GetAsync = function(key: string): any
			return map:GetAsync(key)
		end,
		SetAsync = function(key: string, value: any, expirationSeconds: number): ()
			map:SetAsync(key, value, expirationSeconds)
		end,
	}
end

local function isFiniteNumber(value: unknown): boolean
	return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isInteger(value: unknown): boolean
	return isFiniteNumber(value) and (value :: number) == math.floor(value :: number)
end

local function isValidDocument(doc: unknown): boolean
	if typeof(doc) ~= "table" then
		return false
	end
	local asDoc = doc :: { [string]: unknown }
	if not isFiniteNumber(asDoc.SchemaVersion) then
		return false
	end
	if not isInteger(asDoc.Version) or (asDoc.Version :: number) < 1 then
		return false
	end
	if typeof(asDoc.Overrides) ~= "table" then
		return false
	end
	return true
end

local function copyDocument(doc: LiveOpsDocument): LiveOpsDocument
	local overrides: LiveOpsOverrides = {}
	for itemId, override in doc.Overrides do
		overrides[itemId] = {
			Damage = override.Damage,
		}
	end
	return {
		SchemaVersion = doc.SchemaVersion,
		Version = doc.Version,
		Overrides = overrides,
	}
end

local function createCache(adapter: MemoryStoreAdapter): LiveOpsCacheApi
	local cache = {} :: LiveOpsCacheApi

	function cache:getAsync(): CacheResult<LiveOpsDocument?>
		local ok, result = pcall(function()
			return adapter.GetAsync(Config.MEMORYSTORE_KEY)
		end)
		if not ok then
			warn(`[LiveOpsCache] get failed: {result}`)
			return { ok = false, error = "memorystore_error" }
		end
		if result == nil then
			return { ok = true, value = nil }
		end
		if not isValidDocument(result) then
			warn("[LiveOpsCache] get failed: invalid document")
			return { ok = false, error = "invalid_document" }
		end
		return { ok = true, value = copyDocument(result :: LiveOpsDocument) }
	end

	function cache:setAsync(doc: LiveOpsDocument): CacheResult<nil>
		if not isValidDocument(doc) then
			return { ok = false, error = "invalid_document" }
		end
		local toWrite = copyDocument(doc)
		local ok, err = pcall(function()
			adapter.SetAsync(Config.MEMORYSTORE_KEY, toWrite, Config.MEMORYSTORE_TTL_SECONDS)
		end)
		if not ok then
			warn(`[LiveOpsCache] set failed: {err}`)
			return { ok = false, error = "memorystore_error" }
		end
		return { ok = true, value = nil }
	end

	return cache
end

local defaultAdapter: MemoryStoreAdapter = createDefaultAdapter()
local defaultCache: LiveOpsCacheApi = createCache(defaultAdapter)

local LiveOpsCache = {}

function LiveOpsCache.create(adapter: MemoryStoreAdapter?): LiveOpsCacheApi
	return createCache(adapter or createDefaultAdapter())
end

function LiveOpsCache.setAdapterForTests(adapter: MemoryStoreAdapter): ()
	defaultAdapter = adapter
	defaultCache = createCache(adapter)
end

function LiveOpsCache.getAsync(): CacheResult<LiveOpsDocument?>
	return defaultCache:getAsync()
end

function LiveOpsCache.setAsync(doc: LiveOpsDocument): CacheResult<nil>
	return defaultCache:setAsync(doc)
end

return LiveOpsCache
