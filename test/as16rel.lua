-- SPDX-License-Identifier: ISC
-- 16-bit code against gas: the immediates, the addresses, and the
-- relocations over them.
--
-- The relocation has to be as wide as the field.  A four byte one on
-- `movw $_end, %dx` writes two bytes past the immediate and destroys
-- the instruction after it, which a boot setup only shows by running
-- off into its own bss.
--
-- `(%bx,%si)` is its own encoding, not `(%ebx,%esi)` with an address
-- size prefix: taking it for the other one reads the top half of a
-- register nothing in real mode set.
--
--   lua5.4 test/as16rel.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local lua = os.getenv("LUA") or "lua5.4"
local drive = here .. "/../drive.lua"
local dir = (os.getenv("TMPDIR") or "/tmp") .. "/comp-as16rel-" ..
	tostring(os.time())

local function has(p)
	local f = io.popen("command -v " .. p .. " 2>/dev/null")
	local s = f:read("l")

	f:close()
	return s ~= nil and s ~= ""
end

if not has("as") or not has("objdump") then
	tap.skipall("no binutils for the 16-bit relocation differential")
	return
end

tap.scratch(dir)

local BODY = [[
.code16
.text
	movw	$tail, %dx
	movw	$tail+3, %cx
	movw	$head, %bx
	movl	$tail, %esi
	movw	$0x1234, %ax
	pushw	$tail
	movw	$tail, %di
	movw	4(%bx,%si), %dx
	movw	%dx, 2(%bp)
	movw	(%si), %cx
	movb	(%bx,%di), %al
	movw	(%bp,%si), %ax
	movw	0x200(%bp,%di), %bx
	movw	(%bx), %si
	movw	(%di), %bp
	movw	tail(%bx), %ax
	movl	4(%ebx,%esi,2), %edx
head:
	nop
tail:
	nop
]]

local src = dir .. "/r.s"
local f = assert(io.open(src, "w"))

f:write(BODY)
f:close()

-- The instructions and the relocations, with the addresses taken out:
-- the two assemblers name a local symbol differently and this test is
-- about the widths.
local function text(obj)
	local p = io.popen(("objdump -d -r -m i8086 %s 2>/dev/null")
		:format(obj))
	local out = {}

	for l in p:lines() do
		local b, m = l:match("^%s*[0-9a-f]+:\t([0-9a-f ]+)\t(.*)$")

		if b then
			out[#out + 1] = b:gsub("%s+$", "") .. "|" ..
				m:gsub("%s+", " ")
		else
			local r = l:match("^%s*[0-9a-f]+:%s+(R_%S+)")

			if r then out[#out + 1] = "reloc " .. r end
		end
	end
	p:close()
	return out
end

local g, m = dir .. "/g.o", dir .. "/m.o"

if not os.execute(("as --32 -o %s %s 2>/dev/null"):format(g, src)) then
	tap.skipall("gas does not take the sample")
	os.execute("rm -rf " .. dir)
	return
end
if not tap.ok(os.execute(("MCC_PROG=mcc %s %s -m32 -c -o %s %s " ..
    ">/dev/null 2>&1"):format(lua, drive, m, src)), "the sample assembles")
then
	os.execute("rm -rf " .. dir)
	tap.done()
	return
end

local a, c = text(g), text(m)

tap.ok(#a > 0 and #a == #c,
	("gas wrote %d lines, ours %d"):format(#a, #c))
for i = 1, math.max(#a, #c) do
	if a[i] ~= c[i] then
		tap.diag(("line %d\n  gas  %s\n  ours %s")
			:format(i, a[i] or "-", c[i] or "-"))
	end
	tap.ok(a[i] == c[i], "16-bit: " .. (a[i] or c[i] or "?"))
end
os.execute("rm -rf " .. dir)
tap.done()
