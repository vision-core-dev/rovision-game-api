--!strict
-- Ban list: checks through Lookups (batched and cached), enforcement on join, on periodic re-checks and
-- on ban changes from other servers (Live), and game-scope bans issued from the game itself.
-- Fails open: if the API can't be reached, nobody is kicked.

local Players = game:GetService("Players")

local Http = require(script.Parent.Http)
local Log = require(script.Parent.Log)
local Lookups = require(script.Parent.Lookups)
local Signal = require(script.Parent.Signal)
local Types = require(script.Parent.Types)
local Util = require(script.Parent.Util)

type Ban = Types.Ban

local CHECK_PATH = "/game-api/v1/bans/check"
local BANS_PATH = "/game-api/v1/bans"
local MAX_REASON_LENGTH = 500
local MAX_DURATION_DAYS = 3650
local KICK_REASON_LIMIT = 200

export type Settings = {
	Enforce: boolean,
	KickMessage: Types.KickMessage?,
}

local Bans = {}

Bans.PlayerBanned = Signal.new() :: Types.Signal<Player, Ban>

local settings: Settings? = nil
local handled: { [number]: string } = {} -- UserId -> ban id already handled in this session

---------------------------------------------------------------------------
-- Parsing

local function parseBan(raw: any): Ban?
	if type(raw) ~= "table" or type(raw.id) ~= "string" then
		return nil
	end
	local ban: Ban = {
		Id = raw.id,
		-- Unknown future values are passed through as-is.
		Scope = (if type(raw.scope) == "string" then raw.scope else "rovision") :: any,
		Category = (if type(raw.category) == "string" then raw.category else "other") :: any,
		Reason = if type(raw.reason) == "string" then raw.reason else "",
		ExpiresAt = if type(raw.expiresAt) == "string" then raw.expiresAt else nil,
	}
	return table.freeze(ban) :: Ban
end

local function isExpired(ban: Ban): boolean
	local expiresAt = ban.ExpiresAt
	if not expiresAt then
		return false
	end
	local ok, parsed = pcall(DateTime.fromIsoDate, expiresAt)
	local date: DateTime? = if ok then parsed else nil -- fromIsoDate returns nil for bad input
	if date == nil then
		return false -- can't tell; the API only returns active bans
	end
	return date.UnixTimestampMillis <= DateTime.now().UnixTimestampMillis
end

local function active(ban: Ban?): Ban?
	if ban and not isExpired(ban) then
		return ban
	end
	return nil
end

