-- SPDX-License-Identifier: ISC
-- The 16-bit half, on the machine.
--
-- Everything else here runs code the processor reads in 32 or 64-bit
-- mode.  `.code16gcc` is a different encoding of the same
-- instructions, and nothing tested it by running it: a missing
-- operand size prefix turns `movswl` into `movsww` and the assembler
-- is happy either way.  So: a boot sector, a C program that writes
-- to the serial port, and qemu.  The answers are compared against
-- the same C compiled for the host and run there.
--
--   lua5.4 test/rmode.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

-- The commands below run from a directory of their own, so every path
-- handed to them has to stand on its own.
local function full(p)
	if p:sub(1, 1) == "/" then return p end

	local h = io.popen("pwd")
	local cwd = h:read("l")

	h:close()
	return cwd .. "/" .. p
end

here = full(here)

local lua = os.getenv("LUA") or "lua5.4"
local drive = here .. "/../drive.lua"
-- A directory of this run's own: two checkouts running the test at
-- once wrote into one and each read the other's floppy.
local dir = os.tmpname()

os.remove(dir)
dir = dir .. "-rmode"

local function has(p)
	local f = io.popen("command -v " .. p .. " 2>/dev/null")
	local s = f:read("l")

	f:close()
	return s ~= nil and s ~= ""
end

if not has("qemu-system-x86_64") or not has("ld") or
   not has("objcopy") or not has("gcc") then
	tap.skipall("no qemu, binutils or gcc for the real mode test")
	return
end

os.execute("rm -rf " .. dir .. " && mkdir -p " .. dir)

local function run(cmd)
	return os.execute(("cd %s && %s >/dev/null 2>&1"):format(dir, cmd))
end

-- The same, for a command that says where its own output goes.
local function runout(cmd)
	return os.execute(("cd %s && %s"):format(dir, cmd))
end

local function mcc(args)
	return run(("MCC_PROG=mcc %s %s %s"):format(lua, drive, args))
end

local src = here .. "/c"

-- The flags a kernel's boot setup is built with, so that the path
-- being run is the one that matters: sixteen bit, i386, and the
-- three-register convention nothing else here exercises.
if not tap.ok(mcc(("-m16 -march=i386 -mregparm=3 -ffreestanding " ..
    "-fno-pic -Os -c -o rm.o %s/realmode.c"):format(src)) and
    mcc("-m16 -c -o entry.o " .. src .. "/realmode-entry.S") and
    mcc("-m16 -c -o boot.o " .. src .. "/realmode-boot.S"),
    "the 16-bit program compiles") then
	tap.done()
	return
end
if not tap.ok(run(("ld -m elf_i386 -T %s/realmode.ld -o rm.elf " ..
    "boot.o entry.o rm.o"):format(src)) and
    run("objcopy -O binary rm.elf rm.img") and
    run("cp rm.img fd.img && truncate -s 1474560 fd.img"),
    "and links into a floppy") then
	tap.done()
	return
end

-- The same lines, for the host, as the answer to compare against.
local want = {}
do
	if not tap.ok(run(("gcc -w -DHOST -o host %s/realmode.c")
	    :format(src)) and true or false,
	    "the same lines build for the host") then
		tap.done()
		return
	end

	local p = io.popen(dir .. "/host 2>/dev/null")

	for l in p:lines() do want[#want + 1] = (l:gsub("\r$", "")) end
	p:close()
end

runout("timeout 60 qemu-system-x86_64 -drive file=fd.img,format=raw," ..
    "if=floppy -boot a -nographic -no-reboot -display none " ..
    "-serial mon:stdio </dev/null > out.txt 2>&1")

local got = {}
do
	local f = io.open(dir .. "/out.txt")
	local on = false

	for raw in (f and f:lines() or function() end) do
		local l = raw:gsub("\r", "")
			     :gsub("^Booting from Floppy%.%.", "")

		if l:find("rm start", 1, true) then on = true end
		if on then got[#got + 1] = l end
		if l == "rm done" then break end
	end
	if f then f:close() end
end

if not tap.ok(#want > 0 and #got == #want,
    ("the program runs in real mode and says %d lines"):format(#want)) then
	tap.diag(("host %d lines, real mode %d"):format(#want, #got))
	for i = 1, #got do tap.diag("got  " .. got[i]) end
	for i = 1, #want do tap.diag("want " .. want[i]) end
	tap.done()
	return
end
for i = 1, #want do
	if not tap.is(got[i], want[i], "line " .. i) then break end
end
tap.done()
