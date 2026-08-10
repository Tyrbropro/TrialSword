--!strict
--[[
	LiveOpsStore — single-key DataStore source of truth via GetAsync + UpdateAsync CAS.
	Never SetAsync clobber. Never MessagingService / MemoryStore / ItemService.
]]

local DataStoreService = game:GetService("DataStoreService")

local Types = require(script.Parent.Types)
local Config = require(script.Parent.Config)

type LiveOpsDocument = Types.LiveOpsDocument

export type StoreResult<T> = { ok: true, value: T } | { ok: false, error: string }

export type DataStoreAdapter = {
	GetAsync: (key: string) -> any,
	UpdateAsync: (key: string, transform: (any) -> any) -> any,
}

export type LiveOpsStoreApi = {
	getAsync: (self: LiveOpsStoreApi) -> StoreResult<LiveOpsDocument?>,
	tryCasWrite: (self: LiveOpsStoreApi, nextDoc: LiveOpsDocument) -> StoreResult<LiveOpsDocument>,
}

local function createDefaultAdapter(): DataStoreAdapter
	local dataStore = DataStoreService:GetDataStore(Config.DATASTORE_NAME)
	return {
		GetAsync = function(key: string): any
			return dataStore:GetAsync(key)
		end,
		UpdateAsync = function(key: string, transform: (any) -> any): any
			return dataStore:UpdateAsync(key, transform)
		end,
	}
end

local function isFiniteNumber(value: unknown): boolean
	return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isInteger(value: unknown): boolean
	return isFiniteNumber(value) and (value :: number) == math.floor(value :: number)
end

-- Light shape check; deeper schema gate belongs in P4.
local function isValidDocument(doc: unknown): boolean
	if typeof(doc) ~= "table" then
		return false
	end
	local asDoc = doc :: { [string]: unknown }
	if not isFiniteNumber(asDoc.SchemaVersion) then
		return false
	end
	if not isInteger(asDoc.Version) then
		return false
	end
	if typeof(asDoc.Overrides) ~= "table" then
		return false
	end
	return true
end

local function readCurrentVersion(current: unknown): number
	if typeof(current) ~= "table" then
		return 0
	end
	local version = (current :: { [string]: unknown }).Version
	if not isInteger(version) then
		return 0
	end
	return version :: number
end

local function toDocument(doc: LiveOpsDocument): LiveOpsDocument
	return {
		SchemaVersion = Config.SCHEMA_VERSION,
		Version = doc.Version,
		Overrides = doc.Overrides,
	}
end

local function createStore(adapter: DataStoreAdapter): LiveOpsStoreApi
	local store = {} :: LiveOpsStoreApi

	function store:getAsync(): StoreResult<LiveOpsDocument?>
		local ok, result = pcall(function()
			return adapter.GetAsync(Config.DATASTORE_KEY)
		end)

		if not ok then
			warn(`[LiveOpsStore] get failed: {result}`)
			return { ok = false, error = "datastore_error" }
		end

		if result == nil then
			return { ok = true, value = nil }
		end

		if not isValidDocument(result) then
			warn("[LiveOpsStore] get failed: invalid stored document")
			return { ok = false, error = "invalid_document" }
		end

		local doc = result :: LiveOpsDocument
		return {
			ok = true,
			value = {
				SchemaVersion = doc.SchemaVersion,
				Version = doc.Version,
				Overrides = doc.Overrides,
			},
		}
	end

	function store:tryCasWrite(nextDoc: LiveOpsDocument): StoreResult<LiveOpsDocument>
		if not isValidDocument(nextDoc) then
			return { ok = false, error = "invalid_document" }
		end

		local committed: LiveOpsDocument? = nil
		local rejectReason: string? = nil

		-- Version gate MUST run inside UpdateAsync transform (CAS). No retries: fail soft.
		local ok, result = pcall(function()
			return adapter.UpdateAsync(Config.DATASTORE_KEY, function(current: any): any
				local currentVersion = readCurrentVersion(current)
				if nextDoc.Version <= currentVersion then
					rejectReason = "stale_version"
					return nil
				end

				local toWrite = toDocument(nextDoc)
				committed = toWrite
				return toWrite
			end)
		end)

		if not ok then
			warn(`[LiveOpsStore] cas write failed: {result}`)
			return { ok = false, error = "datastore_error" }
		end

		if rejectReason ~= nil then
			return { ok = false, error = rejectReason }
		end

		if committed == nil then
			-- Transform aborted without setting reason (unexpected); treat as soft fail.
			return { ok = false, error = "stale_version" }
		end

		-- Prefer transform-committed doc; UpdateAsync return should match.
		local value = committed
		if isValidDocument(result) then
			value = result :: LiveOpsDocument
		end

		return { ok = true, value = value }
	end

	return store
end

local defaultAdapter: DataStoreAdapter = createDefaultAdapter()
local defaultStore: LiveOpsStoreApi = createStore(defaultAdapter)

local LiveOpsStore = {}

function LiveOpsStore.create(adapter: DataStoreAdapter?): LiveOpsStoreApi
	return createStore(adapter or createDefaultAdapter())
end

-- Swap the module singleton's adapter (tests). Rebuilds default store API.
function LiveOpsStore.setAdapterForTests(adapter: DataStoreAdapter): ()
	defaultAdapter = adapter
	defaultStore = createStore(adapter)
end

function LiveOpsStore.getAsync(): StoreResult<LiveOpsDocument?>
	return defaultStore:getAsync()
end

function LiveOpsStore.tryCasWrite(nextDoc: LiveOpsDocument): StoreResult<LiveOpsDocument>
	return defaultStore:tryCasWrite(nextDoc)
end

return LiveOpsStore
