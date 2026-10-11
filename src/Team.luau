--!strict
-- Team roles: the owner of this game or of its studio, and the studio's team (admins, moderators,
-- members) as set on the site. Only people whose Roblox account is linked to RoVision have a role.
-- Checks go through Lookups (batched, prefetched on join, cached).
-- Fails closed: if the API can't be reached, nobody counts as a moderator or an admin.

local Players = game:GetService("Players")

local Log = require(script.Parent.Log)
local Lookups = require(script.Parent.Lookups)
local Signal = require(script.Parent.Signal)
local Types = require(script.Parent.Types)

type Role = Types.Role

local CHECK_PATH = "/game-api/v1/team/check"

-- A role has the permissions of the roles ranked below it. Unknown future roles grant nothing.
local RANKS: { [string]: number } = {
	member = 1,
	moderator = 2,
	admin = 3,
	owner = 4,
}

local Team = {}

Team.RoleChanged = Signal.new() :: Types.Signal<Player, Role?, Role?>

local known: { [number]: string } = {} -- UserId -> last role seen for a player in this server ("" = none)
local roleChangedHook: ((player: Player) -> ())? = nil
local started = false

-- Roles are kept as plain strings inside the module; unknown future roles are passed through.
local function parseRole(raw: any): string?
	if type(raw) == "table" and type(raw.role) == "string" then
		return raw.role
	end
	return nil
end

local function onAnswer(player: Player, ok: boolean, role: string?, _reason: Lookups.Reason)
	if not ok then
		return
	end
	local userId = player.UserId
	local previous = known[userId]
	local current = role or ""
	known[userId] = current
	if previous == nil or previous == current then
		return -- the first answer for this player, or nothing changed
	end
	local old = if previous ~= "" then previous else nil
	Log.Debug(`{player.Name} ({userId}) role: {old or "none"} -> {role or "none"}`)
	Team.RoleChanged:Fire(player, role :: Role?, old :: Role?)
	local hook = roleChangedHook
	if hook then
		hook(player)
	end
end

local config: Lookups.Config<string> = {
	Name = "Role check",
	Path = CHECK_PATH,
	Field = "members",
	Parse = parseRole,
	FailureNote = "Until it responds, IsModerator and IsAdmin return false.",
	OnAnswer = onAnswer,
}
local lookup: Lookups.Lookup<string> = Lookups.new(config)

-- Yields. Returns (true, role or nil) when known, (false, nil) when the API couldn't be reached.
function Team.GetRole(userId: number): (boolean, string?)
	return lookup.Check(userId)
end

-- Whether `role` has the permissions of `minimum` (e.g. "moderator": owner, admin or moderator).
function Team.AtLeast(role: string?, minimum: string): boolean
	local rank = if role then RANKS[role] else nil
	return rank ~= nil and rank >= RANKS[minimum]
end

-- Yields. For IsModerator and IsAdmin: fails closed (false, with a warning) when the API couldn't be reached.
function Team.Has(userId: number, minimum: string, method: string): boolean
	local ok, role = lookup.Check(userId)
	if not ok then
		Log.WarnThrottled(
			"role-unknown",
			60,
			`{method}: the role of {userId} is unknown (the RoVision API can't be reached), so the answer is false.`
		)
		return false
	end
	return Team.AtLeast(role, minimum)
end

-- The team roles of these users changed somewhere (a message from Live).
function Team.Changed(userIds: { number })
	lookup.Changed(userIds)
end

-- Internal: called after RoleChanged, for the RequireAllowed gate.
function Team.OnRoleChanged(callback: (player: Player) -> ())
	roleChangedHook = callback
end

function Team.Start()
	if started then
		return
	end
	started = true
	Players.PlayerRemoving:Connect(function(player)
		known[player.UserId] = nil
	end)
end

return Team
