--!strict
-- HTTP core: JSON requests to the RoVision game API with auth, timeouts,
-- retries with exponential backoff and a client-side request budget.

local HttpService = game:GetService("HttpService")

local Log = require(script.Parent.Log)

export type Method = "GET" | "POST" | "DELETE"

export type Response = {
	Ok: boolean,
	StatusCode: number, -- 0 when no HTTP response was received
	Data: any, -- decoded JSON body, if any
	Code: string?, -- API error code (e.g. "rate_limited") or a local one (e.g. "network_error")
	Error: string?, -- short human-readable description of the failure
	Warned: boolean?, -- true when a warning about this failure was already printed
}

-- Subsets of Roblox's HttpService:RequestAsync request and response tables.
type HttpRequest = {
	Url: string,
	Method: Method,
	Headers: { [string]: string | Secret },
	Body: string?,
}

type HttpResponse = {
	StatusCode: number,
	Headers: { [string]: string }?,
	Body: string?,
}

export type RequestOptions = {
	MaxAttempts: number?, -- default 4 (1 try + 3 retries)
	Deadline: number?, -- os.clock() time; no attempt or wait goes past it
}

local REQUEST_TIMEOUT = 15
local DEFAULT_ATTEMPTS = 4
local BACKOFF_BASE = 1
local BACKOFF_MAX = 20
local RETRY_AFTER_MAX = 60
-- Roblox allows ~500 HttpService requests per minute per server for all scripts together.
-- RoVision keeps to a small share of that.
local BUDGET_PER_MINUTE = 120
local BUDGET_BURST = 20
local AUTH_SUSPEND = 600 -- after 401/403 the key won't start working by itself; stop calling for a while
local HTTP_DISABLED_SUSPEND = 60
local ROBLOX_LIMIT_PAUSE = 15
local DEBUG_BODY_LIMIT = 500

local TIMED_OUT = table.freeze({}) -- sentinel result for requestWithTimeout

local Http = {}

local baseUrl = ""
local authorization: (string | Secret)? = nil
local moduleVersion = "dev"
local disabledCode: string? = "not_initialized"

local tokens = BUDGET_BURST
local refilledAt = os.clock()
local pausedUntil = 0
local suspendedUntil = 0
local suspendedCode = "suspended"

-- `auth` is the full Authorization header value ("Bearer …" string or a prefixed Secret);
-- nil leaves the HTTP layer disabled (no key).
function Http.Configure(url: string, auth: (string | Secret)?, version: string)
	baseUrl = (string.gsub(url, "/+$", ""))
	authorization = auth
	moduleVersion = version
	disabledCode = if auth == nil then "missing_api_key" else nil
end

local function failure(statusCode: number, code: string, message: string, data: any?, warned: boolean?): Response
	return {
		Ok = false,
		StatusCode = statusCode,
		Data = data,
		Code = code,
		Error = message,
		Warned = warned,
	}
end

local function preview(text: string): string
	if #text > DEBUG_BODY_LIMIT then
		return string.sub(text, 1, DEBUG_BODY_LIMIT) .. "…"
	end
	return text
end

-- Delays all requests (rate limits).
local function pause(seconds: number)
	pausedUntil = math.max(pausedUntil, os.clock() + seconds)
end

-- Rejects all requests without calling the API (auth problems, HTTP disabled).
local function suspend(seconds: number, code: string)
	suspendedUntil = os.clock() + seconds
	suspendedCode = code
end

-- Token bucket. Yields until a request may be sent; false if that would pass the deadline.
local function takeToken(deadline: number?): boolean
	while true do
		local now = os.clock()
		tokens = math.min(BUDGET_BURST, tokens + (now - refilledAt) * BUDGET_PER_MINUTE / 60)
		refilledAt = now
		local waitFor: number
		if pausedUntil > now then
			waitFor = pausedUntil - now
		elseif tokens >= 1 then
			tokens -= 1
			return true
		else
			waitFor = (1 - tokens) * 60 / BUDGET_PER_MINUTE
		end
		if deadline and now + waitFor > deadline then
			return false
		end
		task.wait(waitFor)
	end
