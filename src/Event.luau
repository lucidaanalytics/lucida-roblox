--!strict
-- Pure event helpers: uuid v7, ISO timestamps, reserved-prop stripping and event building.

local Event = {}

Event.LIB = "lucida-roblox"
Event.LIB_VERSION = "0.1.0"

local function hex(n: number, width: number): string
	return string.format("%0" .. width .. "x", n)
end

-- UUID v7: 48-bit millisecond timestamp, version 7, RFC 4122 variant, random rest.
function Event.uuidV7(ms: number, random: (number, number) -> number): string
	local hi = ms // 0x10000 -- top 32 bits of the 48-bit timestamp
	local lo = ms % 0x10000
	local randA = random(0, 0xfff)
	local variant = 0x8000 + random(0, 0x3fff)
	return string.format(
		"%s-%s-7%s-%s-%s%s",
		hex(hi, 8),
		hex(lo, 4),
		hex(randA, 3),
		hex(variant, 4),
		hex(random(0, 0xffffff), 6),
		hex(random(0, 0xffffff), 6)
	)
end

function Event.iso(ms: number): string
	return (os.date("!%Y-%m-%dT%H:%M:%S", ms // 1000) :: string) .. string.format(".%03dZ", ms % 1000)
end

-- Drops caller-supplied `$lc_*` keys: they are reserved for the gateway.
function Event.stripReserved(props: { [string]: any }?): { [string]: any }
	local out = {}
	if props then
		for k, v in props do
			if type(k) ~= "string" or string.sub(k, 1, 4) ~= "$lc_" then
				out[k] = v
			end
		end
	end
	return out
end

export type Built = { [string]: any }

-- One event in the /v1/batch wire shape.
function Event.build(
	name: string,
	distinctId: string,
	props: { [string]: any }?,
	sessionId: string,
	ms: number,
	random: (number, number) -> number,
	extra: { [string]: any }?
): Built
	local p = Event.stripReserved(props)
	p["$lib"] = Event.LIB
	p["$lib_version"] = Event.LIB_VERSION
	p["$session_id"] = sessionId
	p["$os"] = "Roblox"
	local e: Built = {
		uuid = Event.uuidV7(ms, random),
		event = name,
		distinct_id = distinctId,
		timestamp = Event.iso(ms),
		properties = p,
	}
	if extra then
		for k, v in extra do
			e[k] = v
		end
	end
	return e
end

return Event
