--!strict
--[[
	Messenger — one-topic MessagingService for tiny LiveOpsSignal only (≪ 1KiB).
	Never publishes full Overrides. Never writes DataStore / MemoryStore.
]]

local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")

local Types = require(script.Parent.Types)
local Config = require(script.Parent.Config)

type LiveOpsSignal = Types.LiveOpsSignal
type LiveOpsDocument = Types.LiveOpsDocument
type LiveOpsOverrides = Types.LiveOpsOverrides
type ItemStatsOverride = Types.ItemStatsOverride

export type MessengerResult<T> = { ok: true, value: T } | { ok: false, error: string }

-- Publish/Subscribe use a JSON string body so soft-cap checks match wire bytes.
export type MessagingAdapter = {
	PublishAsync: (topic: string, message: string) -> (),
	SubscribeAsync: (topic: string, callback: (message: { Data: any }) -> ()) -> RBXScriptConnection,
}

export type MessengerApi = {
	validateSignal: (self: MessengerApi, payload: unknown) -> MessengerResult<LiveOpsSignal>,
	validateDocument: (self: MessengerApi, payload: unknown) -> MessengerResult<LiveOpsDocument>,
	getEncodedSize: (self: MessengerApi, signal: LiveOpsSignal) -> number,
	publish: (self: MessengerApi, signal: LiveOpsSignal) -> MessengerResult<nil>,
	subscribe: (self: MessengerApi, onSignal: (LiveOpsSignal) -> ()) -> MessengerResult<RBXScriptConnection>,
}

local ALLOWED_SIGNAL_KEYS: { [string]: boolean } = {
	SchemaVersion = true,
	Version = true,
}

local ALLOWED_DOC_KEYS: { [string]: boolean } = {
	SchemaVersion = true,
	Version = true,
	Overrides = true,
}

local ALLOWED_OVERRIDE_KEYS: { [string]: boolean } = {
	Damage = true,
}

local function createDefaultAdapter(): MessagingAdapter
	return {
		PublishAsync = function(topic: string, message: string): ()
			MessagingService:PublishAsync(topic, message)
		end,
		SubscribeAsync = function(topic: string, callback: (message: { Data: any }) -> ()): RBXScriptConnection
			return MessagingService:SubscribeAsync(topic, callback)
		end,
	}
end

local function isFiniteNumber(value: unknown): boolean
	return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isPositiveInteger(value: unknown): boolean
	return isFiniteNumber(value) and (value :: number) >= 1 and (value :: number) == math.floor(value :: number)
end

local function hasOnlyAllowedKeys(tbl: { [any]: any }, allowed: { [string]: boolean }): boolean
	for key in tbl do
		if typeof(key) ~= "string" or allowed[key] ~= true then
			return false
		end
	end
	return true
end

local function validateOverride(override: unknown): ItemStatsOverride?
	if typeof(override) ~= "table" then
		return nil
	end
	local asTable = override :: { [any]: any }
	if not hasOnlyAllowedKeys(asTable, ALLOWED_OVERRIDE_KEYS) then
		return nil
	end
	local damage = asTable.Damage
	if damage ~= nil and not isFiniteNumber(damage) then
		return nil
	end
	return {
		Damage = if damage ~= nil then damage :: number else nil,
	}
end

local function validateOverrides(overrides: unknown): LiveOpsOverrides?
	if typeof(overrides) ~= "table" then
		return nil
	end
	local result: LiveOpsOverrides = {}
	for itemId, override in overrides :: { [any]: any } do
		if typeof(itemId) ~= "string" then
			return nil
		end
		local cleaned = validateOverride(override)
		if cleaned == nil then
			return nil
		end
		result[itemId] = cleaned
	end
	return result
end

local function validateSignalValue(payload: unknown): MessengerResult<LiveOpsSignal>
	if typeof(payload) ~= "table" then
		return { ok = false, error = "invalid_payload" }
	end
	local asTable = payload :: { [any]: any }
	if not hasOnlyAllowedKeys(asTable, ALLOWED_SIGNAL_KEYS) then
		return { ok = false, error = "invalid_payload" }
	end
	if not isFiniteNumber(asTable.SchemaVersion) then
		return { ok = false, error = "invalid_payload" }
	end
	if not isPositiveInteger(asTable.Version) then
		return { ok = false, error = "invalid_payload" }
	end
	return {
		ok = true,
		value = {
			SchemaVersion = asTable.SchemaVersion :: number,
			Version = asTable.Version :: number,
		},
	}
end

