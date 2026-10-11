--!strict
-- Batched, cached per-player lookups against the Game API: bans, team roles and whitelists.
-- Checks asked for within BATCH_WINDOW share one request per endpoint (up to 100 users each). All lookups
-- share the window, so a joining player costs one request per endpoint. This module also runs the
-- per-player checks: on join, on the periodic re-check, and shortly after a change message (Live).

local Players = game:GetService("Players")

local Http = require(script.Parent.Http)
local Log = require(script.Parent.Log)
local Util = require(script.Parent.Util)

local BATCH_WINDOW = 1 -- seconds to collect user ids into one request per endpoint
local MAX_IDS_PER_REQUEST = 100
local CACHE_TTL = 300
local RECHECK_MAX_AGE = 10 -- a periodic re-check reuses answers fetched this recently
local CHANGED_DELAY = 0.5 -- seconds to collect change messages into one re-check
local CHANGED_MIN_INTERVAL = 2 -- seconds between such re-checks, so a burst can't use up the request budget

-- Why a player is being checked.
export type Reason = "join" | "recheck" | "changed"

export type Config<T> = {
	Name: string, -- e.g. "Ban check"; starts the warnings
	Path: string,
	Field: string, -- the response object that maps UserIds to values
	Parse: (raw: any) -> T?, -- nil drops a malformed value
	FailureNote: string, -- what happens while the API can't be reached
	-- Gets every answer for a player in this server: on join, on a periodic re-check, after a change message.
	OnAnswer: (player: Player, ok: boolean, value: T?, reason: Reason) -> (),
}

export type Lookup<T> = {
	-- Yields. (true, value) when known (nil: the user has none), (false, nil) when the API couldn't be reached.
	Check: (userId: number, maxAge: number?) -> (boolean, T?),
	-- An answer known from a local change (e.g. RoVision:Ban). Answers already in flight are discarded.
	Set: (userId: number, value: T?) -> (),
	-- The data changed; the next check asks the API. Answers already in flight are discarded.
	Forget: (userId: number) -> (),
	-- A change message: forgets these users' answers at once; the ones in this server are re-checked shortly,
	-- bypassing the cache. Messages that arrive close together share one check.
	Changed: (userIds: { number }) -> (),
}

type Entry<T> = {
	Value: T?,
	FetchedAt: number,
}

type Flight = {
	Threads: { thread }, -- also the waiting list of the batch, so threads can join it
	RequestedAt: number,
}

type Internal = {
	Flush: () -> (),
	Prune: (now: number) -> (),
	CheckPlayer: (player: Player, reason: Reason, maxAge: number?) -> (),
	TakeChanged: () -> { number },
}

local Lookups = {}

local registry: { Internal } = {}
local flushTimer: thread? = nil -- sends the waiting batches at the end of BATCH_WINDOW
local changedScheduled = false
local changedRecheckAt = -math.huge
local started = false

-- Reasons as typed values (string literals lose their type when passed through task.spawn).
local JOIN: Reason = "join"
local RECHECK: Reason = "recheck"
local CHANGED: Reason = "changed"

local function flushAll()
	flushTimer = nil
	for _, lookup in registry do
		lookup.Flush()
	end
end

local function scheduleFlush()
	if not flushTimer then
		flushTimer = task.delay(BATCH_WINDOW, flushAll)
	end
end

-- Sends the waiting batches now instead of at the end of BATCH_WINDOW.
local function flushNow()
	local timer = flushTimer
	if timer then
		task.cancel(timer)
	end
	flushAll()
end

local function recheckChanged()
	changedScheduled = false
	changedRecheckAt = os.clock()
	local count = 0
	for _, lookup in registry do
		for _, userId in lookup.TakeChanged() do
			local player = Players:GetPlayerByUserId(userId)
			if player then
				count += 1
				task.spawn(lookup.CheckPlayer, player, CHANGED, 0) -- joins the waiting batch
			end
		end
	end
	if count > 0 then
		Log.Debug(`Re-checking {count} answer(s) for players in this server after a change.`)
		flushNow() -- one request per endpoint, together with any other checks waiting
	end
end

local function scheduleChanged()
	if not changedScheduled then
		changedScheduled = true
		task.delay(math.max(CHANGED_DELAY, changedRecheckAt + CHANGED_MIN_INTERVAL - os.clock()), recheckChanged)
	end
end

local function resume(thread: thread, ok: boolean, value: any)
	if coroutine.status(thread) == "suspended" then
		task.spawn(thread, ok, value)
	end
end

