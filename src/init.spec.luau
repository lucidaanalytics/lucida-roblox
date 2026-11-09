-- TestEZ specs for the Lucida client with an injected fake HttpService (no network).
return function()
	local Lucida = require(script.Parent)

	local function fakeHttp(status: number?, flagsBody: string?)
		local http = { calls = {} }
		local codes = {}
		function http:JSONEncode(v)
			local id = #codes + 1
			codes[id] = v
			return "#" .. id
		end
		function http:JSONDecode(s)
			return codes[tonumber(string.sub(s, 2))]
		end
		function http:RequestAsync(req)
			table.insert(self.calls, { url = req.Url, body = codes[tonumber(string.sub(req.Body, 2))] })
			if string.find(req.Url, "/v1/flags", 1, true) then
				return { Success = true, StatusCode = 200, Body = flagsBody or "" }
			end
			return { Success = true, StatusCode = status or 200, Body = "" }
		end
		return http, codes
	end

	local now = 1767225600000
	local function make(opts)
		local http = opts.http or fakeHttp()
		return Lucida.new({
			apiKey = "lc_pk_test",
			host = "https://example.test/",
			consent = opts.consent,
			flushAt = opts.flushAt or 100,
			httpService = http,
			clock = function()
				return now
			end,
			random = function(a, _b)
				return a
			end,
		}), http
	end
	local player = { UserId = 42 }

	describe("capture", function()
		it("builds the wire event for a player and strips $lc_ props", function()
			local c = make({})
			local e = c:capture(player, "level_complete", { level = 3, ["$lc_project"] = "spoof" })
			expect(e.event).to.equal("level_complete")
			expect(e.distinct_id).to.equal("roblox:42")
			expect(#e.uuid).to.equal(36)
			expect(string.sub(e.uuid, 15, 15)).to.equal("7")
			expect(e.properties["$lib"]).to.equal("lucida-roblox")
			expect(e.properties["$lc_project"]).to.equal(nil)
			expect(e.properties["$session_id"]).to.be.ok()
			expect(e.timestamp).to.equal("2026-01-01T00:00:00.000Z")
		end)

		it("flushes {api_key, batch, sent_at} to /v1/batch at flushAt", function()
			local c, http = make({ flushAt = 2 })
			c:capture(player, "a")
			expect(#http.calls).to.equal(0)
			c:capture(player, "b")
			expect(#http.calls).to.equal(1)
			expect(http.calls[1].url).to.equal("https://example.test/v1/batch")
			expect(http.calls[1].body.api_key).to.equal("lc_pk_test")
			expect(#http.calls[1].body.batch).to.equal(2)
			expect(c.queue:size()).to.equal(0)
		end)
	end)

	describe("consent", function()
		it("opt_in captures nothing before consent", function()
			local c = make({ consent = "opt_in" })
			expect(c:capture(player, "early")).to.equal(nil)
			expect(c.queue:size()).to.equal(0)
			c:setConsent(player, true)
			expect(c.queue.items[1].event).to.equal("$opt_in")
			c:setConsent(player, false)
			expect(c.queue.items[2].event).to.equal("$opt_out")
			expect(c:capture(player, "late")).to.equal(nil)
		end)

		it("opt_out mode captures by default", function()
			local c = make({})
			expect(c:hasConsent(player)).to.equal(true)
		end)
	end)

	describe("retries", function()
		it("keeps a batch on 503 with backoff and drops it on 400", function()
			local http = fakeHttp(503)
			local c = make({ http = http })
			c:capture(player, "a")
			c:flush()
			expect(c.queue:size()).to.equal(1)
			expect(c.queue.retryAt > now).to.equal(true)
			c:flush() -- still backing off: no request
			expect(#http.calls).to.equal(1)
			local q = Lucida.Queue.new()
			q:push({})
			q:sendOne(0, function()
				return ""
			end, function()
				return 400
			end, function()
				return 0
			end)
			expect(q:size()).to.equal(0)
			expect(q.dropped).to.equal(1)
		end)

		it("caps the queue, dropping the oldest", function()
			local q = Lucida.Queue.new(2)
			q:push(1)
			q:push(2)
			q:push(3)
			expect(q:size()).to.equal(2)
			expect(q.items[1]).to.equal(2)
		end)
	end)

	describe("flags", function()
		it("parses values and payloads and records $feature_flag_called once", function()
			local http, codes = fakeHttp()
			codes[999] = { flags = { a = { enabled = true }, b = { variant = "blue", payload = { x = 1 } }, c = 3 } }
			local c = make({ http = http })
			http.RequestAsync = function(self, req)
				table.insert(self.calls, { url = req.Url })
				return { Success = true, StatusCode = 200, Body = "#999" }
			end
			c:reloadFlags(player)
			expect(c:isFeatureEnabled(player, "a")).to.equal(true)
			expect(c:getFlag(player, "b")).to.equal("blue")
			expect(c:getFlagPayload(player, "b").x).to.equal(1)
			c:getFlag(player, "b")
			local called = 0
			for _, e in c.queue.items do
				if e.event == "$feature_flag_called" then
					called += 1
				end
			end
			expect(called).to.equal(2)
			local e = c:capture(player, "after")
			expect(e.properties["$feature/b"]).to.equal("blue")
		end)
	end)

	describe("start", function()
		local function signal()
			local s = { fns = {} }
			function s:Connect(fn)
				table.insert(self.fns, fn)
			end
			function s:Fire(...)
				for _, fn in self.fns do
					fn(...)
				end
			end
			return s
		end

		it("tracks player sessions and forgets a player on leave", function()
			local players = { PlayerAdded = signal(), PlayerRemoving = signal() }
			local http = fakeHttp()
			local c = Lucida.new({ apiKey = "k", httpService = http, players = players, flushInterval = 0.01 })
			c:start()
			players.PlayerAdded:Fire(player)
			expect(c.queue.items[1].event).to.equal("$session_start")
			expect(c.queue.items[1].distinct_id).to.equal("roblox:42")
			c:group(player, "guild", "red")
			players.PlayerRemoving:Fire(player)
			expect(c.queue.items[#c.queue.items].event).to.equal("$session_end")
			expect(c.groups["roblox:42"]).to.equal(nil)
			expect(c.sessions["roblox:42"]).to.equal(nil)
			-- Lune's fake DataModel can fire BindToClose; in Studio `game` is an Instance and this is skipped.
			if typeof(game) == "table" then
				game:close()
				expect(c.running).to.equal(false)
				expect(c.queue:size()).to.equal(0)
				expect(http.calls[#http.calls].url).to.equal("https://capture.lucidace.com/v1/batch")
			end
			c.running = false
		end)
	end)
end
