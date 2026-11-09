--!strict
-- Lucida for Roblox (server only: HttpService works only on the server). Put this ModuleScript in
-- ServerScriptService or ServerStorage and require it from a server Script:
--
--   local Lucida = require(path.to.Lucida)
--   local lucida = Lucida.new({ apiKey = "lc_pk_...", consent = "opt_in" })
--   lucida:start() -- player sessions, flush loop, BindToClose
--   lucida:setConsent(player, true)
--   lucida:capture(player, "level_complete", { level = 3 })
--
-- Players are `roblox:<UserId>`. Consent is per player and kept in memory only: nothing is
-- written to a DataStore, so no storage write ever happens before (or without) consent.

local Event = require(script.Event)
local Queue = require(script.Queue)
local Flags = require(script.Flags)

local Lucida = {}
Lucida.__index = Lucida
Lucida.Event = Event
Lucida.Queue = Queue
Lucida.Flags = Flags

local SESSION_IDLE_MS = 30 * 60 * 1000

export type Options = {
	apiKey: string,
	host: string?,
	-- "opt_out" (default, like every Lucida SDK) captures until a player opts out; "opt_in"
	-- captures nothing for a player before setConsent(player, true).
	consent: string?,
	flushAt: number?,
	flushInterval: number?, -- seconds
	maxQueueSize: number?,
	maxRetries: number?,
	httpService: any?, -- injected in tests; default game:GetService("HttpService")
	players: any?, -- default game:GetService("Players")
	clock: (() -> number)?, -- ms since epoch
	random: ((number, number) -> number)?,
}

local function who(p: any): string
	if type(p) == "string" then
		return p
	end
	return "roblox:" .. tostring(p.UserId)
end

function Lucida.new(opts: Options)
	assert(type(opts.apiKey) == "string" and opts.apiKey ~= "", "Lucida.new: apiKey is required")
	local rng = Random.new()
	local self = setmetatable({
		apiKey = opts.apiKey,
		host = string.gsub(opts.host or "https://capture.lucidace.com", "/+$", ""),
		mode = opts.consent or "opt_out",
		flushAt = opts.flushAt or 20,
		flushInterval = opts.flushInterval or 5,
		http = opts.httpService or game:GetService("HttpService"),
		players = opts.players,
		clock = opts.clock or function()
			return DateTime.now().UnixTimestampMillis
		end,
		random = opts.random or function(a: number, b: number)
			return rng:NextInteger(a, b)
		end,
		queue = Queue.new(opts.maxQueueSize, opts.maxRetries),
		consent = {} :: { [string]: boolean },
		sessions = {} :: { [string]: { id: string, last: number } },
		flags = {} :: { [string]: Flags.Parsed },
		called = {} :: { [string]: boolean },
		groups = {} :: { [string]: { [string]: string } },
		running = false,
	}, Lucida)
	return self
end

function Lucida:hasConsent(player: any): boolean
	local c = self.consent[who(player)]
	if c == nil then
		return self.mode ~= "opt_in"
	end
	return c
end

function Lucida:_session(id: string, now: number): string
	local s = self.sessions[id]
	if not s or now - s.last > SESSION_IDLE_MS then
		s = { id = Event.uuidV7(now, self.random), last = now }
		self.sessions[id] = s
	end
	s.last = now
	return s.id
end

function Lucida:_capture(player: any, name: string, props: { [string]: any }?, extra: { [string]: any }?)
	local id = who(player)
	if not self:hasConsent(id) then
		return nil
	end
	local now = self.clock()
	local p = Event.stripReserved(props)
	local f = self.flags[id]
	if f then
		for k, v in f.values do
			p["$feature/" .. k] = v
		end
	end
	local x = extra or {}
	if self.groups[id] and next(self.groups[id]) then
		x["$groups"] = table.clone(self.groups[id])
	end
	local e = Event.build(name, id, p, self:_session(id, now), now, self.random, x)
	self.queue:push(e)
	if self.queue:size() >= self.flushAt then
		self:flush()
	end
	return e
end

function Lucida:capture(player: any, name: string, props: { [string]: any }?)
	return self:_capture(player, name, props)
end

function Lucida:screen(player: any, name: string, props: { [string]: any }?)
	local p = Event.stripReserved(props)
	p["$screen_name"] = name
	return self:_capture(player, "$screen", p)
end