end

local function backoff(attempt: number): number
	local delay = math.min(BACKOFF_MAX, BACKOFF_BASE * 2 ^ (attempt - 1))
	return delay * (0.75 + math.random() * 0.5)
end

local function retryAfter(headers: { [string]: string }?): number?
	if not headers then
		return nil
	end
	for name, value in headers do
		if string.lower(name) == "retry-after" then
			return tonumber(value)
		end
	end
	return nil
end

local function decode(body: string?): any
	if body == nil or body == "" then
		return nil
	end
	local ok, data = pcall(HttpService.JSONDecode, HttpService, body)
	return if ok then data else nil
end

-- Error code and message from an API error body ({ code, message } as NestJS sends it).
local function errorDetails(data: any, status: number): (string, string)
	local code = `http_{status}`
	local message = `HTTP {status}`
	if type(data) == "table" then
		if type(data.code) == "string" then
			code = data.code
		end
		local detail = data.message
		if type(detail) == "table" then
			local parts = {}
			for _, part in detail do
				table.insert(parts, tostring(part))
			end
			detail = table.concat(parts, "; ")
		end
		if type(detail) == "string" and detail ~= "" then
			message = `{code}: {detail}`
		else
			message = code
		end
	end
	return code, message
end

-- RequestAsync has no timeout option, so wait for it in a separate thread.
local function requestWithTimeout(request: HttpRequest, timeout: number): (boolean, any)
	local thread = coroutine.running()
	local finished = false
	local timer = task.delay(timeout, function()
		if not finished then
			finished = true
			task.defer(thread, false, TIMED_OUT)
		end
	end)
	task.spawn(function()
		local ok, result = pcall(HttpService.RequestAsync, HttpService, request :: any)
		if not finished then
			finished = true
			task.cancel(timer)
			-- defer: the request may fail before the calling thread has yielded
			task.defer(thread, ok, result)
		end
	end)
	return coroutine.yield()
end

