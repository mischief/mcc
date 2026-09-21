-- SPDX-License-Identifier: ISC
-- The promises the driver makes about flags it takes and ignores.
--
-- A machine flag that mcc does not implement is taken only where the
-- emitter satisfies it already, whatever the caller asks.  Those
-- reasons are written beside each flag in drive.lua, and a reason in
-- a comment is a reason nobody checks.  So they are checked here,
-- over everything the test corpus compiles to.
--
--   lua5.4 test/invariants.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local lua = os.getenv("LUA") or "lua5.4"
local dir = (os.getenv("TMPDIR") or "/tmp") .. "/comp-invariants"

os.execute("rm -rf " .. dir .. " && mkdir -p " .. dir)

local inc = ("-I%s/../include -I%s/../include/hosted"):format(here, here)
local sources = {}
do
	local p = io.popen("ls " .. here .. "/c/*.c")

	for l in p:lines() do sources[#sources + 1] = l end
	p:close()
end

-- Every test program, for both x86 targets.
local made = {}

for _, f in ipairs(sources) do
	local b = f:match("([^/]+)%.c$")

	for _, t in ipairs{"amd64", "i386"} do
		local s = ("%s/%s.%s.s"):format(dir, b, t)
		local cmd = ("MCC_PROG=mcc %s %s/../drive.lua --target=%s " ..
			     "%s -S -o %s %s 2>/dev/null")
			:format(lua, here, t, inc, s, f)

		if os.execute(cmd) then
			made[#made + 1] = {name = b, target = t, path = s}
		end
	end
end
if #made == 0 then
	tap.skipall("nothing compiled")
	return
end
tap.ok(#made > 20, ("%d objects to look at"):format(#made))

-- Each promise: which lines break it, and where it is allowed.
local function sweep(what, pattern, allow)
	local bad = {}

	for _, m in ipairs(made) do
		if not (allow and allow(m)) then
			local f = assert(io.open(m.path))
			local n = 0

			for l in f:lines() do
				if l:find(pattern) then
					n = n + 1
					if n == 1 then
						bad[#bad + 1] =
							m.name .. "." ..
							m.target .. ": " ..
							l:gsub("^%s+", "")
					end
				end
			end
			f:close()
		end
	end
	if not tap.ok(#bad == 0, what) then
		for i = 1, math.min(#bad, 6) do tap.diag(bad[i]) end
		if #bad > 6 then
			tap.diag(("and %d more"):format(#bad - 6))
		end
	end
end

-- `-mno-red-zone`: nothing is ever kept below the stack pointer, so
-- asking for that is asking for what already happens.  A value read
-- back from under %rsp is what would break it.
sweep("nothing is kept below the stack pointer",
      "%-%d+%(%%rsp%)")

-- The vector flags: no vector unit is reached for on its own.  SSE is
-- not in this list -- amd64 keeps a float in %xmm because the ABI
-- says to, and `-mno-sse` is implemented rather than satisfied.
sweep("no mmx register", "%%mm[0-7]%f[%W]")
sweep("no avx register", "%%[yz]mm")
sweep("no vex encoding asked for", "%f[%w]v[a-z]+%s+%%[xyz]mm")

-- x87 is touched only where the ABI puts a value there: a long
-- double, and on i386 a float or double returned from a call.
sweep("no x87 on amd64 outside long double",
      "^\t?f[a-z]+%f[%s]",
      function(m)
	      return m.target ~= "amd64" or
		     m.name:find("ldbl", 1, true) ~= nil or
		     m.name:find("cplx", 1, true) ~= nil
      end)

-- `-mpreferred-stack-boundary=` and `-mstackrealign` ask for an
-- alignment this compiler already keeps.  That one cannot be read out
-- of the assembly, so it is run: every prologue pushes the frame
-- pointer and then takes the stack pointer, so %rbp is what the stack
-- pointer was on entry less the eight the call pushed, and the ABI
-- wanting sixteen at the call leaves %rbp on a boundary.
do
	local prog = dir .. "/stackalign"
	local cmd = ("MCC_PROG=mcc %s %s/../drive.lua -o %s %s/c/" ..
		     "stackalign.c 2>/dev/null"):format(lua, here, prog,
						       here)

	if not os.execute(cmd) then
		tap.ok(false, "the alignment program compiles")
	else
		local p = io.popen(prog .. " 2>/dev/null")
		local said = (p:read("a") or ""):gsub("%s+$", "")

		p:close()
		tap.is(said, "worst 0",
		       "the stack is sixteen aligned at every call")
	end
end

tap.done()
