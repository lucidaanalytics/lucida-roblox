--!strict
-- Parses a /v1/flags response into values and payloads.

local Flags = {}

export type Parsed = { values: { [string]: any }, payloads: { [string]: any } }

function Flags.parse(decoded: any): Parsed
	local values, payloads = {}, {}
	local flags = type(decoded) == "table" and decoded.flags or nil
	if type(flags) ~= "table" then
		return { values = values, payloads = payloads }
	end
	for key, m in flags do
		if type(m) ~= "table" then
			values[key] = m
		else
			if m.value ~= nil then
				values[key] = m.value
			elseif m.variant ~= nil then
				values[key] = m.variant
			else
				values[key] = m.enabled == true
			end
			if m.payload ~= nil then
				payloads[key] = m.payload
			end
		end
	end
	return { values = values, payloads = payloads }
end

return Flags
