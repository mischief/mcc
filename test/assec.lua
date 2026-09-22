-- SPDX-License-Identifier: ISC
-- .pushsection, .popsection and .previous against gas, by what lands in
-- each section.
--
-- A push keeps the section in hand and the one `.previous` names, and
-- a pop puts back both.  Putting back only the first sent a `.previous`
-- after the pop into the pushed section, and linux's xen-asm.S then
-- put its code into .discard.annotate_insn.
--
--   lua5.4 test/assec.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local lua = os.getenv("LUA") or "lua5.4"
local drive = here .. "/../drive.lua"

local function has(p)
	local f = io.popen("command -v " .. p .. " 2>/dev/null")
	local s = f:read("l")

	f:close()
	return s ~= nil and s ~= ""
end

if not has("as") or not has("objcopy") or not has("od") then
	tap.skipall("no binutils for the section differential")
	return
end

local dir = tap.scratch((os.getenv("TMPDIR") or "/tmp") .. "/comp-assec")
local src = dir .. "/s.s"
local f = assert(io.open(src, "w"))

f:write([[
	.text
	nop
	.section .init.text,"ax"
	.pushsection .hints,"a"
	.long 0x11223344
	.popsection
	int3
	.previous
	ret
	.pushsection .a,"a"
	.byte 1
	.pushsection .b,"a"
	.byte 2
	.popsection
	.byte 3
	.previous
	.byte 4
	.popsection
	hlt
	.previous
	cli
]])
f:close()

local g, m = dir .. "/g.o", dir .. "/m.o"

if not os.execute(("as --64 -o %s %s 2>/dev/null"):format(g, src)) then
	tap.skipall("gas does not take the sample")
	return
end
if not tap.ok(os.execute(("MCC_PROG=mcc %s %s -c -o %s %s >/dev/null 2>&1")
    :format(lua, drive, m, src)), "the sample assembles") then
	tap.done()
	return
end

local function bytes(obj, sec)
	local p = io.popen(("objcopy -O binary --only-section=%s %s " ..
		"/dev/stdout 2>/dev/null | od -An -tx1"):format(sec, obj))
	local s = p:read("a"):gsub("%s", "")

	p:close()
	return s
end

for _, sec in ipairs({".text", ".init.text", ".hints", ".a", ".b"}) do
	local want, got = bytes(g, sec), bytes(m, sec)

	if not tap.ok(want == got, sec .. " holds what gas puts there") then
		tap.diag(("gas %s, ours %s"):format(want, got))
	end
end
tap.done()
