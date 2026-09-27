-- SPDX-License-Identifier: ISC
-- The one place this compiler leaves Lua.
--
-- The point is that a backend is complete and honest: it answers every
-- question the front door asks, and it says no rather than pretending
-- when its platform cannot do something.  The unix backend is the C
-- module the build makes; LUA_CPATH finds it.
--
--   lua5.4 test/sys.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local CALLS = {"uname", "sharedlibs", "glob", "executable", "exec",
	"tmpname"}

-- A fresh copy of the module with the backend named.  Each one is
-- loaded on its own so that the choice is made again.
local function load(name)
	for _, m in ipairs{"mcc.sys", "mcc.sys.luaos"} do
		package.loaded[m] = nil
	end
	local keep = os.getenv

	-- MCC_SYS cannot be set from inside the process, so the backend
	-- is named by hand.
	os.getenv = function(k)
		if k == "MCC_SYS" then return name end
		return keep(k)
	end
	local sys = require "mcc.sys"

	os.getenv = keep
	return sys
end

for _, name in ipairs{"unix", "luaos"} do
	local sys = load(name)

	tap.is(sys.backend, name, name .. " is the backend it was asked for")
	local missing = {}

	for _, c in ipairs(CALLS) do
		if type(sys[c]) ~= "function" then missing[#missing + 1] = c end
	end
	if #missing > 0 then
		tap.diag("missing: " .. table.concat(missing, " "))
	end
	tap.ok(#missing == 0, name .. " answers every call")

	local u = sys.uname()

	tap.ok(type(u) == "table" and type(u.system) == "string",
		name .. " says what system this is")
	tap.ok(type(sys.sharedlibs("/usr/lib64", "z")) == "table",
		name .. " answers with a list of shared libraries")

	local a, b = sys.tmpname(), sys.tmpname()

	tap.ok(type(a) == "string" and a ~= b,
		name .. " picks a name nothing else has")
end

-- The luaos backend has no shell, and says so rather than failing in a
-- way the caller cannot tell from a link that went wrong.
do
	local sys = load("luaos")
	local ok, why = sys.exec{"true"}

	tap.ok(ok == nil and type(why) == "string",
		"a backend with no shell refuses and gives a reason")
	tap.is(#sys.sharedlibs("/usr/lib64", "z"), 0,
		"a platform with no shared libraries answers with none")
	tap.ok(sys.executable("/nonesuch") == true,
		"making a file runnable succeeds where it means nothing")
end

-- The unix backend agrees with the shell, and runs programs through
-- os.execute.
do
	local sys = load("unix")
	local p = io.popen("uname -s; uname -m")
	local s, m = p:read("l", "l")

	p:close()
	tap.is(sys.uname().system, s:lower(), "uname names the system")
	tap.is(sys.uname().machine, m, "uname names the machine")

	local found = false

	for _, d in ipairs{"/usr/lib64", "/usr/lib", "/lib64", "/lib"} do
		p = io.popen("ls -1 " .. d .. "/libc.so* 2>/dev/null")
		local want = {}

		for l in p:lines() do want[#want + 1] = l end
		p:close()
		if #want > 0 then
			local got = sys.sharedlibs(d, "c")

			table.sort(got)
			table.sort(want)
			found = true
			tap.is(table.concat(got, " "), table.concat(want, " "),
				"the shared libraries in " .. d .. " match ls")
			break
		end
	end
	if not found then
		tap.skip("the shared libraries match ls", "no libc.so* found")
	end

	local t = sys.tmpname()
	local f = assert(io.open(t, "w"))

	f:close()
	tap.ok(sys.executable(t) == true, "a file is made runnable")
	p = io.popen("test -x '" .. t .. "' && echo yes")
	tap.is(p:read("l"), "yes", "and the mode says so")
	p:close()
	local g = sys.glob(t)

	tap.ok(#g == 1 and g[1].path == t and math.type(g[1].mtime) ==
		"integer", "glob gives the path and when it was written")
	os.remove(t)
	local ok, why = sys.executable(t)

	tap.ok(ok == nil and type(why) == "string",
		"a file that is not there cannot be made runnable")
	tap.ok(sys.exec({"true"}, {}) == true,
		"a program that succeeds is reported as succeeding")
	ok, why = sys.exec({"false"}, {})
	tap.ok(ok == nil and type(why) == "string",
		"a program that fails is reported with a reason")

	local dir = (os.getenv("TMPDIR") or "/tmp") .. "/mcc sys test"

	tap.scratch(dir)
	f = assert(io.open(dir .. "/libspaced.so.1", "w"))
	f:write("x")
	f:close()
	tap.is(sys.sharedlibs(dir, "spaced")[1], dir .. "/libspaced.so.1",
		"a directory with a space in its name needs no quoting")
	tap.ok(sys.exec({"test", "-f", dir .. "/libspaced.so.1"}, {}),
		"exec quotes a word with a space")
	os.execute("rm -rf '" .. dir .. "'")
end

-- With nothing named, the unix module is used when it loads, and luaos
-- when it does not.
do
	local function pick(block)
		for _, m in ipairs{"mcc.sys", "mcc.sys.unix", "mcc.sys.luaos"} do
			package.loaded[m] = nil
		end
		package.preload["mcc.sys.unix"] = block and
			function() error("blocked for this test") end or nil
		local b = require("mcc.sys").backend

		package.preload["mcc.sys.unix"] = nil
		return b
	end

	tap.is(pick(true), "luaos", "no unix module picks luaos")
	tap.is(pick(false), "unix", "the unix module is picked when it loads")
end

tap.done()
