--!strict
-- Whitelists: named lists of players on the site (game, studio or RoVision-wide), asked for by key.
-- Checks go through Lookups (batched, prefetched on join, cached per player with all their keys).
-- Fails closed: if the API can't be reached, IsAllowed returns false. The RequireAllowed gate keeps
-- players in while it can't tell, checks again, and kicks only on a definite "not on the list".

local Players = game:GetService("Players")

local Http = require(script.Parent.Http)
local Log = require(script.Parent.Log)
local Lookups = require(script.Parent.Lookups)
local Signal = require(script.Parent.Signal)
local Team = require(script.Parent.Team)
local Types = require(script.Parent.Types)
local Util = require(script.Parent.Util)

type AllowlistEntry = Types.AllowlistEntry

local CHECK_PATH = "/game-api/v1/allowlists/check"
local LISTS_PATH = "/game-api/v1/allowlists"
local NETWORK_PREFIX = "rovision:" -- RoVision-wide lists
local MIN_KEY_LENGTH = 2
local MAX_KEY_LENGTH = 32
local MAX_NOTE_LENGTH = 500
local MAX_DURATION_DAYS = 3650
-- While the API can't be reached, the gate lets a player stay and checks again after these pauses (seconds).
local GATE_RETRY_DELAYS = { 5, 15, 45 }
-- No links: Roblox doesn't allow sending players off-platform.
local DEFAULT_GATE_MESSAGE = "Зараз у цю гру можуть зайти лише гравці зі списку доступу. Вас у ньому немає."

type Gate = {
	Key: string,
	KickMessage: string,
	AllowTeam: boolean,
}

type GateState = "running" | "again"

local Allowlists = {}

Allowlists.ListsChanged = Signal.new() :: Types.Signal<Player, { string }>

local EMPTY: { string } = table.freeze({} :: { string })
local known: { [number]: { string } } = {} -- UserId -> last lists seen for a player in this server
local gate: Gate? = nil
local gateStates: { [Player]: GateState } = {}
local gateRetries: { [Player]: number } = {}
local gateRetryPending: { [Player]: true } = {}
local started = false

