-- SPDX-License-Identifier: ISC
-- mobjcopy against GNU objcopy: the flat image a boot block is written
-- as, and the stripped kernel a release set carries.

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local dir = (os.getenv("TMPDIR") or "/tmp") .. "/mcc-objcopy"
tap.scratch(dir)

local function shell(cmd)
	local p = io.popen(("cd %s && (%s) 2>&1"):format(dir, cmd))
	local out = p:read("a")

	return p:close(), out
end

local function write(name, text)
	local f = assert(io.open(dir .. "/" .. name, "w"))

	f:write(text)
	f:close()
end

local pwd = io.popen("pwd"):read("l")
local root = here:sub(1, 1) == "/" and here or pwd .. "/" .. here
local lua = os.getenv("LUA") or "lua5.4"
local mobjcopy = ("%s %s/../objcopy.lua"):format(lua, root)

if not tap.gnu("objcopy", 2, 30) or not tap.gnu("as", 2, 30) or
   not shell("command -v gcc >/dev/null") then
	tap.skipall("no GNU objcopy, as and gcc to compare against")
end

-- A boot block: sixteen-bit code and data, linked to run at zero, and
-- the same linked with load addresses apart from the run addresses.
write("bb.s", [[
	.code16
	.text
	.globl start
start:	jmp	1f
	.ascii	"hello"
1:	movw	$msg, %si
	hlt
	.data
msg:	.asciz	"boot data"
	.section .rodata
	.byte 1,2,3
	.bss
	.space 64
]])
write("lma.ld", "SECTIONS { .text 0x1000 : AT(0x100) { *(.text) } " ..
	".data 0x2000 : AT(0x180) { *(.data) } " ..
	".rodata : AT(0x200) { *(.rodata) } }\n")
local ok = shell("as --32 bb.s -o bb.o && " ..
	"ld -m elf_i386 -N -Ttext 0 -e start -o bb bb.o && " ..
	"ld -m elf_i386 -N -T lma.ld -e start -o bbl bb.o")
tap.ok(ok, "the boot blocks link")
for _, f in ipairs{"bb", "bbl"} do
	shell(("objcopy -O binary %s %s.g && %s -O binary %s %s.m")
		:format(f, f, mobjcopy, f, f))
	local same = shell(("cmp %s.g %s.m"):format(f, f))

	tap.ok(same, "-O binary matches objcopy on " .. f)
end
local _, g = shell("objcopy -v -O binary bb v.g")
local _, m = shell(mobjcopy .. " -v -O binary bb v.m")
tap.is(m:gsub("v%.m", "X"), g:gsub("v%.g", "X"), "-v says what it copies")

-- A kernel with a ramdisk: everything but two symbols goes, and it
-- still runs.
write("k.c", [[
#include <stdio.h>
int rd_root_size = 42;
char rd_root_image[16] = "img";
static int hidden_local = 5;
int main(void)
{
	printf("%d %s %d\n", rd_root_size, rd_root_image, hidden_local);
	return 0;
}
]])
tap.ok(shell("gcc -g -static -o k k.c"), "the program links")
for _, how in ipairs{"-S -R .comment -K rd_root_size -K rd_root_image",
		     "-g -x -R .comment -K rd_root_size -K rd_root_image",
		     "-S -R .comment"} do
	shell(("objcopy %s k k.g && %s %s k k.m"):format(how, mobjcopy, how))
	local _, sg = shell("readelf -SW k.g | awk '/^ *\\[/{print $2}'")
	local _, sm = shell("readelf -SW k.m | awk '/^ *\\[/{print $2}'")
	local _, ng = shell("nm k.g 2>/dev/null | awk '{print $NF}' | sort")
	local _, nm = shell("nm k.m 2>/dev/null | awk '{print $NF}' | sort")
	local _, run = shell("./k.m")

	tap.ok(sg == sm and ng == nm and run == "42 img 5\n",
		how .. " leaves what objcopy does")
end
tap.done()
