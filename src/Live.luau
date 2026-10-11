--!strict
-- Live updates on every server: ban, team and whitelist changes arrive through MessagingService
-- (topic "RoVision"). RoVision (through Open Cloud, once the game owner has saved a key) and the game's
-- other servers (after RoVision:Ban/Unban/Allow/Disallow) publish {"v":1,"type":"bans_changed",
-- "robloxUserIds":["…"]} (or "team_changed", "allowlists_changed"), and the handler for that type
-- re-checks those users right away instead of at the next periodic re-check. A message carries no
-- data about the change: the answer always comes from the API.
-- Fails open: without a subscription the periodic re-check still catches every change.

local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local RunService = game:GetService("RunService")

local Log = require(script.Parent.Log)
local Util = require(script.Parent.Util)

local TOPIC = "RoVision" -- reserved for the module
local MESSAGE_VERSION = 1
local SUBSCRIBE_RETRY_BASE = 5
local SUBSCRIBE_RETRY_MAX = 300
local DEBUG_PREVIEW_LIMIT = 200

-- Message types the game's servers publish themselves.
export type Kind = "bans_changed" | "allowlists_changed"

-- Gets the UserIds of one message.
export type Handler = (userIds: { number }) -> ()

-- Message type -> handler.
export type Handlers = { [string]: Handler }

local Live = {}

local handlers: Handlers? = nil
local connection: RBXScriptConnection? = nil
local stopped = false

local function preview(text: string): string
	if #text > DEBUG_PREVIEW_LIMIT then
		return string.sub(text, 1, DEBUG_PREVIEW_LIMIT) .. "…"
	end
	return text
end

-- Roblox UserIds come as decimal strings; numbers are accepted too.
local function parseUserId(raw: any): number?
	local userId: number? = nil
	if type(raw) == "string" and string.match(raw, "^%d+$") then
		userId = tonumber(raw)
	elseif type(raw) == "number" then
		userId = raw
	end
	if userId and userId > 0 and userId % 1 == 0 and userId < 2 ^ 53 then
		return userId
	end
	return nil
end

local function onHandlerError(err: any)
	Log.WarnThrottled("live-handler", 60, `Live updates: a change couldn't be handled: {err}`)
end

local function onMessage(message: any)
	local byType = handlers
	if stopped or byType == nil then
		return
	end
	local data = if type(message) == "table" then message.Data else nil
	if type(data) ~= "string" then
		Log.Debug(`Live updates: ignored a message that isn't a JSON string ({typeof(data)}).`)
		return
	end
	local decoded, payload = pcall(HttpService.JSONDecode, HttpService, data)
	if not decoded or type(payload) ~= "table" then
		Log.Debug(`Live updates: ignored a message that isn't a JSON object: {preview(data)}`)
		return
	end
	local version = payload.v
	if type(version) ~= "number" or version < MESSAGE_VERSION then
		Log.Debug(`Live updates: ignored a message without a valid version: {preview(data)}`)
		return
	elseif version > MESSAGE_VERSION then
		Log.Debug(`Live updates: ignored a message in a newer format (v{version}).`)
		return
	end
	local kind = payload.type
	if kind == "ping" then
		Log.Debug("Live updates: ping from RoVision received; this server gets changes instantly.")
		return
	end
	local callback = if type(kind) == "string" then byType[kind] else nil
	if callback == nil then
		Log.Debug(`Live updates: ignored a message of unknown type {preview(tostring(kind))}.`)
		return
	end
	local rawIds = payload.robloxUserIds
	if type(rawIds) ~= "table" then
		Log.Debug(`Live updates: ignored a {kind} message without robloxUserIds: {preview(data)}`)
		return
	end
	local userIds: { number } = {}
	for _, raw in rawIds do
		local userId = parseUserId(raw)
		if userId then
			table.insert(userIds, userId)
		end
	end
	if #userIds == 0 then
		Log.Debug(`Live updates: ignored a {kind} message without valid ids: {preview(data)}`)
		return
	end
	Log.Debug(`Live updates: {kind} for {#userIds} user(s).`)
	xpcall(callback, onHandlerError, userIds)
end

local function studioHint(): string
	if RunService:IsStudio() then
		return " In Studio this needs a published place and "
			.. "Game Settings → Security → Enable Studio Access to API Services."
	end
	return ""
end

-- Yields. Retries with a growing pause until it works or the server closes.
local function subscribe()
	local attempt = 0
	while not stopped do
		attempt += 1
		local ok, result = pcall(MessagingService.SubscribeAsync, MessagingService, TOPIC, onMessage)
		if ok then
			if stopped then
				result:Disconnect()
			else
				connection = result
				Log.Debug(`Live updates: subscribed to MessagingService topic "{TOPIC}".`)
			end
			return
		end
		local jitter = 0.75 + math.random() * 0.5
		local delay = math.min(SUBSCRIBE_RETRY_MAX, SUBSCRIBE_RETRY_BASE * 2 ^ (attempt - 1) * jitter)
		Log.WarnOnce(
			"live-subscribe",
			`Live updates: can't subscribe to MessagingService ({tostring(result)}); retrying in the background. `
				.. "Until then changes to bans, the team and whitelists made on the site or in other servers "
				.. "reach this server at the periodic re-check."
				.. studioHint()
		)
		Log.Debug(`Live updates: next subscription attempt in {math.floor(delay)} s.`)
		task.wait(delay)
	end
end

-- Subscribes to the topic in the background. Doesn't yield.
function Live.Start(byType: Handlers)
	if handlers then
		return
	end
	handlers = byType
	task.spawn(subscribe)
end

-- Tells the game's other servers that something about a user changed (after RoVision:Ban, Unban, Allow
-- or Disallow). Doesn't yield. A failure only warns: the other servers still see the change at their
-- periodic re-check.
function Live.Announce(kind: Kind, userId: number)
	if handlers == nil or stopped then
		return -- live updates are off
	end
	-- One id per message, far below the 1 KB MessagingService limit (30 ids at most).
	local message = HttpService:JSONEncode({
		v = MESSAGE_VERSION,
		type = kind,
		robloxUserIds = { Util.FormatUserId(userId) },
	})
	task.spawn(function()
		local ok, err = pcall(MessagingService.PublishAsync, MessagingService, TOPIC, message)
		if ok then
			Log.Debug(`Live updates: told other servers about {kind} for {userId}.`)
		else
			Log.WarnThrottled(
				"live-publish",
				300,
				`Live updates: couldn't tell other servers about {kind} for {userId} ({tostring(err)}). `
					.. "They will see it at their periodic re-check."
			)
		end
	end)
end

-- Stops listening (server shutdown).
function Live.Stop()
	stopped = true
	local current = connection
	connection = nil
	if current then
		current:Disconnect()
	end
end

return Live
