-- SPDX-License-Identifier: ISC
-- One source, one target: compile it with this compiler, and assemble the
-- result twice -- with the system assembler, which says the file is legal,
-- and with our own, which says we can read back what we wrote.
--
--   lua5.4 test/onefile.lua <target> <file.c>

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local target, file = arg[1], arg[2]
if not target or not file then
	io.stderr:write("usage: onefile.lua <target> <file.c>\n")
	os.exit(2)
end

local ESP = os.getenv("HOME") .. "/.espressif/tools/xtensa-esp-elf"

local function xtensabin()
	local p = io.popen("ls -d " .. ESP ..
		"/*/xtensa-esp-elf/bin 2>/dev/null | head -1")
	local d = p:read("l")
	p:close()
	return d
end

local AS = {
	amd64 = {"gcc", "-c"},
	riscv64 = {"riscv64-linux-gnu-as", "-march=rv64g -mabi=lp64d"},
	riscv32 = {"riscv64-linux-gnu-as", "-march=rv32imac_zicsr -mabi=ilp32"},
	arm64 = {"aarch64-linux-gnu-as", ""},
}
if target == "xtensa" then
	local b = xtensabin()
	AS.xtensa = b and {b .. "/xtensa-esp32-elf-gcc",
		"-c -mtext-section-literals -mlongcalls"}
end
local tool = AS[target]
if not tool then tap.skipall("no assembler for " .. target) end
if os.execute("command -v " .. tool[1] .. " >/dev/null 2>&1") ~= true and
   not tool[1]:find("/") then
	tap.skipall("no " .. tool[1])
end

-- our own assembler reads what the RISC-V and Xtensa targets emit
local OURS = {riscv64 = "riscv", riscv32 = "riscv", xtensa = "xtensa"}

local name = file:match("([^/]+)%.c$") or file
local dir = (os.getenv("TMPDIR") or "/tmp") .. "/comp-one-" .. target
os.execute("mkdir -p " .. dir)
local asm = ("%s/%s.s"):format(dir, name)

local src = os.getenv("LUA_SRC")
local inc = ("-I%s/../include -I%s/../include/hosted"):format(here, here)
if src and src ~= "" then
	inc = inc .. " -I" .. src .. " -I" ..
		src:gsub("/[^/]*$", "") .. "/include"
end

local function shell(cmd)
	local p = io.popen(cmd .. " 2>&1")
	local out = p:read("a")
	return p:close(), out
end

local lua = os.getenv("LUA") or "lua5.4"
local ok, out = shell(("%s %s/../cc.lua -t %s %s %s -o %s")
	:format(lua, here, target, inc, file, asm))

if not tap.ok(ok and true or false, name .. " compiles") then
	tap.diag((out:gsub("\n.*", "")))
	tap.done()
end

ok, out = shell(("%s %s -o %s/%s.o %s")
	:format(tool[1], tool[2], dir, name, asm))
if not tap.ok(ok and true or false, name .. " assembles") then
	tap.diag(out)
end

if OURS[target] then
	local as = require "as"
	local f = assert(io.open(asm))
	local text = f:read("a")
	f:close()
	local good, err = pcall(as.assemble, text,
		{arch = OURS[target], xlen = target == "riscv32" and 32 or 64})
	if not tap.ok(good, name .. " assembles with our own") then
		tap.diag(tostring(err))
	end
end
tap.done()