local function validateDocumentValue(payload: unknown): MessengerResult<LiveOpsDocument>
	if typeof(payload) ~= "table" then
		return { ok = false, error = "invalid_payload" }
	end
	local asTable = payload :: { [any]: any }
	if not hasOnlyAllowedKeys(asTable, ALLOWED_DOC_KEYS) then
		return { ok = false, error = "invalid_payload" }
	end
	if not isFiniteNumber(asTable.SchemaVersion) then
		return { ok = false, error = "invalid_payload" }
	end
	if not isPositiveInteger(asTable.Version) then
		return { ok = false, error = "invalid_payload" }
	end
	local overrides = validateOverrides(asTable.Overrides)
	if overrides == nil then
		return { ok = false, error = "invalid_payload" }
	end
	return {
		ok = true,
		value = {
			SchemaVersion = asTable.SchemaVersion :: number,
			Version = asTable.Version :: number,
			Overrides = overrides,
		},
	}
end

local function decodeInboundData(data: unknown): unknown
	if typeof(data) == "string" then
		local ok, decoded = pcall(function()
			return HttpService:JSONDecode(data :: string)
		end)
		if not ok then
			return nil
		end
		return decoded
	end
	return data
end

local function createMessenger(adapter: MessagingAdapter): MessengerApi
	local messenger = {} :: MessengerApi

	function messenger:validateSignal(payload: unknown): MessengerResult<LiveOpsSignal>
		return validateSignalValue(payload)
	end

	function messenger:validateDocument(payload: unknown): MessengerResult<LiveOpsDocument>
		return validateDocumentValue(payload)
	end

	function messenger:getEncodedSize(signal: LiveOpsSignal): number
		return string.len(HttpService:JSONEncode(signal))
	end

	function messenger:publish(signal: LiveOpsSignal): MessengerResult<nil>
		local validated = validateSignalValue(signal)
		if not validated.ok then
			return { ok = false, error = "invalid_payload" }
		end

		local clean = validated.value
		local encoded = HttpService:JSONEncode(clean)
		if string.len(encoded) > Config.MS_PAYLOAD_SOFT_CAP_BYTES then
			return { ok = false, error = "payload_too_large" }
		end

		-- No retry storm; MemoryStore + DS retain truth if publish fails.
		local ok, err = pcall(function()
			adapter.PublishAsync(Config.MESSAGING_TOPIC, encoded)
		end)
		if not ok then
			warn(`[Messenger] publish failed: {err}`)
			return { ok = false, error = "publish_failed" }
		end

		return { ok = true, value = nil }
	end

	function messenger:subscribe(onSignal: (LiveOpsSignal) -> ()): MessengerResult<RBXScriptConnection>
		local ok, connectionOrErr = pcall(function()
			return adapter.SubscribeAsync(Config.MESSAGING_TOPIC, function(message: { Data: any })
				local decoded = decodeInboundData(message.Data)
				local validated = validateSignalValue(decoded)
				if not validated.ok then
					warn("[Messenger] reject invalid")
					return
				end
				onSignal(validated.value)
			end)
		end)

		if not ok then
			warn(`[Messenger] subscribe failed: {connectionOrErr}`)
			return { ok = false, error = "subscribe_failed" }
		end

		return { ok = true, value = connectionOrErr :: RBXScriptConnection }
	end

	return messenger
end

local defaultAdapter: MessagingAdapter = createDefaultAdapter()
local defaultMessenger: MessengerApi = createMessenger(defaultAdapter)

local Messenger = {}

function Messenger.create(adapter: MessagingAdapter?): MessengerApi
	return createMessenger(adapter or createDefaultAdapter())
end

function Messenger.setAdapterForTests(adapter: MessagingAdapter): ()
	defaultAdapter = adapter
	defaultMessenger = createMessenger(adapter)
end

function Messenger.validateSignal(payload: unknown): MessengerResult<LiveOpsSignal>
	return defaultMessenger:validateSignal(payload)
end

function Messenger.validateDocument(payload: unknown): MessengerResult<LiveOpsDocument>
	return defaultMessenger:validateDocument(payload)
end

function Messenger.getEncodedSize(signal: LiveOpsSignal): number
	return defaultMessenger:getEncodedSize(signal)
end

function Messenger.publish(signal: LiveOpsSignal): MessengerResult<nil>
	return defaultMessenger:publish(signal)
end

function Messenger.subscribe(onSignal: (LiveOpsSignal) -> ()): MessengerResult<RBXScriptConnection>
	return defaultMessenger:subscribe(onSignal)
end

return Messenger
