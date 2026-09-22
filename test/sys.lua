-- SPDX-License-Identifier: ISC
-- The one place this compiler leaves Lua.
--
-- The point is that a backend is complete and honest: it answers every
-- question the front door asks, it says no rather than pretending when
-- its platform cannot do something, and the posix one gives the same
-- answers with luaposix and without it.
--
--   lua5.4 test/sys.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local CALLS = {"uname", "sharedlibs", "executable", "exec", "tmpname"}

-- A fresh copy of the module, with the backend named and luaposix
-- allowed or blocked.  Each one is loaded on its own so that the
-- choice is made again.
local function load(name, noposix)
	for _, m in ipairs{"sys", "sys.posix", "sys.luaos", "posix"} do
		package.loaded[m] = nil
	end
	package.preload.posix = noposix and
		function() error("luaposix blocked for this test") end or nil
	local keep = os.getenv
	local sys = (function()
		-- MCC_SYS cannot be set from inside the process, so the
		-- backend is named by hand.
		local real = require("sys." .. name)

		package.loaded["sys." .. name] = real
		os.getenv = function(k)
			if k == "MCC_SYS" then return name end
			return keep(k)
		end
		local s = require "sys"

		os.getenv = keep
		return s
	end)()

	package.preload.posix = nil
	return sys
end

for _, name in ipairs{"posix", "luaos"} do
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

-- With luaposix and without it, the posix backend has to agree.  This
-- is the check that keeps the fallback honest: it is the path a box
-- with nothing but stock Lua takes, and nothing else exercises it.
do
	local with = load("posix")
	local without = load("posix", true)

	tap.is(without.uname().system, with.uname().system,
		"uname agrees with luaposix and without it")
	tap.is(without.uname().machine, with.uname().machine,
		"the machine name agrees too")

	local function sorted(t)
		local out = {}

		for i, v in ipairs(t) do out[i] = v end
		table.sort(out)
		return table.concat(out, " ")
	end

	local found = false

	for _, d in ipairs{"/usr/lib64", "/usr/lib", "/lib64", "/lib"} do
		local a = sorted(with.sharedlibs(d, "c"))

		if a ~= "" then
			found = true
			tap.is(sorted(without.sharedlibs(d, "c")), a,
				"the shared libraries in " .. d ..
				" agree either way")
			break
		end
	end
	if not found then
		tap.skip("the shared libraries agree either way",
			"no libc.so* found to compare")
	end
	tap.ok(with.exec({"true"}, {}) == true,
		"a program that succeeds is reported as succeeding")
	local ok, why = with.exec({"false"}, {})

	tap.ok(ok == nil and type(why) == "string",
		"a program that fails is reported with a reason")
end

-- A directory whose name holds a space is quoted once, in the backend,
-- and not by every caller.
do
	local sys = load("posix", true)
	local dir = (os.getenv("TMPDIR") or "/tmp") .. "/mcc sys test"

	os.execute("rm -rf '" .. dir .. "' && mkdir -p '" .. dir .. "'")
	local f = assert(io.open(dir .. "/libspaced.so.1", "w"))

	f:write("x")
	f:close()
	local got = sys.sharedlibs(dir, "spaced")

	tap.is(got[1], dir .. "/libspaced.so.1",
		"a directory with a space in its name is quoted once")
	os.execute("rm -rf '" .. dir .. "'")
end

tap.done()