---------------------------------------------------------------------------
-- Kick message (Ukrainian by default; no links: Roblox doesn't allow sending players off-platform)

local SCOPE_TEXT: { [string]: string } = {
	rovision = "Вас заблоковано в мережі ігор RoVision.",
	studio = "Вас заблоковано в іграх цієї студії.",
	game = "Вас заблоковано в цій грі.",
}

local CATEGORY_TEXT: { [string]: string } = {
	exploiting = "читерство та експлойти",
	scamming = "шахрайство",
	botting = "боти та автоматизація",
}

local function formatExpiry(iso: string): string?
	local year, month, day, hour, minute = string.match(iso, "^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d)")
	if year then
		return `{day}.{month}.{year} {hour}:{minute} UTC`
	end
	year, month, day = string.match(iso, "^(%d%d%d%d)-(%d%d)-(%d%d)")
	if year then
		return `{day}.{month}.{year}`
	end
	return nil
end

-- Reasons are written by people; keep them short and without links.
local function cleanReason(reason: string): string
	local text = string.gsub(reason, "%a[%w%+%.%-]*://%S*", "")
	text = string.gsub(text, "[Ww][Ww][Ww]%.%S+", "")
	text = string.gsub(text, "%s+", " ")
	text = Util.Trim(text)
	if Util.Utf16Length(text) == nil then
		return ""
	end
	local short = Util.TruncateUtf16(text, KICK_REASON_LIMIT)
	if short ~= text then
		return short .. "…"
	end
	if #text > 0 and not string.find(text, "[%.!%?]$") then
		return text .. "."
	end
	return text
end

local function defaultKickMessage(ban: Ban): string
	local parts = { SCOPE_TEXT[ban.Scope] or "Вас заблоковано." }
	local category = CATEGORY_TEXT[ban.Category]
	if category then
		table.insert(parts, `Порушення: {category}.`)
	end
	local reason = cleanReason(ban.Reason)
	if reason ~= "" then
		table.insert(parts, `Причина: {reason}`)
	end
	if ban.ExpiresAt then
		local expiry = formatExpiry(ban.ExpiresAt)
		table.insert(parts, if expiry then `Діє до {expiry}.` else "Блокування тимчасове.")
	else
		table.insert(parts, "Блокування безстрокове.")
	end
	return table.concat(parts, " ")
end

local function kickMessageFor(ban: Ban): string
	local custom = settings and settings.KickMessage
	if type(custom) == "string" then
		return custom
	elseif type(custom) == "function" then
		-- The function may return nil to use the default message.
		local ok, message = pcall(custom, ban)
		if ok and type(message) == "string" and #message > 0 then
			return message
		elseif not ok or message ~= nil then
			Log.WarnThrottled(
				"kick-message",
				60,
				`KickMessage function failed or returned a non-string ({tostring(message)}); using the default message.`
			)
		end
	end
	return defaultKickMessage(ban)
end

---------------------------------------------------------------------------
-- Enforcement

local function handle(player: Player, ban: Ban)
	if player.Parent ~= Players or handled[player.UserId] == ban.Id then
		return
	end
	handled[player.UserId] = ban.Id
	Log.Debug(`{player.Name} ({player.UserId}) has an active {ban.Scope} ban {ban.Id}`)
	Bans.PlayerBanned:Fire(player, ban)
	if settings and settings.Enforce then
		player:Kick(kickMessageFor(ban))
	end
end

local function onAnswer(player: Player, ok: boolean, raw: Ban?, reason: Lookups.Reason)
	local ban = active(raw)
	if ok and ban then
		handle(player, ban)
	elseif ok and reason == "changed" then
		-- The ban was lifted; if it applies again later, PlayerBanned fires for it again.
		handled[player.UserId] = nil
	end
end

local config: Lookups.Config<Ban> = {
	Name = "Ban check",
	Path = CHECK_PATH,
	Field = "bans",
	Parse = parseBan,
	FailureNote = "Players are let in until the API responds again.",
	OnAnswer = onAnswer,
}
local lookup: Lookups.Lookup<Ban> = Lookups.new(config)

-- Yields. Returns (true, ban or nil) when known, (false, nil) when the API couldn't be reached.
function Bans.Check(userId: number): (boolean, Ban?)
	local ok, ban = lookup.Check(userId)
	return ok, active(ban)
end

-- The bans of these users changed somewhere (a message from Live).
function Bans.Changed(userIds: { number })
	lookup.Changed(userIds)
end

function Bans.Start(options: Settings)
	if settings then
		return
	end
	settings = options
	Players.PlayerRemoving:Connect(function(player)
		handled[player.UserId] = nil
	end)
end

---------------------------------------------------------------------------
-- Game-scope bans from the game (e.g. admin commands)

-- Yields. Returns (true, ban) or (false, error message).
function Bans.Ban(userId: number, options: any): (boolean, Ban | string)
	if type(options) ~= "table" then
		return false, "options must be a table { Reason = string, DurationDays = number?, Category = string? }"
	end
	local reason = if type(options.Reason) == "string" then Util.Trim(options.Reason) else ""
	local reasonLength = Util.Utf16Length(reason)
	if reasonLength == nil or reasonLength < 1 or reasonLength > MAX_REASON_LENGTH then
		return false, `Reason must be text of 1-{MAX_REASON_LENGTH} characters`
	end
	local days = options.DurationDays
	if days ~= nil and (type(days) ~= "number" or days % 1 ~= 0 or days < 1 or days > MAX_DURATION_DAYS) then
		return false, `DurationDays must be a whole number from 1 to {MAX_DURATION_DAYS}, or nil for a permanent ban`
	end
	local category = options.Category
	if category ~= nil and not Types.BanCategories[category] then
		return false, "Category must be one of: exploiting, scamming, botting, other"
	end

	local body = {
		robloxUserId = Util.FormatUserId(userId),
		reason = reason,
		category = category, -- nil: the API default ("other")
		durationDays = days, -- nil: permanent
	}
	local response = Http.Request("POST", BANS_PATH, body, { MaxAttempts = 3 })
	if not response.Ok then
		local message = response.Error or "request failed"
		if not response.Warned then
			Log.Warn(`Ban of {userId} failed: {message}`)
		end
		return false, message
	end
	local ban = parseBan(response.Data)
	if not ban then
		return false, "unexpected response from the API"
	end
	Log.Debug(`Banned {userId} in this game: {ban.Id}`)

	-- A longer ban from another scope may also apply, but this one is active, so it is a valid answer.
	lookup.Set(userId, ban)
	local player = Players:GetPlayerByUserId(userId)
	if player then
		handle(player, ban)
	end
	return true, ban
end

-- Yields. Lifts this game's game-scope bans of the user.
-- Returns (true, number of lifted bans) or (false, error message).
function Bans.Unban(userId: number): (boolean, number | string)
	local response = Http.Request("DELETE", `{BANS_PATH}/{Util.FormatUserId(userId)}`, nil, { MaxAttempts = 3 })
	if not response.Ok then
		local message = response.Error or "request failed"
		if not response.Warned then
			Log.Warn(`Unban of {userId} failed: {message}`)
		end
		return false, message
	end
	-- Studio or RoVision bans may still apply; the next check asks the API again.
	lookup.Forget(userId)
	handled[userId] = nil
	local data = response.Data
	local lifted = 0
	if type(data) == "table" and type(data.lifted) == "number" then
		lifted = data.lifted
	end
	Log.Debug(`Unbanned {userId} in this game: {lifted} ban(s) lifted`)
	return true, lifted
end

return Bans
