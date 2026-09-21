-- SPDX-License-Identifier: ISC
-- The assembler against the real one, over everything the compiler
-- makes in 16-bit mode.
--
-- `.code16gcc` is 32-bit code with prefixes, and a missing prefix is
-- a different instruction that assembles without complaint.  So every
-- test program is built with -m16 and handed to both assemblers.
--
-- The comparison is of what the instructions are, not of the bytes:
-- gas picks the accumulator short form for a load from a fixed
-- address where this assembler picks the ordinary one, which is a
-- byte and not a difference.  Addresses and immediates come out
-- before the comparison for the same reason -- the two lay the code
-- out to the same sizes only when they agree everywhere, and this
-- test is about the instructions.
--
--   lua5.4 test/as16.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local lua = os.getenv("LUA") or "lua5.4"
local dir = (os.getenv("TMPDIR") or "/tmp") .. "/comp-as16"

local function has(p)
	local f = io.popen("command -v " .. p .. " 2>/dev/null")
	local s = f:read("l")

	f:close()
	return s ~= nil and s ~= ""
end

if not has("as") or not has("objdump") then
	tap.skipall("no binutils for the 16-bit differential")
	return
end

os.execute("rm -rf " .. dir .. " && mkdir -p " .. dir)

local sources = {}
do
	local p = io.popen("ls " .. here .. "/c/*.c")

	for l in p:lines() do sources[#sources + 1] = l end
	p:close()
end

local inc = ("-I%s/../include -I%s/../include/hosted"):format(here, here)

-- The instructions, with everything that is a number taken out: an
-- address, an immediate, a branch target.
local STRIP = {
	{"^%s*[0-9a-f]+:\t", ""},
	{"0x[0-9a-f]+", ""},
	{"<[^>]*>", ""},
	{"[0-9a-f][0-9a-f][0-9a-f]+", ""},
	{"%s+$", ""},
}

-- A branch whose only operand is a place in this section: where it
-- lands is a number, and the two assemblers lay the code out to the
-- same sizes only when they agree everywhere.
local function target(l)
	local m, t = l:match("^(%a[%w]*)%s+([0-9a-f]+)$")

	if m and (m:sub(1, 1) == "j" or m == "call" or
		  m:sub(1, 4) == "loop") then
		return m .. " ."
	end
	return l
end

local function insns(obj)
	local p = io.popen(("objdump -d -Mi8086 --no-show-raw-insn %s 2>/dev/null")
		:format(obj))
	local out = {}

	for raw in p:lines() do
		if raw:match("^%s+[0-9a-f]+:") then
			local l = raw

			for _, r in ipairs(STRIP) do
				l = l:gsub(r[1], r[2])
			end
			out[#out + 1] = target((l:gsub("%s+", " ")))
		end
	end
	p:close()
	return out
end

local n = 0

for _, f in ipairs(sources) do
	local b = f:match("([^/]+)%.c$")
	local s = ("%s/%s.s"):format(dir, b)
	-- Through the driver rather than cc.lua: -m16 is a driver flag,
	-- and without it the output is ordinary 32-bit code and this
	-- test quietly checks nothing.
	local cmd = ("MCC_PROG=mcc %s %s/../drive.lua --target=i386 -m16 " ..
		     "-ffreestanding %s -S -o %s %s 2>/dev/null")
		:format(lua, here, inc, s, f)

	if os.execute(cmd) then
		local g = ("%s/%s.g.o"):format(dir, b)
		local m = ("%s/%s.m.o"):format(dir, b)
		local okg = os.execute(("as --32 -o %s %s 2>/dev/null")
			:format(g, s))
		local okm = os.execute(
			("MCC_PROG=mas %s %s/../drive.lua --target=i386 " ..
			 "-c -o %s %s 2>/dev/null"):format(lua, here, m, s))

		if okg and not tap.ok(okm and true or false,
		    b .. ": this assembler takes what gas takes") then
			n = n + 1
		elseif okg then
			local a, c = insns(g), insns(m)
			local same = #a == #c

			if same then
				for i = 1, #a do
					if a[i] ~= c[i] then
						same = false
						tap.diag(("line %d\n  gas  %s\n  ours %s")
							:format(i, a[i], c[i]))
						break
					end
				end
			else
				tap.diag(("gas %d instructions, ours %d")
					:format(#a, #c))
			end
			tap.ok(same, b .. ": the same instructions in 16-bit mode")
			n = n + 1
		end
	end
end
if n == 0 then tap.skipall("nothing compiled for i386 -m16") end
tap.done()
