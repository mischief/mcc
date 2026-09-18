-- Differential test: compile test/c/prog.c with this compiler and with the
-- system one, run both against the same driver, and compare the output.
--
--   lua5.4 test/cc.lua [amd64|riscv64]

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"
local which = arg[1] or "amd64"

-- The Xtensa toolchain is not on the path; find it where the ESP-IDF
-- installer puts it.
local function xcc()
	local p = io.popen("ls -d " ..
		os.getenv("HOME") .. "/.espressif/tools/xtensa-esp*-elf/*/" ..
		"xtensa-esp*-elf/bin/xtensa-esp32-elf-gcc 2>/dev/null")
	local path = p:read("l")
	p:close()
	return path
end

local here0 = arg[0]:match("^(.*)/[^/]*$") or "."
local xgcc = xcc()

local TOOL = {
	amd64   = {cc = "gcc", run = ""},
	riscv64 = {cc = "riscv64-linux-gnu-gcc -static", run = "qemu-riscv64 "},
	-- A bare metal ELF for qemu's generic Xtensa machine: our own reset
	-- code and simcall system calls under newlib.
	xtensa  = xgcc and {
		cc = xgcc .. " -nostartfiles -mlongcalls" ..
		     " -mtext-section-literals -T " .. here0 ..
		     "/xtensa/ld.script " .. here0 .. "/xtensa/crt.S " ..
		     here0 .. "/xtensa/sys.c",
		run = "timeout 180 qemu-system-xtensa -M sim -cpu dc233c -nographic" ..
		      " -monitor none -semihosting -kernel ",
	} or nil,
}
local tool = TOOL[which]
if not tool then tap.skipall("no toolchain for " .. which) end

local dir = (os.getenv("TMPDIR") or "/tmp") .. "/mcc-" .. which ..
	"-" .. (arg[2] or "prog") .. (arg[3] and ("-" .. arg[3]) or "")
os.execute("rm -rf " .. dir .. " && mkdir -p " .. dir)

local function shell(cmd)
	local p = io.popen(cmd .. " 2>&1")
	local out = p:read("a")
	return p:close(), out
end

local name

local function fail(what, out)
	tap.ok(false, name .. ": " .. what)
	tap.diag(out or "")
	tap.done()
end

local which_src = arg[2] or "prog"
local src = here .. "/c/" .. which_src .. ".c"
local main = here .. "/c/" ..
	(which_src == "prog" and "main" or (which_src .. "main")) .. ".c"

-- A third argument asks for the 32-bit treatment of eight-byte scalars on a
-- 64-bit target: the lowering is the same code, and this is the only way to
-- run it against a compiler that has the type natively.
local wide = arg[3] == "wide" and "WIDE=1 " or ""

name = ("%s/%s%s"):format(which, which_src, wide == "" and "" or " wide")

local ok, out = shell(("%slua5.4 %s/../cc.lua -t %s -I%s/../include %s -o %s/prog.s")
	:format(wide, here, which, here, src, dir))
if not ok then fail("compile", out) end

local rt = here .. "/../rt/softfp.c " .. here .. "/../rt/varargs.c " ..
	here .. "/../rt/wide.c " .. here .. "/../rt/widefp.c -lm"
ok, out = shell(("%s -w -o %s/mine %s %s/prog.s %s")
	:format(tool.cc, dir, main, dir, rt))
if not ok then fail("assemble/link", out) end

-- The Xtensa core the emulator offers has no high word multiply, which
-- every espressif libgcc soft float routine uses, so a reference built for
-- the target cannot run.  These answers do not depend on the machine, so
-- the reference is built and run here instead.
local HOSTREF = {xtensa = {flt = true, abi = true}}
local hostref = HOSTREF[which] and HOSTREF[which][which_src]

if hostref then
	ok, out = shell(("gcc -O0 -w -o %s/ref %s %s -lm")
		:format(dir, main, src))
else
	ok, out = shell(("%s -O0 -w -o %s/ref %s %s -lm")
		:format(tool.cc, dir, main, src))
end
if not ok then fail("reference build", out) end

local _, mine = shell(tool.run .. dir .. "/mine")
local _, ref  = shell((hostref and "" or tool.run) .. dir .. "/ref")

local n = select(2, mine:gsub("\n", ""))

if not tap.ok(mine == ref,
    ("%s matches gcc on %d lines"):format(name, n)) then
	local a, b = {}, {}
	for l in mine:gmatch("[^\n]*") do a[#a + 1] = l end
	for l in ref:gmatch("[^\n]*") do b[#b + 1] = l end
	for i = 1, math.max(#a, #b) do
		if a[i] ~= b[i] then
			tap.diag(("line %d\n  mine %s\n  gcc  %s")
				:format(i, tostring(a[i]), tostring(b[i])))
		end
	end
end
tap.done()
