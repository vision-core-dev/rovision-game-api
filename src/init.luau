--!strict
-- RoVision game module (server only). Docs: https://github.com/vision-core-dev/rovision-game-api

local RunService = game:GetService("RunService")

if not RunService:IsServer() then
	error("[RoVision] RoVision runs only on the server. Keep it in ServerScriptService; require it from a Script.", 0)
end

local HttpService = game:GetService("HttpService")

-- Bans first: lookups are batched in the order they are created, so ban checks go out first.
local Bans = require(script.Bans)
local Allowlists = require(script.Allowlists)
local Http = require(script.Http)
local Live = require(script.Live)
local Log = require(script.Log)
local Lookups = require(script.Lookups)
local Reports = require(script.Reports)
local Team = require(script.Team)
local Types = require(script.Types)
local Util = require(script.Util)

export type Ban = Types.Ban
export type BanScope = Types.BanScope
export type BanCategory = Types.BanCategory
export type ReportCategory = Types.ReportCategory
export type InitOptions = Types.InitOptions
export type BansOptions = Types.BansOptions
export type BanOptions = Types.BanOptions
export type ReportOptions = Types.ReportOptions
export type Role = Types.Role
export type AllowOptions = Types.AllowOptions
export type AllowlistEntry = Types.AllowlistEntry
export type RequireAllowedOptions = Types.RequireAllowedOptions
export type Connection = Types.Connection
export type Signal<T...> = Types.Signal<T...>

local VERSION = "1.0.0"
local DEFAULT_BASE_URL = "https://api.rovision.gg"
local SECRET_NAME = "rovision"
local DEFAULT_RECHECK_INTERVAL = 300
local MIN_RECHECK_INTERVAL = 60
local CLOSE_TIMEOUT = 10 -- seconds of the 30 s BindToClose budget

local KNOWN_OPTIONS = { ApiKey = true, BaseUrl = true, Debug = true, Bans = true }
local KNOWN_BANS_OPTIONS = { Enforce = true, KickMessage = true, RecheckInterval = true, Live = true }
local KNOWN_GATE_OPTIONS = { KickMessage = true, AllowOwnersAndTeam = true }

local RoVision = {}

RoVision.Version = VERSION

-- Fires with (player, ban) when a player in this server has an active ban that applies to this game:
-- on join, on a periodic re-check, after RoVision:Ban, or when a ban change arrives from the site or
-- another server (Bans.Live). Fires before the kick (Enforce = true), and is the place for custom
-- handling when Enforce = false.
RoVision.PlayerBanned = Bans.PlayerBanned

-- Fires with (player, newRole, oldRole) when a re-check or a live update shows that the team role of a
-- player in this server changed. A role is nil when the player isn't on the team.
RoVision.RoleChanged = Team.RoleChanged

-- Fires with (player, lists) when a re-check or a live update shows that the whitelists a player in this
-- server is on changed. `lists` holds all their keys.
RoVision.ListsChanged = Allowlists.ListsChanged

local initialized = false

local function invalidArgument(method: string, name: string, expected: string, value: any): never
	error(`[RoVision] {method}: {name} must be {expected}, got {typeof(value)}.`, 0)
end

local function invalidOption(name: string, expected: string, value: any): never
	return invalidArgument("Init", name, expected, value)
end

local function warnUnknown(method: string, options: { [any]: any }, known: { [string]: boolean }, prefix: string)
	for key in options do
		if not known[key] then
			Log.Warn(`{method}: unknown option {prefix}{tostring(key)} is ignored.`)
		end
	end
end

-- Returns the Authorization header value, or nil when there is no usable key.
local function resolveAuthorization(apiKey: any): (string | Secret)?
	if apiKey == nil then
		local ok, secret = pcall(HttpService.GetSecret, HttpService, SECRET_NAME)
		if ok then
			return secret:AddPrefix("Bearer ")
		end
		Log.Warn(
			`No API key: the secret "{SECRET_NAME}" can't be read ({secret}). Add it in Creator Dashboard → `
				.. "your experience → Secrets (Studio uses its own local secrets), or pass ApiKey to Init. "
				.. "Until then ban checks are off and players are let in; "
				.. "IsModerator, IsAdmin and IsAllowed return false."
		)
		return nil
	end
	if typeof(apiKey) == "Secret" then
		return (apiKey :: Secret):AddPrefix("Bearer ")
	end
	if type(apiKey) == "string" then
		local key = Util.Trim(apiKey)
		if key == "" then
			Log.Warn(
				"ApiKey is an empty string. Until a key is set ban checks are off and players are let in; "
					.. "IsModerator, IsAdmin and IsAllowed return false."
			)
			return nil
		end
		if string.sub(key, 1, 3) ~= "rv_" then
			Log.Warn("ApiKey doesn't look like a RoVision key (rv_live_…).")
		end
		if not RunService:IsStudio() then
			Log.Warn(
				"ApiKey is a plain string in a live server: anyone with a copy of the place can read it. "
					.. `Store it in Secrets and pass HttpService:GetSecret("{SECRET_NAME}").`
			)
		end
		return "Bearer " .. key
	end
	return invalidOption("ApiKey", "a Secret or a string", apiKey)
