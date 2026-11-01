-- Runs src/*.spec.luau outside Roblox with Lune: `cd sdks/roblox && lune run tests/run`.
-- Loads the ModuleScripts from disk behind fake `script` instances and fakes the Roblox globals
-- the SDK touches (game, Random, DateTime); `task` is Lune's scheduler. Exits 1 on any failure.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local task = require("@lune/task")

-- Fake DataModel: GetService returns registered fakes; BindToClose hooks run on game:close().
local game = { services = {}, closers = {} }
function game:GetService(name: string)
	return assert(self.services[name], "no fake service " .. name)
end
function game:BindToClose(fn)
	table.insert(self.closers, fn)
end
function game:close()
	for _, fn in self.closers do
		fn()
	end
	self.closers = {}
end

local Random = {
	new = function()
		return {
			NextInteger = function(_self, a: number, b: number)
				return math.random(a, b)
			end,
		}
	end,
}
local DateTime = {
	now = function()
		return { UnixTimestampMillis = os.time() * 1000 }
	end,
}

-- TestEZ subset used by the specs: describe, it, expect(v).to.equal(x), expect(v).to.be.ok().
local passed, failed, prefix = 0, 0, {}
local function describe(name: string, fn: () -> ())
	table.insert(prefix, name)
	fn()
	table.remove(prefix)
end
local function it(name: string, fn: () -> ())
	local full = table.concat(prefix, " > ") .. " > " .. name
	local ok, err = pcall(fn)
	if ok then
		passed += 1
	else
		failed += 1
		print("FAIL: " .. full .. "\n  " .. tostring(err))
	end
end
local function expect(v: any)
	local e = {}
	e.to, e.be = e, e
	function e.equal(x: any)
		if v ~= x then
			error(string.format("expected %s to equal %s", tostring(v), tostring(x)), 2)
		end
	end
	function e.ok()
		if v == nil or v == false then
			error("expected value to be ok, got " .. tostring(v), 2)
		end
	end
	return e
end

local cache = {}
local load

-- A fake ModuleScript instance: children are the sibling .luau files of an init module.
local function instance(path: string, parent: any?)
	return { path = path, Parent = parent }
end

local function fakeRequire(inst: any)
	if cache[inst.path] == nil then
		cache[inst.path] = load(inst)
	end
	return cache[inst.path]
end

function load(inst: any)
	local env = {
		script = inst,
		require = fakeRequire,
		game = game,
		Random = Random,
		DateTime = DateTime,
		task = task,
		describe = describe,
		it = it,
		expect = expect,
	}
	local chunk = luau.load(fs.readFile(inst.path), { debugName = inst.path, environment = env })
	return chunk()
end

local root = instance("src/init.luau")
for _, file in fs.readDir("src") do
	local name = string.match(file, "^(%w+)%.luau$")
	if name and name ~= "init" then
		root[name] = instance("src/" .. file, root)
	end
end

for _, file in fs.readDir("src") do
	if string.match(file, "%.spec%.luau$") then
		local spec = load(instance("src/" .. file, root))
		spec()
	end
end

-- Let spawned threads (flush loops, flag reloads) settle before reporting.
task.wait(0.05)
print(string.format("lucida roblox specs: %d passed, %d failed", passed, failed))
process.exit(if failed > 0 or passed == 0 then 1 else 0)
