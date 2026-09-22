-- SPDX-License-Identifier: ISC
-- The instructions whose size letter, not their operands, says how
-- wide they are, against gas, in each mode.
--
-- The prefix asks for the width the mode does not give by default, so
-- the same letter means the opposite byte in 16-bit code: `lretw` is
-- cb there and 66 cb in 32-bit code.  A table of fixed bytes gets one
-- mode right and the other wrong, and the wrong one only shows up
-- when a boot setup runs.
--
--   lua5.4 test/asbare.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local lua = os.getenv("LUA") or "lua5.4"
local drive = here .. "/../drive.lua"
local dir = (os.getenv("TMPDIR") or "/tmp") .. "/comp-asbare-" ..
	tostring(os.time())

local function has(p)
	local f = io.popen("command -v " .. p .. " 2>/dev/null")
	local s = f:read("l")

	f:close()
	return s ~= nil and s ~= ""
end

if not has("as") or not has("objdump") then
	tap.skipall("no binutils for the bare instruction differential")
	return
end

tap.scratch(dir)

-- gas refuses a size letter on the ones long mode does not have, so
-- each mode carries its own list.
local COMMON = {"lret", "lretw", "lretl", "iret", "iretw", "iretl",
		"pushf", "pushfw", "popf", "popfw",
		-- the port instructions and the string ones: the same
		-- rule, and the operands say nothing the opcode does not
		"inb %dx,%al", "inw %dx,%ax", "inl %dx,%eax",
		"outb %al,%dx", "outw %ax,%dx", "outl %eax,%dx",
		"inb $0x20,%al", "outw %ax,$0x20",
		"movsb", "movsw", "movsl", "stosw", "stosl",
		"lodsw", "lodsl", "scasw", "cmpsl", "insw", "outsw"}
local LIST = {
	[16] = {"ret", "retw", "retl", "pusha", "pushaw", "pushal",
		"popa", "popaw", "popal", "pushfl", "popfl"},
	[32] = {"ret", "retw", "retl", "pusha", "pushaw", "pushal",
		"popa", "popaw", "popal", "pushfl", "popfl"},
	[64] = {"ret", "retq", "lretq", "iretq", "pushfq", "popfq",
		"movsq", "stosq", "lodsq", "scasq", "cmpsq"},
}

-- The bytes of .text, as objdump writes them, one instruction a line.
local function bytes(obj)
	local p = io.popen(("objdump -d %s 2>/dev/null"):format(obj))
	local out = {}

	for l in p:lines() do
		local b = l:match("^%s*[0-9a-f]+:\t([0-9a-f ]+)")

		if b then out[#out + 1] = (b:gsub("%s+$", "")) end
	end
	p:close()
	return out
end

local n = 0

for _, bits in ipairs({16, 32, 64}) do
	local list = {}

	for _, m in ipairs(COMMON) do list[#list + 1] = m end
	for _, m in ipairs(LIST[bits]) do list[#list + 1] = m end

	local src = ("%s/b%d.s"):format(dir, bits)
	local f = assert(io.open(src, "w"))

	f:write((".code%d\n"):format(bits))
	for _, m in ipairs(list) do f:write(m, "\n") end
	f:close()

	local gopt = bits == 64 and "--64" or "--32"
	local mopt = bits == 64 and "-m64" or "-m32"
	local g = ("%s/g%d.o"):format(dir, bits)
	local m = ("%s/m%d.o"):format(dir, bits)

	if not os.execute(("as %s -o %s %s 2>/dev/null"):format(gopt, g, src))
	then
		tap.skipall(("gas does not take the %d-bit list"):format(bits))
		os.execute("rm -rf " .. dir)
		return
	end
	if not tap.ok(os.execute(("MCC_PROG=mcc %s %s %s -c -o %s %s " ..
	    ">/dev/null 2>&1"):format(lua, drive, mopt, m, src)),
	    ("the %d-bit list assembles"):format(bits)) then
		n = n + 1
	else
		local a, c = bytes(g), bytes(m)

		for i, insn in ipairs(list) do
			tap.ok(a[i] ~= nil and a[i] == c[i],
				("%s in %d-bit code: %s"):format(insn, bits,
					a[i] or "?"))
			if a[i] ~= c[i] then
				tap.diag(("  gas  %s\n  ours %s")
					:format(a[i] or "-", c[i] or "-"))
			end
			n = n + 1
		end
	end
end
os.execute("rm -rf " .. dir)
if n == 0 then tap.skipall("nothing assembled") end
tap.done()