end

--[[
	Starts the module. Call once per server, from a server Script, before other methods.
	Doesn't yield. Invalid option types throw; a missing key only warns (the module then lets everyone in).
]]
function RoVision:Init(options: InitOptions?)
	if initialized then
		Log.Warn("Init was already called; this call is ignored.")
		return
	end
	local raw: any = if options == nil then {} else options
	if type(raw) ~= "table" then
		invalidOption("options", "a table", raw)
	end
	warnUnknown("Init", raw, KNOWN_OPTIONS, "")

	local baseUrl = raw.BaseUrl
	if baseUrl == nil then
		baseUrl = DEFAULT_BASE_URL
	elseif type(baseUrl) ~= "string" or not string.match(baseUrl, "^https?://") then
		invalidOption("BaseUrl", "a URL string starting with https://", baseUrl)
	end

	local debugMode = raw.Debug
	if debugMode == nil then
		debugMode = false
	elseif type(debugMode) ~= "boolean" then
		invalidOption("Debug", "a boolean", debugMode)
	end

	local bansOptions = raw.Bans
	if bansOptions == nil then
		bansOptions = {}
	elseif type(bansOptions) ~= "table" then
		invalidOption("Bans", "a table", bansOptions)
	end
	warnUnknown("Init", bansOptions, KNOWN_BANS_OPTIONS, "Bans.")

	local enforce = bansOptions.Enforce
	if enforce == nil then
		enforce = true
	elseif type(enforce) ~= "boolean" then
		invalidOption("Bans.Enforce", "a boolean", enforce)
	end

	local kickMessage = bansOptions.KickMessage
	if kickMessage ~= nil and type(kickMessage) ~= "string" and type(kickMessage) ~= "function" then
		invalidOption("Bans.KickMessage", "a string or a function(ban): string", kickMessage)
	end

	local recheckInterval = bansOptions.RecheckInterval
	if recheckInterval == nil then
		recheckInterval = DEFAULT_RECHECK_INTERVAL
	elseif type(recheckInterval) ~= "number" or recheckInterval ~= recheckInterval or recheckInterval == math.huge then
		invalidOption("Bans.RecheckInterval", "a number of seconds", recheckInterval)
	elseif recheckInterval < MIN_RECHECK_INTERVAL then
		Log.Warn(`Bans.RecheckInterval is raised to the minimum of {MIN_RECHECK_INTERVAL} seconds.`)
		recheckInterval = MIN_RECHECK_INTERVAL
	end

	local live = bansOptions.Live
	if live == nil then
		live = true
	elseif type(live) ~= "boolean" then
		invalidOption("Bans.Live", "a boolean", live)
	end

	Log.SetDebug(debugMode)
	local authorization = resolveAuthorization(raw.ApiKey)

	initialized = true
	Http.Configure(baseUrl, authorization, VERSION)
	Bans.Start({ Enforce = enforce, KickMessage = kickMessage })
	Team.Start()
	Allowlists.Start()
	Lookups.Start(recheckInterval)
	-- Without a key nothing can be re-checked, so there is no point in listening.
	if live and authorization ~= nil then
		Live.Start({
			bans_changed = Bans.Changed,
			team_changed = Team.Changed,
			allowlists_changed = Allowlists.Changed,
		})
	end
	game:BindToClose(function()
		Live.Stop()
		Reports.Flush(CLOSE_TIMEOUT)
	end)
	Log.Debug(
		`v{VERSION} started: {baseUrl}, Enforce = {enforce}, RecheckInterval = {recheckInterval} s, Live = {live}`
	)
end

--[[
	Returns the active ban that applies to this game, or nil. Yields (batched with other
	checks, ~1 s; cached for 5 minutes or until a ban change arrives). The second value is false
	when the API couldn't be reached; then the first is nil.
]]
function RoVision:CheckBan(target: Player | number): (Ban?, boolean)
	if not initialized then
		Log.Warn("CheckBan: call RoVision:Init first.")
		return nil, false
	end
	local userId = Util.UserIdOf(target)
	if not userId then
		Log.Warn(`CheckBan: expected a Player or a UserId, got {typeof(target)}.`)
		return nil, false
	end
	local ok, ban = Bans.Check(userId)
	return ban, ok
end