-- Lowercased key, or nil for anything that can't be a list key: 2-32 of a-z, 0-9, "-" and "_", starting
-- with a letter or digit; RoVision-wide lists are asked for as "rovision:<key>".
function Allowlists.NormalizeKey(key: any): string?
	if type(key) ~= "string" then
		return nil
	end
	local lowered = string.lower(Util.Trim(key))
	local plain = lowered
	if string.sub(lowered, 1, #NETWORK_PREFIX) == NETWORK_PREFIX then
		plain = string.sub(lowered, #NETWORK_PREFIX + 1)
	end
	if #plain < MIN_KEY_LENGTH or #plain > MAX_KEY_LENGTH or not string.match(plain, "^[a-z0-9][a-z0-9_%-]*$") then
		return nil
	end
	return lowered
end

local function parseLists(raw: any): { string }?
	if type(raw) ~= "table" then
		return nil
	end
	local lists: { string } = {}
	for _, key in raw do
		if type(key) == "string" then
			table.insert(lists, key)
		end
	end
	table.sort(lists)
	return table.freeze(lists)
end

local function sameLists(a: { string }, b: { string }): boolean
	if #a ~= #b then
		return false
	end
	for index, key in a do
		if b[index] ~= key then
			return false
		end
	end
	return true
end

local lookup: Lookups.Lookup<{ string }>

---------------------------------------------------------------------------
-- RequireAllowed gate

-- Yields. true: may stay; false: definitely not on the list (nor on the team, when that counts); nil: unknown.
local function admitted(current: Gate, userId: number): boolean?
	local listsOk, lists = lookup.Check(userId)
	if listsOk and lists and table.find(lists, current.Key) then
		return true
	end
	if current.AllowTeam then
		local roleOk, role = Team.GetRole(userId)
		if roleOk and Team.AtLeast(role, "moderator") then
			return true
		elseif not roleOk then
			return nil
		end
	end
	return if listsOk then false else nil
end

local checkGate: (player: Player) -> ()

local function scheduleRetry(player: Player, current: Gate)
	if gateRetryPending[player] then
		return
	end
	local used = gateRetries[player] or 0
	local delay = GATE_RETRY_DELAYS[used + 1]
	if delay == nil then
		Log.WarnThrottled(
			"gate-unknown",
			60,
			`RequireAllowed: can't tell whether {player.Name} ({player.UserId}) is on "{current.Key}" `
				.. "(the RoVision API can't be reached), so they stay. The periodic re-check will try again."
		)
		return
	end
	gateRetries[player] = used + 1
	gateRetryPending[player] = true
	task.delay(delay, function()
		gateRetryPending[player] = nil
		checkGate(player)
	end)
end

local function runGate(player: Player)
	repeat
		gateStates[player] = "running"
		local current = gate
		if current and player.Parent == Players then
			local verdict = admitted(current, player.UserId)
			if gate ~= current then
				gateStates[player] = "again" -- RequireAllowed was called again meanwhile
			elseif player.Parent ~= Players then
				break
			elseif verdict == false then
				gateStates[player] = nil
				Log.Debug(`{player.Name} ({player.UserId}) is not on "{current.Key}"; kicked (RequireAllowed).`)
				player:Kick(current.KickMessage)
				return
			elseif verdict == nil then
				scheduleRetry(player, current)
			else
				gateRetries[player] = nil
			end
		end
	until gateStates[player] ~= "again"
	gateStates[player] = nil
end

-- Evaluates the gate for a player in the background; one evaluation at a time per player.
checkGate = function(player: Player)
	if gate == nil or player.UserId <= 0 then
		return -- no gate, or a Studio test player
	end
	if gateStates[player] then
		gateStates[player] = "again"
		return
	end
	gateStates[player] = "running"
	task.spawn(runGate, player)
end

---------------------------------------------------------------------------
-- Checks

local function onAnswer(player: Player, ok: boolean, lists: { string }?, _reason: Lookups.Reason)
	if ok then
		local userId = player.UserId
		local current = lists or EMPTY
		local previous = known[userId]
		known[userId] = current
		if previous and not sameLists(previous, current) then
			Log.Debug(`{player.Name} ({userId}) lists: {table.concat(current, ", ")}`)
			Allowlists.ListsChanged:Fire(player, table.clone(current))
		end
	end
	local activeGate = gate
	if activeGate then
		if ok then
			checkGate(player)
		elseif player.UserId > 0 then
			scheduleRetry(player, activeGate)
		end
	end
end

local config: Lookups.Config<{ string }> = {
	Name = "Whitelist check",
	Path = CHECK_PATH,
	Field = "allowed",
	Parse = parseLists,
	FailureNote = "Until it responds, IsAllowed returns false and RequireAllowed lets players stay.",
	OnAnswer = onAnswer,
}
lookup = Lookups.new(config)

-- Yields. (on the list, checked). Fails closed: (false, false) when the API couldn't be reached.
function Allowlists.IsAllowed(userId: number, key: string): (boolean, boolean)
	local ok, lists = lookup.Check(userId)
	if not ok then
		Log.WarnThrottled(
			"lists-unknown",
			60,
			`IsAllowed: the lists of {userId} are unknown (the RoVision API can't be reached), so the answer is false.`
		)
		return false, false
	end
	return lists ~= nil and table.find(lists, key) ~= nil, true
end

-- Yields. All keys the user is on (a copy) and whether the API answered.
function Allowlists.GetLists(userId: number): ({ string }, boolean)
	local ok, lists = lookup.Check(userId)
	return table.clone(lists or EMPTY), ok
end

-- The lists of these users changed somewhere (a message from Live).
function Allowlists.Changed(userIds: { number })
	lookup.Changed(userIds)
end

---------------------------------------------------------------------------
-- Changes from the game: only this game's own lists

local function gameListError(key: string): string?
	if string.sub(key, 1, #NETWORK_PREFIX) == NETWORK_PREFIX then
		return "RoVision-wide lists can't be changed from a game"
	end
	return nil
end

local function parseEntry(raw: any, key: string, userId: number): AllowlistEntry?
	if type(raw) ~= "table" or type(raw.id) ~= "string" then
		return nil
	end
	local entry: AllowlistEntry = {
		Id = raw.id,
		Key = key,
		UserId = userId,
		Username = if type(raw.robloxUsername) == "string" then raw.robloxUsername else nil,
		Note = if type(raw.note) == "string" then raw.note else nil,
		ExpiresAt = if type(raw.expiresAt) == "string" then raw.expiresAt else nil,
	}
	return table.freeze(entry) :: AllowlistEntry
end

-- Yields. Adds the user to one of this game's lists (already there: returns the current entry).
-- Returns (true, entry) or (false, error message).
function Allowlists.Allow(userId: number, key: string, options: any): (boolean, AllowlistEntry | string)
	local keyError = gameListError(key)
	if keyError then
		return false, keyError
	end
	local days: number? = nil
	local note: string? = nil
	if options ~= nil then
		if type(options) ~= "table" then
			return false, "options must be a table { DurationDays = number?, Note = string? }"
		end
		days = options.DurationDays
		if days ~= nil and (type(days) ~= "number" or days % 1 ~= 0 or days < 1 or days > MAX_DURATION_DAYS) then
			return false, `DurationDays must be a whole number from 1 to {MAX_DURATION_DAYS}, or nil for no end`
		end
		local rawNote = options.Note
		if rawNote ~= nil then
			local trimmed = if type(rawNote) == "string" then Util.Trim(rawNote) else nil
			local length = if trimmed then Util.Utf16Length(trimmed) else nil
			if trimmed == nil or length == nil or length > MAX_NOTE_LENGTH then
				return false, `Note must be text of up to {MAX_NOTE_LENGTH} characters`
			end
			note = if trimmed ~= "" then trimmed else nil
		end
	end

	local body = {
		robloxUserId = Util.FormatUserId(userId),
		durationDays = days, -- nil: no end
		note = note,
	}
	local response = Http.Request("POST", `{LISTS_PATH}/{key}/entries`, body, { MaxAttempts = 3 })
	if not response.Ok then
		local message = response.Error or "request failed"
		if not response.Warned then
			Log.Warn(`Allow of {userId} on "{key}" failed: {message}`)
		end
		return false, message
	end
	local entry = parseEntry(response.Data, key, userId)
	if not entry then
		return false, "unexpected response from the API"
	end
	Log.Debug(`{userId} is on "{key}": {entry.Id}`)
	lookup.Changed({ userId })
	return true, entry
end

-- Yields. Removes the user from one of this game's lists.
-- Returns (true, number of removed entries) or (false, error message).
function Allowlists.Disallow(userId: number, key: string): (boolean, number | string)
	local keyError = gameListError(key)
	if keyError then
		return false, keyError
	end
	local path = `{LISTS_PATH}/{key}/entries/{Util.FormatUserId(userId)}`
	local response = Http.Request("DELETE", path, nil, { MaxAttempts = 3 })
	if not response.Ok then
		local message = response.Error or "request failed"
		if not response.Warned then
			Log.Warn(`Disallow of {userId} on "{key}" failed: {message}`)
		end
		return false, message
	end
	-- The user may still be on a studio list with the same key; the re-check asks the API.
	lookup.Changed({ userId })
	local data = response.Data
	local removed = 0
	if type(data) == "table" and type(data.removed) == "number" then
		removed = data.removed
	end
	Log.Debug(`Removed {userId} from "{key}": {removed} entries`)
	return true, removed
end

-- From now on players who aren't on `key` are kicked: on join, and when a change or re-check shows
-- they're no longer on it. Checks the players already in the server too.
function Allowlists.Require(key: string, kickMessage: string?, allowTeam: boolean)
	gate = {
		Key = key,
		KickMessage = kickMessage or DEFAULT_GATE_MESSAGE,
		AllowTeam = allowTeam,
	}
	table.clear(gateRetries)
	for _, player in Players:GetPlayers() do
		checkGate(player)
	end
end

function Allowlists.Start()
	if started then
		return
	end
	started = true
	Team.OnRoleChanged(function(player)
		local current = gate
		if current and current.AllowTeam then
			checkGate(player)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		known[player.UserId] = nil
		gateStates[player] = nil
		gateRetries[player] = nil
		gateRetryPending[player] = nil
	end)
end

return Allowlists
