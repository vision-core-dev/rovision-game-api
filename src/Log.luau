--!strict
-- Output helpers. Everything is prefixed with [RoVision].

local PREFIX = "[RoVision] "

local Log = {}

local debugEnabled = false
local warnedOnce: { [string]: true } = {}
local lastWarnedAt: { [string]: number } = {}

function Log.SetDebug(enabled: boolean)
	debugEnabled = enabled
end

function Log.IsDebug(): boolean
	return debugEnabled
end

-- Verbose output, only with Debug = true.
function Log.Debug(message: string)
	if debugEnabled then
		print(PREFIX .. message)
	end
end

function Log.Warn(message: string)
	warn(PREFIX .. message)
end

-- Warns once per server for the given key.
function Log.WarnOnce(key: string, message: string)
	if warnedOnce[key] then
		Log.Debug(message)
		return
	end
	warnedOnce[key] = true
	Log.Warn(message)
end

-- Warns at most once per `interval` seconds for the given key.
function Log.WarnThrottled(key: string, interval: number, message: string)
	local now = os.clock()
	local last = lastWarnedAt[key]
	if last and now - last < interval then
		Log.Debug(message)
		return
	end
	lastWarnedAt[key] = now
	Log.Warn(message)
end

return Log