--[[
	Bans a player in this game (game scope), e.g. from an admin command. Yields.
	Kicks the player if they are in this server (unless Bans.Enforce = false) and fires PlayerBanned;
	the game's other servers learn about the ban within seconds (Bans.Live).
	Returns (true, ban) or (false, error message). Check that the caller is allowed to ban first!
]]
function RoVision:Ban(target: Player | number, options: BanOptions): (boolean, Ban | string)
	if not initialized then
		Log.Warn("Ban: call RoVision:Init first.")
		return false, "RoVision:Init was not called"
	end
	local userId = Util.UserIdOf(target)
	if not userId or userId <= 0 then
		return false, "expected a Player or a positive UserId"
	end
	local ok, result = Bans.Ban(userId, options)
	if ok then
		Live.Announce("bans_changed", userId)
	end
	return ok, result
end

--[[
	Lifts this game's game-scope bans of a user. Yields. Studio and RoVision bans are not affected.
	The game's other servers learn about it within seconds (Bans.Live).
	Returns (true, number of lifted bans) or (false, error message).
]]
function RoVision:Unban(target: Player | number): (boolean, number | string)
	if not initialized then
		Log.Warn("Unban: call RoVision:Init first.")
		return false, "RoVision:Init was not called"
	end
	local userId = Util.UserIdOf(target)
	if not userId or userId <= 0 then
		return false, "expected a Player or a positive UserId"
	end
	local ok, result = Bans.Unban(userId)
	if ok then
		Live.Announce("bans_changed", userId)
	end
	return ok, result
end

--[[
	Sends a report to RoVision moderators (for a network ban), e.g. from an anti-cheat.
	Never yields: the report is queued and sent in the background. Nobody is banned
	automatically; a moderator reviews every report. Returns true if the report was queued.
]]
function RoVision:Report(target: Player | number, report: ReportOptions): boolean
	if not initialized then
		Log.Warn("Report: call RoVision:Init first.")
		return false
	end
	local userId = Util.UserIdOf(target)
	if not userId then
		Log.Warn(`Report: expected a Player or a UserId, got {typeof(target)}.`)
		return false
	end
	if userId <= 0 then
		Log.Debug(`Report about test player {userId} skipped.`)
		return false
	end
	return Reports.Enqueue(userId, report)
end

---------------------------------------------------------------------------
-- Team roles

--[[
	Returns the player's team role in this game, or nil: not on the team, or the Roblox account isn't
	linked to RoVision. Yields (prefetched on join, so usually instant; cached for 5 minutes or until a
	team change arrives). The second value is false when the API couldn't be reached.
]]
function RoVision:GetRole(target: Player | number): (Role?, boolean)
	if not initialized then
		Log.Warn("GetRole: call RoVision:Init first.")
		return nil, false
	end
	local userId = Util.UserIdOf(target)
	if not userId then
		Log.Warn(`GetRole: expected a Player or a UserId, got {typeof(target)}.`)
		return nil, false
	end
	local ok, role = Team.GetRole(userId)
	return role :: Role?, ok
end

local function hasRole(method: string, target: any, minimum: string): boolean
	if not initialized then
		Log.Warn(`{method}: call RoVision:Init first.`)
		return false
	end
	local userId = Util.UserIdOf(target)
	if not userId then
		Log.Warn(`{method}: expected a Player or a UserId, got {typeof(target)}.`)
		return false
	end
	return Team.Has(userId, minimum, method)
end

--[[
	Whether the player is the owner, an admin or a moderator of this game's team. Yields like GetRole.
	Fails closed: false (with a warning) when the API couldn't be reached.
]]
function RoVision:IsModerator(target: Player | number): boolean
	return hasRole("IsModerator", target, "moderator")
end

--[[
	Whether the player is the owner or an admin of this game's team. Yields like GetRole.
	Fails closed: false (with a warning) when the API couldn't be reached.
]]
function RoVision:IsAdmin(target: Player | number): boolean
	return hasRole("IsAdmin", target, "admin")
end

---------------------------------------------------------------------------
-- Whitelists

-- Normalized list key, or nil (with a warning once per key).
local function listKey(method: string, key: any): string?
	local normalized = Allowlists.NormalizeKey(key)
	if not normalized then
		Log.WarnOnce(
			`bad-key:{tostring(key)}`,
			`{method}: "{tostring(key)}" isn't a list key `
				.. '(2-32 of a-z, 0-9, - and _; "rovision:<key>" for RoVision lists).'
		)
	end
	return normalized
end