function Lookups.new<T>(config: Config<T>): Lookup<T>
	local cache: { [number]: Entry<T> } = {}
	local waiting: { [number]: { thread } } = {} -- UserId -> threads waiting for the next batch
	local inFlight: { [number]: Flight } = {} -- UserId -> the latest request on its way
	-- UserId -> when this server last learned that the user's data changed (locally or from a message).
	local changedAt: { [number]: number } = {}
	local changedUsers: { [number]: true } = {} -- UserIds from change messages, waiting for a re-check

	-- One request for up to 100 users. Returns UserId -> value, or nil on failure.
	local function fetch(userIds: { number }): { [number]: T }?
		local ids = table.create(#userIds)
		for index, userId in userIds do
			ids[index] = Util.FormatUserId(userId)
		end
		local response = Http.Request("POST", config.Path, { robloxUserIds = ids })
		if not response.Ok then
			if not response.Warned then
				Log.WarnThrottled(
					`{config.Name}-failed`,
					300,
					`{config.Name} failed ({response.Error}). {config.FailureNote}`
				)
			end
			return nil
		end
		local data = response.Data
		local map = if type(data) == "table" then data[config.Field] else nil
		if type(map) ~= "table" then
			Log.WarnThrottled(`{config.Name}-response`, 300, `{config.Name}: unexpected response. {config.FailureNote}`)
			return nil
		end
		local result: { [number]: T } = {}
		for key, raw in map do
			local userId = tonumber(key)
			local value = config.Parse(raw)
			if userId and value ~= nil then
				result[userId] = value
			end
		end
		return result
	end

	-- Adds threads to a request sent after the user's last change: the one in flight, or the next batch.
	local function enqueue(userId: number, threads: { thread })
		local flight = inFlight[userId]
		local changed = changedAt[userId]
		local list: { thread }
		if flight and not (changed and changed >= flight.RequestedAt) then
			list = flight.Threads
		else
			list = waiting[userId] or {}
			waiting[userId] = list
			scheduleFlush()
		end
		table.move(threads, 1, #threads, #list + 1, list)
	end

	local function fetchChunk(userIds: { number }, batch: { [number]: { thread } })
		local requestedAt = os.clock()
		for _, userId in userIds do
			inFlight[userId] = { Threads = batch[userId], RequestedAt = requestedAt }
		end
		local fetched, result = pcall(fetch, userIds)
		if not fetched then
			Log.Warn(`{config.Name} error: {result}`)
		end
		-- Every waiting thread is resumed (or handed to a newer request) below, whatever happened above.
		local values = if fetched then result else nil
		for _, userId in userIds do
			local threads = batch[userId]
			local flight = inFlight[userId]
			if flight and flight.Threads == threads then
				inFlight[userId] = nil
			end
			local ok = values ~= nil
			local value = if values then values[userId] else nil
			local changed = changedAt[userId]
			if changed and changed >= requestedAt then
				-- The data changed while this request was in flight, so its answer may be out of date.
				local current = cache[userId]
				if current == nil then
					enqueue(userId, threads) -- wait for a request sent after the change
					continue
				end
				value = current.Value -- the newer answer is already known
				ok = true
			elseif ok then
				cache[userId] = { Value = value, FetchedAt = os.clock() }
			end
			for _, thread in threads do
				resume(thread, ok, value)
			end
		end
	end

	local function flush()
		local batch = waiting
		waiting = {}
		local userIds: { number } = {}
		for userId in batch do
			table.insert(userIds, userId)
		end
		for first = 1, #userIds, MAX_IDS_PER_REQUEST do
			local last = math.min(first + MAX_IDS_PER_REQUEST - 1, #userIds)
			task.spawn(fetchChunk, table.move(userIds, first, last, 1, {}), batch)
		end
	end

	local function check(userId: number, maxAge: number?): (boolean, T?)
		if userId <= 0 then
			return true, nil -- Studio test players have negative ids
		end
		local entry = cache[userId]
		if entry and os.clock() - entry.FetchedAt < (maxAge or CACHE_TTL) then
			return true, entry.Value
		end
		enqueue(userId, { coroutine.running() })
		local ok: boolean, value: T? = coroutine.yield()
		return ok, value
	end

	local function setValue(userId: number, value: T?)
		changedAt[userId] = os.clock()
		cache[userId] = { Value = value, FetchedAt = os.clock() }
	end

	local function forget(userId: number)
		changedAt[userId] = os.clock()
		cache[userId] = nil
	end

	local function markChanged(userIds: { number })
		local inServer = false
		for _, userId in userIds do
			forget(userId)
			if Players:GetPlayerByUserId(userId) then
				changedUsers[userId] = true
				inServer = true
			end
		end
		if inServer then
			scheduleChanged()
		end
	end

	local function checkPlayer(player: Player, reason: Reason, maxAge: number?)
		local ok, value = check(player.UserId, maxAge)
		if player.Parent == Players then
			config.OnAnswer(player, ok, value, reason)
		end
	end

	local function takeChanged(): { number }
		local userIds: { number } = {}
		for userId in changedUsers do
			table.insert(userIds, userId)
		end
		table.clear(changedUsers)
		return userIds
	end

	local function prune(now: number)
		for userId, entry in cache do
			if now - entry.FetchedAt > CACHE_TTL then
				cache[userId] = nil
			end
		end
		for userId, at in changedAt do
			if now - at > CACHE_TTL then
				changedAt[userId] = nil
			end
		end
	end

	table.insert(registry, {
		Flush = flush,
		Prune = prune,
		CheckPlayer = checkPlayer,
		TakeChanged = takeChanged,
	})
	local lookup: Lookup<T> = {
		Check = check,
		Set = setValue,
		Forget = forget,
		Changed = markChanged,
	}
	return lookup
end

local function checkAll(player: Player, reason: Reason, maxAge: number?)
	for _, lookup in registry do
		task.spawn(lookup.CheckPlayer, player, reason, maxAge)
	end
end

local function recheckLoop(interval: number)
	while true do
		-- Jitter, so servers started together don't call the API in sync.
		task.wait(interval * (0.9 + math.random() * 0.2))
		local now = os.clock()
		for _, lookup in registry do
			lookup.Prune(now)
		end
		for _, player in Players:GetPlayers() do
			checkAll(player, RECHECK, RECHECK_MAX_AGE)
		end
	end
end

-- Checks every player with every lookup on join and every `recheckInterval` seconds.
function Lookups.Start(recheckInterval: number)
	if started then
		return
	end
	started = true
	Players.PlayerAdded:Connect(function(player)
		checkAll(player, JOIN, nil)
	end)
	for _, player in Players:GetPlayers() do
		checkAll(player, JOIN, nil)
	end
	task.spawn(recheckLoop, recheckInterval)
end

return Lookups