-- Person properties for a player (their distinct id is already stable, so no merge happens).
function Lucida:identify(player: any, set: { [string]: any }?, setOnce: { [string]: any }?)
	local extra = {}
	if set then
		extra["$set"] = Event.stripReserved(set)
	end
	if setOnce then
		extra["$set_once"] = Event.stripReserved(setOnce)
	end
	return self:_capture(player, "$identify", nil, extra)
end

function Lucida:group(player: any, groupType: string, key: string, props: { [string]: any }?)
	local id = who(player)
	if not self:hasConsent(id) then
		return nil
	end
	self.groups[id] = self.groups[id] or {}
	self.groups[id][groupType] = key
	return self:_capture(id, "$groupidentify", { ["$group_type"] = groupType, ["$group_key"] = key, ["$group_set"] = Event.stripReserved(props) })
end

-- Records a player's consent. Granting captures $opt_in; revoking captures $opt_out (sent with
-- what is already queued) and forgets the player's session, groups and flags.
function Lucida:setConsent(player: any, granted: boolean)
	local id = who(player)
	local was = self:hasConsent(id)
	if was and not granted then
		self:_capture(id, "$opt_out")
	end
	self.consent[id] = granted
	if not granted then
		self.sessions[id], self.groups[id], self.flags[id] = nil, nil, nil
	elseif not was then
		self:_capture(id, "$opt_in")
	end
end

function Lucida:_post(path: string, body: string): (number, string?)
	local ok, res = pcall(function()
		return self.http:RequestAsync({
			Url = self.host .. path,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = body,
		})
	end)
	if not ok or type(res) ~= "table" then
		return 0, nil
	end
	return res.StatusCode or 0, res.Body
end

-- Sends queued batches until the queue is empty or waits on a backoff. Yields (HTTP).
function Lucida:flush()
	local encode = function(batch: { any }): string
		return self.http:JSONEncode({ api_key = self.apiKey, batch = batch, sent_at = Event.iso(self.clock()) })
	end
	local send = function(body: string): number
		return (self:_post("/v1/batch", body))
	end
	local rand = function(): number
		return self.random(0, 1000) / 1000
	end
	while self.queue:sendOne(self.clock(), encode, send, rand) do
	end
end

-- Fetches a player's flags (POST /v1/flags). Yields. Keeps the cached values on failure.
function Lucida:reloadFlags(player: any): Flags.Parsed?
	local id = who(player)
	if not self:hasConsent(id) then
		return nil
	end
	local body = self.http:JSONEncode({ api_key = self.apiKey, distinct_id = id, groups = self.groups[id] or {}, person_properties = {} })
	local status, text = self:_post("/v1/flags", body)
	if status < 200 or status > 299 or not text then
		return self.flags[id]
	end
	local ok, decoded = pcall(function()
		return self.http:JSONDecode(text)
	end)
	if ok then
		self.flags[id] = Flags.parse(decoded)
	end
	return self.flags[id]
end

function Lucida:getFlag(player: any, key: string): any
	local id = who(player)
	local f = self.flags[id]
	local v = f and f.values[key]
	local mark = id .. "|" .. key .. "=" .. tostring(v)
	if not self.called[mark] then
		self.called[mark] = true
		self:_capture(id, "$feature_flag_called", { ["$feature_flag"] = key, ["$feature_flag_response"] = if v == nil then false else v })
	end
	return v
end

function Lucida:isFeatureEnabled(player: any, key: string): boolean
	local v = self:getFlag(player, key)
	return v ~= nil and v ~= false
end

function Lucida:getFlagPayload(player: any, key: string): any
	local f = self.flags[who(player)]
	return f and f.payloads[key]
end

-- Player sessions ($session_start / $session_end), a flush loop and a final flush on shutdown.
function Lucida:start()
	if self.running then
		return
	end
	self.running = true
	local players = self.players or game:GetService("Players")
	players.PlayerAdded:Connect(function(p)
		self:_capture(p, "$session_start")
		task.spawn(function()
			self:reloadFlags(p)
		end)
	end)
	players.PlayerRemoving:Connect(function(p)
		local id = who(p)
		self:_capture(id, "$session_end")
		self.sessions[id], self.flags[id], self.groups[id], self.consent[id] = nil, nil, nil, nil
	end)
	task.spawn(function()
		while self.running do
			task.wait(self.flushInterval)
			self:flush()
		end
	end)
	game:BindToClose(function()
		self.running = false
		self:flush()
	end)
end

return Lucida
