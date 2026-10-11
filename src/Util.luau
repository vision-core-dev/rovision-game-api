--!strict
-- Small helpers shared by the modules.

local Util = {}

-- Player or integer UserId -> UserId. Returns nil for anything else.
function Util.UserIdOf(target: any): number?
	if typeof(target) == "Instance" then
		local instance = target :: Instance
		return if instance:IsA("Player") then (instance :: Player).UserId else nil
	end
	-- Whole numbers only (rejects NaN and infinity too), within the exactly representable range.
	if type(target) == "number" and target % 1 == 0 and math.abs(target) < 2 ^ 53 then
		return target
	end
	return nil
end

-- The API takes Roblox ids as decimal strings.
function Util.FormatUserId(userId: number): string
	return string.format("%d", userId)
end

function Util.Trim(text: string): string
	return string.match(text, "^%s*(.-)%s*$") or text
end

-- Length the way the API (JavaScript) counts it: UTF-16 code units. Nil for invalid UTF-8.
function Util.Utf16Length(text: string): number?
	if utf8.len(text) == nil then
		return nil
	end
	local units = 0
	for _, codepoint in utf8.codes(text) do
		units += if codepoint > 0xFFFF then 2 else 1
	end
	return units
end

-- Cuts valid UTF-8 text to at most `limit` UTF-16 code units, on a character boundary.
function Util.TruncateUtf16(text: string, limit: number): string
	local units = 0
	for position, codepoint in utf8.codes(text) do
		units += if codepoint > 0xFFFF then 2 else 1
		if units > limit then
			return string.sub(text, 1, position - 1)
		end
	end
	return text
end

return Util