--[[
	Whether the player is on the list `key`: this game's or its studio's list, or "rovision:<key>" for a
	RoVision-wide list. Yields (prefetched on join; cached for 5 minutes or until a change arrives).
	Fails closed: (false, false) when the API couldn't be reached; the second value is whether it answered.
]]
function RoVision:IsAllowed(target: Player | number, key: string): (boolean, boolean)
	if not initialized then
		Log.Warn("IsAllowed: call RoVision:Init first.")
		return false, false
	end
	local userId = Util.UserIdOf(target)
	if not userId then
		Log.Warn(`IsAllowed: expected a Player or a UserId, got {typeof(target)}.`)
		return false, false
	end
	local list = listKey("IsAllowed", key)
	if not list then
		return false, true -- no list can have this key
	end
	return Allowlists.IsAllowed(userId, list)
end

--[[
	All list keys the player is on, sorted. Yields like IsAllowed.
	The second value is false when the API couldn't be reached; then the list is empty.
]]
function RoVision:GetLists(target: Player | number): ({ string }, boolean)
	if not initialized then
		Log.Warn("GetLists: call RoVision:Init first.")
		return {}, false
	end
	local userId = Util.UserIdOf(target)
	if not userId then
		Log.Warn(`GetLists: expected a Player or a UserId, got {typeof(target)}.`)
		return {}, false
	end
	return Allowlists.GetLists(userId)
end

--[[
	Adds a player to one of this game's own lists (not studio or RoVision lists), e.g. from an admin
	command. Yields. Other servers learn about it within seconds (Bans.Live).
	Returns (true, entry) or (false, error message). Check that the caller is allowed to do this first!
]]
function RoVision:Allow(
	target: Player | number,
	key: string,
	options: AllowOptions?
): (boolean, AllowlistEntry | string)
	if not initialized then
		Log.Warn("Allow: call RoVision:Init first.")
		return false, "RoVision:Init was not called"
	end
	local userId = Util.UserIdOf(target)
	if not userId or userId <= 0 then
		return false, "expected a Player or a positive UserId"
	end
	local list = listKey("Allow", key)
	if not list then
		return false, `"{tostring(key)}" isn't a list key`
	end
	local ok, result = Allowlists.Allow(userId, list, options)
	if ok then
		Live.Announce("allowlists_changed", userId)
	end
	return ok, result
end

--[[
	Removes a player from one of this game's own lists. Yields. Other servers learn about it within
	seconds (Bans.Live). Returns (true, number of removed entries) or (false, error message).
]]
function RoVision:Disallow(target: Player | number, key: string): (boolean, number | string)
	if not initialized then
		Log.Warn("Disallow: call RoVision:Init first.")
		return false, "RoVision:Init was not called"
	end
	local userId = Util.UserIdOf(target)
	if not userId or userId <= 0 then
		return false, "expected a Player or a positive UserId"
	end
	local list = listKey("Disallow", key)
	if not list then
		return false, `"{tostring(key)}" isn't a list key`
	end
	local ok, result = Allowlists.Disallow(userId, list)
	if ok then
		Live.Announce("allowlists_changed", userId)
	end
	return ok, result
end

--[[
	A gate for closed tests and private servers: from now on, players who aren't on the list `key` are
	kicked on join, and when a change or a re-check shows they're no longer on it. With AllowOwnersAndTeam
	(default true) the owners and the team's admins and moderators pass too. While the API can't be
	reached, players stay and are checked again; only a definite "not on the list" kicks. Studio test
	players (negative UserIds) always pass. Call after Init; invalid arguments throw. Doesn't yield.
]]
function RoVision:RequireAllowed(key: string, options: RequireAllowedOptions?)
	if not initialized then
		error("[RoVision] RequireAllowed: call RoVision:Init first.", 0)
	end
	local list = Allowlists.NormalizeKey(key)
	if not list then
		error(
			`[RoVision] RequireAllowed: "{tostring(key)}" isn't a list key `
				.. '(2-32 of a-z, 0-9, - and _; "rovision:<key>" for RoVision lists).',
			0
		)
	end
	local raw: any = if options == nil then {} else options
	if type(raw) ~= "table" then
		invalidArgument("RequireAllowed", "options", "a table", raw)
	end
	warnUnknown("RequireAllowed", raw, KNOWN_GATE_OPTIONS, "")

	local kickMessage = raw.KickMessage
	if kickMessage ~= nil and (type(kickMessage) ~= "string" or Util.Trim(kickMessage) == "") then
		invalidArgument("RequireAllowed", "KickMessage", "a non-empty string", kickMessage)
	end
	local allowTeam = raw.AllowOwnersAndTeam
	if allowTeam == nil then
		allowTeam = true
	elseif type(allowTeam) ~= "boolean" then
		invalidArgument("RequireAllowed", "AllowOwnersAndTeam", "a boolean", allowTeam)
	end

	Allowlists.Require(list :: string, kickMessage, allowTeam)
	Log.Debug(`RequireAllowed: players need "{list}"{if allowTeam then " (the team passes)" else ""}.`)
end

return RoVision