-- Sends a JSON request. Never throws; yields while waiting, retrying and backing off.
-- Retries network errors, timeouts, 5xx and 429; never other 4xx.
function Http.Request(method: Method, path: string, body: any?, options: RequestOptions?): Response
	if disabledCode then
		return failure(0, disabledCode, "no API key (see the warning printed at Init)", nil, true)
	end
	local maxAttempts = options and options.MaxAttempts or DEFAULT_ATTEMPTS
	local deadline = options and options.Deadline

	local encoded: string? = nil
	if body ~= nil then
		local ok, result = pcall(HttpService.JSONEncode, HttpService, body)
		if not ok then
			Log.Warn(`{method} {path}: the request body can't be converted to JSON: {result}`)
			return failure(0, "encode_error", tostring(result), nil, true)
		end
		encoded = result
	end

	local headers: { [string]: string | Secret } = {
		Authorization = authorization :: any,
		Accept = "application/json",
		["X-RoVision-Module"] = moduleVersion,
	}
	if encoded then
		headers["Content-Type"] = "application/json"
	end
	local request: HttpRequest = {
		Url = baseUrl .. path,
		Method = method,
		Headers = headers,
		Body = encoded,
	}

	local attempt = 0
	while true do
		attempt += 1
		if os.clock() < suspendedUntil then
			return failure(0, suspendedCode, "requests are paused after an earlier error", nil, true)
		end
		if not takeToken(deadline) then
			return failure(0, "budget_exhausted", "no request budget left before the deadline")
		end
		local timeout = REQUEST_TIMEOUT
		if deadline then
			timeout = math.min(timeout, deadline - os.clock())
			if timeout <= 0 then
				return failure(0, "timeout", "deadline reached")
			end
		end

		if Log.IsDebug() then
			Log.Debug(`-> {method} {path}{if encoded then " " .. preview(encoded) else ""}`)
		end
		local startedAt = os.clock()
		local ok, result = requestWithTimeout(request, timeout)
		local elapsed = math.floor((os.clock() - startedAt) * 1000)

		local last: Response
		local retryDelay: number? = nil
		if not ok then
			-- No HTTP response: HTTP disabled, secret problem, DNS/connection error, timeout...
			if result == TIMED_OUT then
				last = failure(0, "timeout", `no response in {math.floor(timeout)} s`)
			else
				local message = tostring(result)
				local lower = string.lower(message)
				if string.find(lower, "not enabled", 1, true) then
					suspend(HTTP_DISABLED_SUSPEND, "http_disabled")
					Log.WarnOnce(
						"http-disabled",
						"HTTP requests are disabled. Turn on Game Settings → Security → Allow HTTP Requests. "
							.. "Until then ban checks are skipped and players are let in."
					)
					return failure(0, "http_disabled", message, nil, true)
				elseif string.find(lower, "secret", 1, true) then
					suspend(AUTH_SUSPEND, "secret_error")
					Log.WarnOnce(
						"secret-error",
						`The API key secret can't be used for {baseUrl} ({message}). `
							.. "Check that the secret's domain is api.rovision.gg (or the host of BaseUrl)."
					)
					return failure(0, "secret_error", message, nil, true)
				elseif string.find(lower, "exceeded", 1, true) then
					-- Roblox's own per-server HttpService limit (shared with the game's other scripts).
					pause(ROBLOX_LIMIT_PAUSE)
					Log.WarnThrottled(
						"roblox-limit",
						60,
						"The server reached Roblox's HttpService request limit; RoVision requests are delayed."
					)
				end
				last = failure(0, "network_error", message)
			end
			Log.Debug(`x {method} {path} after {elapsed} ms: {last.Error}`)
		else
			local response = result :: HttpResponse
			local status = response.StatusCode
			local data = decode(response.Body)
			if Log.IsDebug() then
				Log.Debug(`<- {status} {method} {path} in {elapsed} ms {preview(response.Body or "")}`)
			end
			if status >= 200 and status < 300 then
				return { Ok = true, StatusCode = status, Data = data }
			end

			local code, message = errorDetails(data, status)
			last = failure(status, code, message, data)
			if status == 401 then
				suspend(AUTH_SUSPEND, "invalid_api_key")
				Log.Warn(
					"Invalid API key (401 invalid_api_key). Check the rovision secret or create a new key "
						.. "in Кабінет → Мої ігри → Інтеграція. RoVision requests are paused for 10 minutes; "
						.. "players are let in."
				)
				last.Warned = true
				return last
			elseif status == 403 and code == "partner_required" then
				suspend(AUTH_SUSPEND, "partner_required")
				Log.Warn(
					"The owner of this game is no longer a RoVision partner (403 partner_required). "
						.. "RoVision requests are paused for 10 minutes; players are let in."
				)
				last.Warned = true
				return last
			elseif status == 429 then
				retryDelay = math.clamp(retryAfter(response.Headers) or backoff(attempt), 1, RETRY_AFTER_MAX)
				pause(retryDelay :: number)
				Log.WarnThrottled("rate-limited", 60, "RoVision API rate limit reached (429); requests are delayed.")
			elseif status < 500 then
				-- Any other 4xx: the request itself is wrong, a retry won't help.
				return last
			end
		end

		if attempt >= maxAttempts then
			return last
		end
		local delay = retryDelay or backoff(attempt)
		if deadline and os.clock() + delay >= deadline then
			return last
		end
		Log.Debug(`Retrying {method} {path} in {string.format("%.1f", delay)} s ({attempt + 1}/{maxAttempts})`)
		task.wait(delay)
	end
end

return Http
