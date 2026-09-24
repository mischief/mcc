-- SPDX-License-Identifier: ISC
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

-- No compiled test here runs for a minute.  Anything that does is a
-- miscompile, and the answer wanted is a failure, not a hung harness.
local RUNCAP = "timeout 60 "

-- OpenBSD has no gcc; its cc is the reference there.
local hostcc = os.execute("command -v gcc >/dev/null 2>&1") and "gcc" or "cc"

local TOOL = {
	amd64   = {cc = hostcc, run = ""},
	-- 32-bit x86 runs here, so no emulator.  The reference keeps its
	-- floating point in sse registers rather than on the x87 stack,
	-- because ours is a software runtime that rounds once.
	i386    = {cc = "gcc -m32 -msse2 -mfpmath=sse", run = ""},
	riscv64 = {cc = "riscv64-linux-gnu-gcc -static", run = "qemu-riscv64 "},
	arm64   = {cc = "aarch64-linux-gnu-gcc -static", run = "qemu-aarch64 "},
	-- A bare metal ELF for qemu's generic Xtensa machine: our own reset
	-- code and simcall system calls under newlib.
	xtensa  = xgcc and {
		cc = xgcc .. " -nostartfiles -mlongcalls" ..
		     " -mtext-section-literals -T " .. here0 ..
		     "/xtensa/ld.script " .. here0 .. "/xtensa/crt.S " ..
		     here0 .. "/xtensa/sys.c",
		run = "qemu-system-xtensa -M sim -cpu dc233c -nographic" ..
		      " -monitor none -semihosting -kernel ",
	} or nil,
}
local tool = TOOL[which]
if not tool then tap.skipall("no toolchain for " .. which) end
-- Cases only gcc answers for: clang puts _Bool in a class of its own,
-- and its assembler takes no UTF-8 in a name.
local GCCONLY = {ctype = true, lang = true}
if which == "amd64" and hostcc ~= "gcc" and GCCONLY[arg[2]] then
	tap.skipall(arg[2] .. " is measured against gcc")
end

local dir = (os.getenv("TMPDIR") or "/tmp") .. "/mcc-" .. which ..
	"-" .. (arg[2] or "prog") .. (arg[3] and ("-" .. arg[3]) or "")
tap.scratch(dir)

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
-- and `opt` asks for the peephole, which must not change what the
-- program answers.
local opt = arg[3] == "opt" and "-O1 " or ""
-- `hard` asks for the hardening a kernel builds with, which must not
-- change what the program answers either.
local hard = arg[3] == "hard" and
	"-fcf-protection=branch -fret-clean -mindirect-branch=thunk-extern " ..
	"-mfunction-return=thunk-extern " ..
	"-fstack-protector-strong " or ""

name = ("%s/%s%s%s%s"):format(which, which_src,
	wide == "" and "" or " wide", opt == "" and "" or " opt",
	hard == "" and "" or " hard")

-- Where a case asks the system library something, it says so: the
-- self-hosted harness links our own runtime and has no such library.
local sys = which_src == "va" and "-DVA_SYS " or ""

-- Which standard the reference is built to.  gcc refuses an implicit
-- declaration by default now, and a case about what one answers with
-- has to be built where the language still has them.
local STD = {implicit = "-std=gnu89 ",
	     -- the reference compiler's intrinsics want the features
	     simd = "-msse4.2 -mavx2 -mpclmul -mpopcnt -mlzcnt -mbmi "}
local std = STD[which_src] or ""

local ok, out = shell(("%slua5.4 %s/../cc.lua -t %s %s%s%s-I%s/../include %s -o %s/prog.s")
	:format(wide, here, which, opt, hard, sys, here, src, dir))
if not ok then fail("compile", out) end

-- A 128-bit scalar has 64-bit halves; everything else this runtime is
-- built for has 32-bit ones.
local half = which_src == "i128" and "-DWIDE_HALF=8 " or ""
local rt = half .. here .. "/../rt/softfp.c " ..
	here .. "/../rt/varargs.c " .. here .. "/../rt/bits.c " ..
	here .. "/../rt/atomic.c " ..
	here .. "/../rt/wide.c " .. here .. "/../rt/widefp.c -lm"
-- OpenBSD's crtbegin.o and libc have the stack protector's runtime.
if hard ~= "" then
	local ssp = io.popen("uname -s"):read("l") == "OpenBSD" and "" or
		here .. "/../rt/ssp.c "

	rt = here .. "/thunk-amd64.s " .. ssp .. rt
end
ok, out = shell(("%s -w %s-o %s/mine %s %s/prog.s %s")
	:format(tool.cc, std .. sys, dir, main, dir, rt))
if not ok then fail("assemble/link", out) end

-- The Xtensa core the emulator offers has no high word multiply, which
-- every espressif libgcc soft float routine uses, so a reference built for
-- the target cannot run.  These answers do not depend on the machine, so
-- the reference is built and run here instead.
local HOSTREF = {xtensa = {flt = true, abi = true}}
local hostref = HOSTREF[which] and HOSTREF[which][which_src]

if hostref then
	ok, out = shell(("gcc -O0 -w %s-o %s/ref %s %s -lm")
		:format(sys, dir, main, src))
else
	ok, out = shell(("%s -O0 -w %s-o %s/ref %s %s -lm")
		:format(tool.cc, std .. sys, dir, main, src))
end
if not ok then fail("reference build", out) end

-- Under a timeout: a miscompile that loops forever otherwise hangs
-- the run, and killing the harness leaves the program orphaned onto
-- init with a core to itself.
local _, mine = shell(RUNCAP .. tool.run .. dir .. "/mine")
local _, ref  = shell(RUNCAP .. (hostref and "" or tool.run) ..
		      dir .. "/ref")

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
