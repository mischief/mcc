-- SPDX-License-Identifier: ISC
-- A program that says for itself what its image looks like.

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"
local ldscript = require "ldscript"

local dir = (os.getenv("TMPDIR") or "/tmp") .. "/mcc-ldscript"
tap.scratch(dir)

local function write(name, text)
	local f = assert(io.open(dir .. "/" .. name, "w"))

	f:write(text)
	f:close()
end

local function shell(cmd)
	local p = io.popen(cmd .. " 2>&1")
	local out = p:read("a")

	return p:close(), out
end

write("a.c", [[
__attribute__((section(".ktext"))) int early(void) { return 7; }
int normal(void) { return early() + 1; }
__attribute__((section(".kdata"))) int marked = 42;
int plain = 1;
int later;
]])

write("t.script", [[
ENTRY(normal)
__base = 0x100000;
SECTIONS
{
	. = __base;
	.text : {
		__text_start = ABSOLUTE(.);
		*(.ktext)
		*(.text .text.*)
		__text_end = ABSOLUTE(.);
	}
	. = ALIGN(0x1000);
	.data : AT (0x900000) {
		__data_start = ABSOLUTE(.);
		*(.kdata)
		*(.data .data.*)
		PROVIDE (edata = .);
	}
	.bss : { *(.bss .bss.*) }
	_end = .;
	/DISCARD/ : { *(.note.GNU-stack) }
}
]])

local lua = os.getenv("LUA") or "lua5.4"
local mcc = ("%s %s/../drive.lua"):format(lua, here)
local ok, out = shell(("%s -w -c %s/a.c -o %s/a.o"):format(mcc, dir, dir))

if not tap.ok(ok, "the object compiles") then tap.diag(out) end

-- A script says where everything goes, so nothing else is added.
ok, out = shell(("%s -nostdlib -T %s/t.script %s/a.o -o %s/img")
	:format(mcc, dir, dir, dir))
if not tap.ok(ok, "it links against the script") then tap.diag(out) end

-- The script decides the addresses, so read them back out of the image.
local f = assert(io.open(dir .. "/img", "rb"))
local image = f:read("a")

f:close()
local function u16(at) return string.unpack("<I2", image, at + 1) end
local function u64(at) return string.unpack("<I8", image, at + 1) end

tap.ok(image:sub(1, 4) == "\127ELF", "it is an ELF image")
local phoff, phnum = u64(0x20), u16(0x38)
local entry = u64(0x18)

tap.ok(entry >= 0x100000 and entry < 0x101000,
	"the entry symbol is where the script put the text")
tap.ok(phnum == 2, "two segments, one for each permission")

local function ph(i, at) return u64(phoff + i * 56 + at) end

tap.ok(ph(0, 0x10) < 0x101000, "the first segment holds the text")
-- AT() gives the data a load address of its own
tap.ok(ph(1, 0x18) == 0x900000,
	"AT() gave the data a load address of its own")
tap.ok(ph(1, 0x10) == 0x101000, "and it runs where the script said")

-- The parser on its own, over the kernel's script if it is here.
local k = os.getenv("HOME") ..
	"/src/openbsd/sys/arch/amd64/conf/ld.script"
local kf = io.open(k)

if kf then
	local s = ldscript.parse(kf:read("a"))

	kf:close()
	tap.ok(s.entry == "start" and #s.phdrs == 5 and #s.sections > 30,
		"the OpenBSD kernel's own script reads")
else
	tap.skip("no OpenBSD tree here")
end
-- ld.so's script, which spells the relro layout with GNU ld's
-- DATA_SEGMENT functions.
local lf = io.open(os.getenv("HOME") ..
	"/src/openbsd/libexec/ld.so/amd64/ld.script")

if lf then
	local ok, s = pcall(ldscript.parse, lf:read("a"))

	lf:close()
	tap.ok(ok and #s.phdrs >= 9, "OpenBSD ld.so's script reads")
else
	tap.skip("no OpenBSD tree here")
end
tap.done()
