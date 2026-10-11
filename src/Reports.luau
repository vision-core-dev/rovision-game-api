--!strict
-- Anti-cheat reports to RoVision moderators (POST /game-api/v1/reports).
-- Report() only queues; a background worker sends, and the queue is flushed on shutdown.

local HttpService = game:GetService("HttpService")

local Http = require(script.Parent.Http)
local Log = require(script.Parent.Log)
local Types = require(script.Parent.Types)
local Util = require(script.Parent.Util)

local REPORTS_PATH = "/game-api/v1/reports"
local MAX_DESCRIPTION = 1000
local MAX_DETECTION_BYTES = 8000 -- the API allows 8 KB of JSON; keep a margin
local MAX_JOB_ID = 100
local MAX_QUEUE = 100
-- At most one send per player and category in this window; calls in between update the queued report.
local COOLDOWN = 30

type Item = {
	Key: string,
	UserId: number,
	Category: Types.ReportCategory,
	Description: string,
	Detection: any,
	NotBefore: number,
}

local Reports = {}

local queue: { Item } = {}
local queuedByKey: { [string]: Item } = {}
local sentAt: { [string]: number } = {}
local workerRunning = false
local inFlight = 0
local closeDeadline: number? = nil

-- Validates Detection and returns an independent copy that fits the API limits (nil = don't send).
local function snapshotDetection(detection: any): any
	if detection == nil then
		return nil
	end
	if type(detection) ~= "table" then
		Log.WarnThrottled("report-detection", 60, "Report: Detection must be a table; it was left out.")
		return nil
	end
	local ok, json = pcall(HttpService.JSONEncode, HttpService, detection)
	if not ok then
		Log.WarnThrottled("report-detection", 60, `Report: Detection can't be converted to JSON ({json}); left out.`)
		return nil
	end
	if json == "[]" or json == "{}" then
		return nil
	end
	if #json > MAX_DETECTION_BYTES then
		Log.WarnThrottled(
			"report-detection-size",
			60,
			`Report: Detection is {#json} bytes as JSON (limit 8 KB); only a "truncated" note was sent.`
		)
		return { truncated = true, originalBytes = #json }
	end
	-- A decoded copy, so later changes to the caller's table don't leak into the queued report.
	local decoded, copy = pcall(HttpService.JSONDecode, HttpService, json)
	if not decoded then
		Log.WarnThrottled("report-detection", 60, "Report: Detection isn't valid JSON (NaN or infinity?); left out.")
		return nil
	end
	-- The API expects a JSON object; wrap arrays.
	if string.sub(json, 1, 1) == "[" then
		return { items = copy }
	end
	return copy
end

local function send(item: Item): boolean
	local jobId = game.JobId
	local body = {
		robloxUserId = Util.FormatUserId(item.UserId),
		category = item.Category,
		description = item.Description,
		detection = item.Detection,
		jobId = if jobId ~= "" then string.sub(jobId, 1, MAX_JOB_ID) else nil, -- empty in Studio
	}
	local response = Http.Request("POST", REPORTS_PATH, body, { Deadline = closeDeadline })
	if response.Ok then
		local id = if type(response.Data) == "table" then response.Data.id else nil
		Log.Debug(`Report about {item.UserId} ({item.Category}) received: {tostring(id)}`)
	elseif not response.Warned then
		Log.WarnThrottled("report-failed", 60, `Could not send a report about {item.UserId}: {response.Error}`)
	end
	return response.Ok
end

local function sendTracked(item: Item)
	sentAt[item.Key] = os.clock()
	inFlight += 1
	local ok, result = pcall(send, item)
	inFlight -= 1
	if not ok then
		Log.Warn(`Report about {item.UserId} failed: {tostring(result)}`)
	end
end

local function take(index: number): Item
	local item = table.remove(queue, index) :: Item
	queuedByKey[item.Key] = nil
	return item
end

local function worker()
	while #queue > 0 do
		local now = os.clock()
		local readyIndex: number? = nil
		local earliest = math.huge
		for index, item in queue do
			if closeDeadline ~= nil or item.NotBefore <= now then
				readyIndex = index
				break
			end
			earliest = math.min(earliest, item.NotBefore)
		end
		if readyIndex then
			sendTracked(take(readyIndex)) -- one at a time; the queue is small and rarely busy
		else
			-- Short slices, so a shutdown flush doesn't wait out a cooldown.
			task.wait(math.clamp(earliest - now, 0.1, 1))
		end
	end
	workerRunning = false
end

-- Never yields. Returns true if the report was queued.
function Reports.Enqueue(userId: number, report: any): boolean
	if type(report) ~= "table" then
		Log.Warn("Report: expected a table { Category = string, Description = string, Detection = table? }.")
		return false
	end
	local category = report.Category
	if type(category) ~= "string" or not Types.ReportCategories[category] then
		Log.Warn(`Report: Category must be "exploiting", "scamming" or "botting", got {tostring(category)}.`)
		return false
	end
	if type(report.Description) ~= "string" then
		Log.Warn("Report: Description must be a string.")
		return false
	end
	local description = Util.Trim(report.Description)
	local length = Util.Utf16Length(description)
	if length == nil then
		Log.Warn("Report: Description isn't valid UTF-8 text.")
		return false
	elseif length == 0 then
		Log.Warn("Report: Description is empty.")
		return false
	elseif length > MAX_DESCRIPTION then
		description = Util.TruncateUtf16(description, MAX_DESCRIPTION)
		Log.Debug(`Report: Description cut to {MAX_DESCRIPTION} characters.`)
	end
	local detection = snapshotDetection(report.Detection)

	local key = `{Util.FormatUserId(userId)}:{category}`
	local queued = queuedByKey[key]
	if queued then
		queued.Description = description
		queued.Detection = detection
		Log.Debug(`Report about {userId} ({category}) merged into the queued one.`)
		return true
	end
	if #queue >= MAX_QUEUE then
		Log.WarnThrottled("report-queue-full", 60, `Report queue is full ({MAX_QUEUE}); new reports are dropped.`)
		return false
	end

	local now = os.clock()
	for otherKey, at in sentAt do
		if now - at >= COOLDOWN then
			sentAt[otherKey] = nil
		end
	end
	local lastSent = sentAt[key]
	local item: Item = {
		Key = key,
		UserId = userId,
		Category = category :: Types.ReportCategory,
		Description = description,
		Detection = detection,
		NotBefore = if lastSent then lastSent + COOLDOWN else now,
	}
	table.insert(queue, item)
	queuedByKey[key] = item
	Log.Debug(`Report about {userId} ({category}) queued.`)

	if not workerRunning then
		workerRunning = true
		task.defer(worker)
	end
	return true
end

-- Sends everything still queued (in parallel, ignoring cooldowns) and waits up to `timeout` seconds.
-- For game:BindToClose.
function Reports.Flush(timeout: number)
	local deadline = os.clock() + timeout
	closeDeadline = deadline
	while #queue > 0 do
		task.spawn(sendTracked, take(1))
	end
	while inFlight > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
	if inFlight > 0 or #queue > 0 then
		Log.Warn(`{inFlight + #queue} report(s) were not sent before the server closed.`)
	end
end

return Reports
