--!strict
-- Public types and shared constants.

-- "rovision": network-wide ban issued by RoVision moderators.
-- "studio": ban issued by the studio this game is credited to.
-- "game": ban issued for this game (on the site or through RoVision:Ban).
export type BanScope = "rovision" | "studio" | "game"

export type BanCategory = "exploiting" | "scamming" | "botting" | "other"

-- Categories accepted by RoVision:Report (network bans only).
export type ReportCategory = "exploiting" | "scamming" | "botting"

export type Ban = {
	Id: string,
	Scope: BanScope,
	Category: BanCategory,
	Reason: string,
	ExpiresAt: string?, -- ISO 8601 (UTC); nil = permanent
}

-- A fixed text, or a function that builds one (return nil to use the default message).
export type KickMessage = string | ((ban: Ban) -> string?)

export type BansOptions = {
	Enforce: boolean?,
	KickMessage: KickMessage?,
	RecheckInterval: number?,
	Live: boolean?, -- ban, team and whitelist changes reach every server through MessagingService (default true)
}

export type InitOptions = {
	ApiKey: (Secret | string)?,
	BaseUrl: string?,
	Debug: boolean?,
	Bans: BansOptions?,
}

export type BanOptions = {
	Reason: string,
	DurationDays: number?, -- nil = permanent
	Category: BanCategory?,
}

-- "owner": the owner of this game or of the studio it's credited to.
-- "admin", "moderator", "member": the studio's team, as set on the site.
export type Role = "owner" | "admin" | "moderator" | "member"

export type AllowOptions = {
	DurationDays: number?, -- nil = no end
	Note: string?,
}

-- A player's entry on one of this game's whitelists (RoVision:Allow).
export type AllowlistEntry = {
	Id: string,
	Key: string,
	UserId: number,
	Username: string?,
	Note: string?,
	ExpiresAt: string?, -- ISO 8601 (UTC); nil = no end
}

export type RequireAllowedOptions = {
	KickMessage: string?,
	AllowOwnersAndTeam: boolean?, -- owners, admins and moderators pass too (default true)
}

export type ReportOptions = {
	Category: ReportCategory,
	Description: string,
	Detection: { [any]: any }?,
}

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Signal<T...> = {
	Connect: (self: Signal<T...>, callback: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, callback: (T...) -> ()) -> Connection,
	Wait: (self: Signal<T...>) -> T...,
	Fire: (self: Signal<T...>, T...) -> (),
	DisconnectAll: (self: Signal<T...>) -> (),
}

local Types = {}

local banCategories: { [string]: boolean } = {
	exploiting = true,
	scamming = true,
	botting = true,
	other = true,
}
Types.BanCategories = table.freeze(banCategories)

local reportCategories: { [string]: boolean } = {
	exploiting = true,
	scamming = true,
	botting = true,
}
Types.ReportCategories = table.freeze(reportCategories)

return Types
