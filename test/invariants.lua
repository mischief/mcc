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

tap.scratch(dir)

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
-- double, and on i386 a float or double returned from a call.  The asm
-- case also asks for it by name, with t and u constraints.
sweep("no x87 on amd64 outside long double",
      "^\t?f[a-z]+%f[%s]",
      function(m)
	      return m.target ~= "amd64" or
		     m.name:find("ldbl", 1, true) ~= nil or
		     m.name:find("cplx", 1, true) ~= nil or
		     m.name == "asm"
      end)

-- `-mstackrealign` asks for an alignment this compiler already keeps,
-- and so does `-mpreferred-stack-boundary=` above two.  That one cannot be read out
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

-- The same on i386, where the static walk cannot go.  The call there
-- pushes four, so a prologue that pushes the frame pointer leaves it
-- eight past a boundary rather than on one.
do
	local o = dir .. "/stackalign32.o"
	local prog = dir .. "/stackalign32"
	local cmd = ("MCC_PROG=mcc %s %s/../drive.lua -m32 -c -o %s " ..
		     "%s/c/stackalign32.c 2>/dev/null")
		:format(lua, here, o, here)
	local link = ("gcc -m32 -no-pie -w -o %s %s %s/../rt/softfp.c " ..
		      "%s/../rt/widefp.c -lm 2>/dev/null")
		:format(prog, o, here, here)

	if not os.execute(cmd) or not os.execute(link) then
		tap.skip("no 32-bit link for the i386 alignment check")
	else
		local p = io.popen(prog .. " 2>/dev/null")
		local said = (p:read("a") or ""):gsub("%s+$", "")

		p:close()
		tap.is(said, "worst 8",
		       "and on i386, where a call pushes four")
	end
end

-- `-msave-args` asks for the incoming register arguments to be put
-- in the frame at entry so a debugger can read them back.  Every
-- prologue does that already, for every parameter, whether or not
-- the body looks at one.  openbsd builds its kernel with it.
do
	local src = dir .. "/saveargs.c"
	local f = assert(io.open(src, "w"))

	f:write("long f(long a, long b, long c, long d, long e, long g)\n" ..
		"{\n\treturn 1;\n}\n")
	f:close()

	local out = dir .. "/saveargs.s"
	local cmd = ("MCC_PROG=mcc %s %s/../drive.lua --target=amd64 " ..
		     "-S -o %s %s 2>/dev/null"):format(lua, here, out, src)
	local n = 0

	if not os.execute(cmd) then
		tap.ok(false, "the argument program compiles")
	else
		local h = assert(io.open(out))

		for l in h:lines() do
			if l:match("^\tmovq\t%%%w+,%-%d+%(%%rbp%)$") then
				n = n + 1
			end
		end
		h:close()
		tap.ok(n >= 6, ("every incoming argument is put in the " ..
			"frame at entry (%d of 6)"):format(n))
	end
end

-- The rounding in front of that mask does a different job: it is
-- what makes the block big enough.  With the mask alone the stack
-- stays aligned and an alloca of a size that is nine past a multiple
-- of sixteen hands back eight fewer bytes than it was asked for, and
-- the write past the end lands in the frame above it.  Two blocks of
-- the same size must not overlap, whatever the size is.
for _, t in ipairs{"amd64", "i386"} do
	local prog = ("%s/allocsize.%s"):format(dir, t)
	local o = prog .. ".o"
	local built

	if t == "amd64" then
		built = os.execute(("MCC_PROG=mcc %s %s/../drive.lua -o %s " ..
			"%s/c/allocsize.c 2>/dev/null")
			:format(lua, here, prog, here))
	else
		built = os.execute(("MCC_PROG=mcc %s %s/../drive.lua -m32 " ..
			"-c -o %s %s/c/allocsize.c 2>/dev/null")
			:format(lua, here, o, here)) and
			os.execute(("gcc -m32 -no-pie -w -o %s %s 2>/dev/null")
			:format(prog, o))
	end
	if not built then
		tap.skip("no " .. t .. " link for the alloca size check")
	else
		local p = io.popen(prog .. " 2>/dev/null")
		local said = (p:read("a") or ""):gsub("%s+$", "")

		p:close()
		tap.is(said, "slack 0",
		       "alloca gives back what it was asked for on " .. t)
	end
