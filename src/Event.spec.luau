-- TestEZ specs for the pure modules (Event, Queue) and the per-player calls of the client.
return function()
	local Lucida = require(script.Parent)
	local Event = Lucida.Event
	local Queue = Lucida.Queue

	local function fixed(a: number, _b: number)
		return a
	end

	describe("Event", function()
		it("formats a v7 uuid from the millisecond clock", function()
			local u = Event.uuidV7(0x0123456789ab, fixed)
			expect(u).to.equal("01234567-89ab-7000-8000-000000000000")
		end)

		it("formats ISO timestamps with milliseconds in UTC", function()
			expect(Event.iso(1767225600123)).to.equal("2026-01-01T00:00:00.123Z")
		end)

		it("strips only string $lc_ keys and copies the rest", function()
			local src = { ["$lc_org"] = 1, ["$lc"] = 2, plain = 3 }
			local out = Event.stripReserved(src)
			expect(out["$lc_org"]).to.equal(nil)
			expect(out["$lc"]).to.equal(2)
			expect(out.plain).to.equal(3)
			expect(src["$lc_org"]).to.equal(1) -- the caller's table is not mutated
			expect(next(Event.stripReserved(nil))).to.equal(nil)
		end)

		it("builds an event whose SDK props cannot be overridden and merges extra fields", function()
			local e = Event.build("x", "roblox:1", { ["$lib"] = "spoof" }, "s1", 0, fixed, { ["$set"] = { a = 1 } })
			expect(e.properties["$lib"]).to.equal("lucida-roblox")
			expect(e.properties["$os"]).to.equal("Roblox")
			expect(e["$set"].a).to.equal(1)
		end)
	end)

	describe("Queue", function()
		local function encode()
			return ""
		end
		local function half()
			return 0.5
		end

		it("sends at most MAX_BATCH events per request", function()
			local q = Queue.new()
			for i = 1, 150 do
				q:push(i)
			end
			local sizes = {}
			local function send(_body: string)
				table.insert(sizes, #q.items)
				return 200
			end
			expect(q:sendOne(0, encode, send, half)).to.equal(true)
			expect(q:size()).to.equal(50)
			expect(sizes[1]).to.equal(150)
		end)

		it("backs off exponentially, capped, and drops after maxRetries", function()
			local q = Queue.new(nil, 2)
			q:push(1)
			local function fail()
				return 503
			end
			expect(q:sendOne(0, encode, fail, half)).to.equal(false)
			expect(q.retryAt).to.equal(1500) -- 2 s cap * 0.75
			expect(q:sendOne(100, encode, fail, half)).to.equal(false) -- still waiting: nothing sent
			expect(q.attempt).to.equal(1)
			q:sendOne(2000, encode, fail, half)
			expect(q.attempt).to.equal(2)
			expect(q:sendOne(10000, encode, fail, half)).to.equal(true)
			expect(q:size()).to.equal(0)
			expect(q.dropped).to.equal(1)
		end)

		it("treats network failures, 408 and 429 as retryable", function()
			expect(Queue.retryable(0)).to.equal(true)
			expect(Queue.retryable(408)).to.equal(true)
			expect(Queue.retryable(429)).to.equal(true)
			expect(Queue.retryable(404)).to.equal(false)
		end)
	end)

	describe("players", function()
		local now = 1767225600000
		local function make(consent: string?)
			local http = { calls = {} }
			function http:JSONEncode(_v)
				return ""
			end
			function http:JSONDecode(_s)
				return {}
			end
			function http:RequestAsync(req)
				table.insert(self.calls, req.Url)
				return { Success = true, StatusCode = 200, Body = "" }
			end
			return Lucida.new({
				apiKey = "k",
				consent = consent,
				flushAt = 1000,
				httpService = http,
				clock = function()
					return now
				end,
				random = fixed,
			})
		end
		local alice, bob = { UserId = 1 }, { UserId = 2 }

		it("screen, identify and group build their events", function()
			local c = make()
			local s = c:screen(alice, "Shop", { ["$lc_x"] = 1 })
			expect(s.event).to.equal("$screen")
			expect(s.properties["$screen_name"]).to.equal("Shop")
			expect(s.properties["$lc_x"]).to.equal(nil)
			local i = c:identify(alice, { plan = "pro", ["$lc_y"] = 1 }, { first = "2026" })
			expect(i.event).to.equal("$identify")
			expect(i["$set"].plan).to.equal("pro")
			expect(i["$set"]["$lc_y"]).to.equal(nil)
			expect(i["$set_once"].first).to.equal("2026")
			local g = c:group(alice, "guild", "red", { size = 5 })
			expect(g.properties["$group_key"]).to.equal("red")
			expect(c:capture(alice, "later")["$groups"].guild).to.equal("red")
			expect(c:capture(bob, "other")["$groups"]).to.equal(nil) -- groups are per player
		end)

		it("rotates a player's session after 30 idle minutes", function()
			local c = make()
			local first = c:capture(alice, "a").properties["$session_id"]
			now += 29 * 60 * 1000
			expect(c:capture(alice, "b").properties["$session_id"]).to.equal(first)
			now += 31 * 60 * 1000
			expect(c:capture(alice, "c").properties["$session_id"] ~= first).to.equal(true)
		end)

		it("revoking consent forgets the player's session, groups and flags only", function()
			local c = make("opt_in")
			c:setConsent(alice, true)
			c:setConsent(bob, true)
			c:group(alice, "guild", "red")
			c.flags["roblox:1"] = { values = { a = true }, payloads = {} }
			c:setConsent(alice, false)
			expect(c.sessions["roblox:1"]).to.equal(nil)
			expect(c.groups["roblox:1"]).to.equal(nil)
			expect(c.flags["roblox:1"]).to.equal(nil)
			expect(c:group(alice, "guild", "blue")).to.equal(nil)
			expect(c:capture(bob, "still").event).to.equal("still")
		end)
	end)
end