end

-- The same property read out of the text rather than run, which
-- reaches every call rather than the seven the program above makes.
-- The stack descends by a known amount from the entry to each call,
-- and the ABI wants it on a sixteen byte boundary there.
--
-- amd64 only.  On i386 a function that answers with a record pops the
-- hidden pointer itself, so the caller adds back four less than it
-- took, and the arithmetic in the text does not balance.  Nothing in
-- the text says which callee does that, so a reader of the text alone
-- cannot tell that convention from a real fault; i386 is covered by
-- running it instead.
do
	local PUSH, POP = "pushq", "popq"
	local calls, bad, gave = 0, {}, 0

	for _, m in ipairs(made) do
		if m.target == "amd64" then
			local f = assert(io.open(m.path))
			local off, fn, give = nil, nil, nil
			-- The register an `and $-16` just rounded, so
			-- that taking it off the stack pointer leaves
			-- the alignment where it was.  Only the line
			-- immediately before counts, which is where
			-- alloca puts it.
			local rounded = nil

			for l in f:lines() do
				local name = l:match("^([A-Za-z_$][%w.$]*):")
				local mn, ops = l:match("^\t(%S+)\t?(.*)$")

				if name then
					if fn and give then gave = gave + 1 end
					fn, off, give = name, 8, nil
				elseif give or not mn or
				       mn:sub(1, 1) == "." or not fn then
					-- nothing to do
				elseif false then
					-- unreachable; keeps the chain
					-- below reading as one list
				elseif mn == PUSH then
					off = off + 8
				elseif mn == POP then
					off = off - 8
				elseif (mn == "subq" or mn == "addq") and
				       ops:sub(-4) == "%rsp" then
					local k = ops:match("^%$(%-?%d+),")
					local r = ops:match("^(%%%w+),")

					if k and mn == "subq" then
						off = off + tonumber(k)
					elseif k then
						off = off - tonumber(k)
					elseif r and r == rounded then
						-- a whole number of
						-- sixteens, so the
						-- alignment is unmoved
					else
						give = true
					end
				elseif mn == "leaq" and
				       ops:match("^(%-?%d+)%(%%rsp%),%%rsp$") then
					-- the same as an add, and the
					-- code table writes it this way
					-- where the flags matter
					off = off -
					      ops:match("^(%-?%d+)%(")
				elseif ops:sub(-4) == "%rsp" and
				       mn ~= "cmpq" and mn ~= "testq" then
					give = true
				elseif mn == "leave" then
					off = 8
				elseif mn == "andq" and
				       ops:match("^%$%-16,(%%%w+)$") then
					rounded = ops:match("(%%%w+)$")
					goto kept
				elseif mn:sub(1, 4) == "call" then
					calls = calls + 1
					if off % 16 ~= 0 then
						bad[#bad + 1] = ("%s %s: %d off at %s"):
							format(m.name, fn,
							       off % 16, ops)
					end
				end
				rounded = nil
				::kept::
			end
			f:close()
			if fn and give then gave = gave + 1 end
		end
	end
	-- Nothing is allowed to be unfollowable: an alloca rounds its
	-- size to a multiple of sixteen before taking it off the stack,
	-- so the alignment survives whatever the size turns out to be,
	-- and that is the only thing that moves the stack by a value.
	tap.ok(calls > 500 and gave == 0,
	       ("%d calls walked, %d bodies with a stack this cannot " ..
		"follow"):format(calls, gave))
	if not tap.ok(#bad == 0,
	    "the stack is on a boundary at every call it can read") then
		for i = 1, math.min(#bad, 6) do tap.diag(bad[i]) end
	end
end

tap.done()
