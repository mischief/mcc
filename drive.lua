-- SPDX-License-Identifier: ISC
-- The driver, in the shape the rest of the world expects one.
--
-- It takes the flags a C compiler takes, so that a build that says `CC=`
-- and `LD=` can say them here.  What it does not understand it ignores
-- rather than refusing: a build system passes -O2 and -Wall to everything,
-- and neither means anything to a compiler with no optimiser and one
-- opinion about warnings.
--
--	mcc [-c|-S|-E|-shared] [-o out] [-Idir] [-Dname] [-fpic] [-static]
--	    [-nostdlib] [-Ldir] [-lname] [--target=NAME] file...
--
-- `mas` is this with -c, `mld` is this with -nostdlib.
--
-- Stages: a .c becomes assembly, assembly becomes an object, objects
-- become a program.  Each stage stops if the flags say to.

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. here .. "/?/init.lua;" .. package.path

-- The whole driver runs again inside a handler, so an error comes out
-- the way a compiler's does: `file:line: error: what`, and exit 1.  A
-- traceback says where in mcc something went wrong, which is worth
-- having for a fault in mcc and is noise for a fault in the program.
-- So it is printed for the first and not the second.  MCC_TRACEBACK=1
-- prints it always, and MCC_TRACEBACK=0 never.
if not package.loaded["mcc.driven"] then
	package.loaded["mcc.driven"] = true
	local chunk = assert(loadfile(arg[0]))
	local want = os.getenv("MCC_TRACEBACK")
	-- What Lua itself says when the code is wrong, rather than what
	-- mcc says when the input is.
	local LUAFAULT = {"attempt to ", "bad argument", "stack overflow",
			  "table index is ", "assertion failed",
			  "number has no integer", "not enough memory",
			  "invalid ", "wrong number of arguments"}
	local function fault(e)
		if type(e) ~= "string" then return true end
		for _, f in ipairs(LUAFAULT) do
			if e:find(f, 1, true) then return true end
		end
		return false
	end
	-- A handler hands back one value, so the traceback travels with
	-- the error in a table.
	local ok, box = xpcall(chunk, function(e)
		return {e = e, tb = debug.traceback("", 2)}
	end, ...)

	if ok then return end
	local err, tb = box.e, box.tb
	local prog = os.getenv("MCC_PROG") or "mcc"
	local msg = tostring(err)
	local show = want == "1" or (want ~= "0" and fault(err))

	if not show then
		-- mcc's own places in its source say nothing about the
		-- program's, and the program's come first.
		msg = msg:gsub("[^%s:]*%.lua:%d+: ", "")
		local at, what = msg:match("^([^%s:]+:%d+): (.*)$")

		msg = at and (at .. ": error: " .. what) or
			(prog .. ": error: " .. msg)
	end
	io.stderr:write(msg, "\n")
	if show then io.stderr:write(tb or "", "\n") end
	os.exit(1)
end

-- Reading a global that was never set is a mistake here, and a local
-- named later in a file is a global to the code above it.
require("strict").on()
-- Most of what a compile makes is dead a moment later, and what it
-- keeps, the bodies of a header's inline functions held for replay,
-- is large and long lived.  A collector that sweeps only the young
-- objects most of the time suits that: a few percent of a kernel
-- file's time, at the same peak memory.
collectgarbage("generational")

local as = require "as"
local elf = require "elf"
local sys = require "sys"

-- MCC_GCPAUSE trades time for memory: an incremental collector that
-- starts a cycle when the heap has grown by that percent.  150 holds a
-- kernel file to about four fifths of the memory for 7% more time.
local gcpause = tonumber(sys.getenv("MCC_GCPAUSE") or "")

if gcpause then collectgarbage("incremental", gcpause) end

local HOST = "amd64"
local ARCH = {amd64 = "amd64", x86_64 = "amd64", riscv64 = "riscv",
	      riscv32 = "riscv", xtensa = "xtensa", arm64 = "arm64",
	      aarch64 = "arm64", i386 = "amd64", i486 = "amd64",
	      i586 = "amd64", i686 = "amd64"}
-- The tuple names the part; the target is the one code generator that
-- covers them all.
local CPUALIAS = {x86_64 = "amd64", aarch64 = "arm64", i486 = "i386",
		  i586 = "i386", i686 = "i386"}
-- the runtime a program gets when nothing says otherwise
-- The system a program is built for, which decides the entry code, the
-- system call numbers, and what the preprocessor says it is.  It comes
-- from the target tuple, and from the machine this runs on when the
-- tuple says only an architecture.
local SYSTEM = {linux = "linux", openbsd = "openbsd", freebsd = "freebsd",
		netbsd = "netbsd", darwin = "darwin", none = "none",
		elf = "none", macosx = "darwin", apple = "darwin"}

local function system()
	return SYSTEM[sys.uname().system or "linux"] or "linux"
end

-- A target is named by its architecture alone, as `amd64`, or by a
-- tuple, as `x86_64-unknown-openbsd8.0`.  The first part names the
-- machine and the last one that this compiler knows names the system.
local function splittarget(s)
	local parts = {}

	for w in s:gmatch("[^-]+") do parts[#parts + 1] = w end
	local sys
	for i = #parts, 2, -1 do
		-- the system carries a version, as `openbsd8.0` does
		local w = parts[i]:lower():gsub("[%d.]+$", "")

		if SYSTEM[w] then
			sys = SYSTEM[w]
			break
		end
	end
	return parts[1] or s, sys
end

local OS = system()

local CRT = {amd64 = "rt/linux-amd64.s", riscv64 = "rt/linux-riscv.s",
	     riscv32 = "rt/linux-riscv.s", xtensa = "rt/sim-xtensa.s",
	     arm64 = "rt/linux-arm64.s"}
-- The arithmetic a target cannot do in instructions, which any object may
-- need, and the few library calls a program does.  A shared object gets
-- only the first: it has an interpreter or a program around it for the
-- rest, and an unused system call in it would be an import nothing
-- satisfies.
local RTMATH = {"rt/softfp.c", "rt/wide.c", "rt/widefp.c", "rt/bits.c",
		"rt/atomic.c", "rt/dso.c", "rt/varargs.c", "rt/complex.c"}
local RTIO = {"rt/miniio.c", "rt/ministr.c"}

local o = {
	target = HOST, os = OS, out = nil, stop = nil, pic = false,
	shared = false, retclean = false, cet = false, retpoline = false,
	rethunk = false,
	nosse = false, shortwchar = false,
	guardsym = nil, guardfail = nil, guardreg = nil,
	nomarkers = false, lang = nil, syslink = false,
	dynamic = false, interp = nil, needed = {}, sysroot = "",
	stdc = "201710L",
	ssp = nil,
	nostdlib = false, visibility = nil,
	defs = {}, incs = {}, libdirs = {}, libs = {},
	files = {}, wl = {}, preinc = {}, verbose = false, entry = nil,
	soname = nil,
	opt = 0,
}

-- Whichever of the three was called, so that a complaint names the
-- program the caller asked for.
local VERSION = "0.3"
-- The gnu triple each target answers -dumpmachine with.
local MACHINE = {amd64 = "x86_64", arm64 = "aarch64",
		 riscv64 = "riscv64", riscv32 = "riscv32",
		 xtensa = "xtensa", i386 = "i386"}
-- what the system is called in a tuple
local TUPLE = {linux = "linux-gnu", openbsd = "openbsd", none = "elf",
	       freebsd = "freebsd", netbsd = "netbsd", darwin = "darwin"}

local prog = sys.getenv("MCC_PROG") or
	(arg[0]:gsub(".*/", ""):gsub("%.lua$", ""))

local function settarget(s)
	local arch, sys = splittarget(s)

	o.target = CPUALIAS[arch] or arch
	if o.target == "i386" then o.bits = 32 end
	if sys then o.os = sys end
end

local function die(msg)
	io.stderr:write(prog .. ": " .. msg .. "\n")
	sys.exit(1)
end

-- Flags that carry their value in the next argument, as gcc has them.
-- What each standard calls itself in __STDC_VERSION__.  gcc 8 defaults
-- to gnu17, and this compiler says the same.
local STDC = {c89 = nil, c90 = nil, c99 = "199901L", c11 = "201112L",
	      c17 = "201710L", c18 = "201710L", c23 = "202311L",
	      c2x = "202311L"}

-- The loader each system runs a dynamic program with, and the startup
-- files it wants in front of and behind the program's own.
local INTERP = {
	linux = {amd64 = "/lib64/ld-linux-x86-64.so.2",
		 arm64 = "/lib/ld-linux-aarch64.so.1",
		 riscv64 = "/lib/ld-linux-riscv64-lp64d.so.1"},
	openbsd = {amd64 = "/usr/libexec/ld.so"},
}
-- musl names its loader after the machine rather than after the ABI,
-- and a sysroot may hold it where the system holds glibc's.
local MUSL = {amd64 = "/lib/ld-musl-x86_64.so.1",
	      arm64 = "/lib/ld-musl-aarch64.so.1",
	      riscv64 = "/lib/ld-musl-riscv64.so.1"}
local CRTSET = {linux = {"Scrt1.o", "crti.o", "crtn.o"},
		openbsd = {"crt0.o", "crtbegin.o", "crtend.o"}}
-- A shared library's own start-up files.  OpenBSD's crtbeginS.o holds
-- the hidden __guard_local that every -fstack-protector object uses.
local SHAREDCRT = {openbsd = {"crtbeginS.o", "crtendS.o"}}

-- What -x calls each kind of input.
local XLANG = {c = "c", ["c-header"] = "c", assembler = "s",
	       ["assembler-with-cpp"] = "S"}

local SEPARATE = {["-o"] = true, ["-I"] = true, ["-D"] = true,
		  ["-U"] = true, ["-L"] = true, ["-l"] = true,
		  ["-e"] = true,
		  ["-Xlinker"] = true, ["-z"] = true, ["--target"] = true,
		  ["-x"] = true, ["--param"] = true}
-- What a machine flag means here.  A flag that changes what the code
-- *is* -- the mode, the calling convention, the code model -- has to
-- be implemented or refused, because taking it and ignoring it
-- changes the answer and says nothing.  A flag that only asks for a
-- diagnostic or an optimisation may be taken and ignored.
--
-- The reasons below are claims about what the emitter never does,
-- and test/invariants.lua checks each of them over everything the
-- test corpus compiles to.  A reason nobody checks is a reason that
-- stops being true without anyone noticing.
--
-- Everything here is one of two things.  The ones read elsewhere in
-- this function are implemented.  The ones listed here are satisfied
-- already, whatever the caller asks, and the reason is written beside
-- each: if that reason stops being true, this is where the obligation
-- is recorded.  Anything not named at all is refused, so that a flag
-- nobody has thought about cannot quietly change the output.
local MFLAG = {
	-- Nothing is ever kept below the stack pointer here: every
	-- frame is subtracted before it is used.
	["-mno-red-zone"] = true, ["-mred-zone"] = true,
	-- The stack is kept sixteen byte aligned at every call, which
	-- is at least what any of these ask for.
	-- `-mpreferred-stack-boundary` is read above: below four bytes
	-- the i386 spill path gets cheaper.
	["-mstackrealign"] = true, ["-mno-stackrealign"] = true,
	["-mincoming-stack-boundary="] = true,
	["-maccumulate-outgoing-args"] = true,
	["-mno-accumulate-outgoing-args"] = true,
	-- No vector unit is ever reached for on its own: a wide type
	-- goes through the software runtime.  -mno-sse is read
	-- elsewhere because it also says what a float return does.
	["-mno-mmx"] = true, ["-mmmx"] = true,
	["-mno-3dnow"] = true, ["-m3dnow"] = true,
	["-mno-avx"] = true, ["-mno-avx2"] = true,
	["-mno-sse3"] = true, ["-msse3"] = true, ["-mssse3"] = true,
	["-msse4"] = true, ["-msse4.1"] = true, ["-msse4.2"] = true,
	["-mavx"] = true, ["-mavx2"] = true, ["-mfma"] = true,
	["-mf16c"] = true, ["-mbmi"] = true, ["-mbmi2"] = true,
	["-maes"] = true, ["-mpclmul"] = true, ["-mpopcnt"] = true,
	["-mno-ssse3"] = true, ["-mno-sse4"] = true,
	["-mno-sse4.1"] = true, ["-mno-sse4.2"] = true,
	["-mno-sse4a"] = true, ["-mno-avx512f"] = true,
	["-mno-fma"] = true, ["-mno-f16c"] = true,
	["-mno-bmi"] = true, ["-mno-bmi2"] = true,
	["-mno-aes"] = true, ["-mno-pclmul"] = true,
	["-mno-popcnt"] = true, ["-mno-abm"] = true,
	-- Which processor to tune for, which changes no instruction
	-- this compiler chooses.
	["-march="] = true, ["-mtune="] = true, ["-mcpu="] = true,
	-- Alignment and layout hints that this compiler already
	-- satisfies or that gcc documents as advisory.
	["-malign-data="] = true, ["-mno-align-stringops"] = true,
	["-minline-all-stringops"] = true,
	-- Hardening this compiler does unconditionally or not at all,
	-- where doing more than asked is allowed.
	["-mharden-sls="] = true, ["-mno-fentry"] = true,
	["-mrecord-mcount"] = true, ["-mno-record-mcount"] = true,
	["-mfentry"] = true, ["-mnop-mcount"] = true,
	["-mskip-rax-setup"] = true, ["-mtls-direct-seg-refs"] = true,
	["-mno-tls-direct-seg-refs"] = true,
	["-mindirect-branch-register"] = true,
	["-mindirect-branch-cs-prefix"] = true,
	-- x87 is reached only at a call boundary, and only where the
	-- ABI puts a result there.  Asking for less than that is what
	-- this compiler already does.
	["-msoft-float"] = true, ["-mno-80387"] = true,
	["-mno-fp-ret-in-387"] = true, ["-mhard-float"] = true,
	["-mfpmath="] = true,
	-- Only the assembler's spelling, which is fixed here.
	["-masm="] = true,
	-- openbsd asks for the incoming register arguments to be put
	-- in the frame at entry, so that its debugger can read them
	-- back.  Every prologue here does that already, for every
	-- parameter, whether or not the body looks at it.
	["-msave-args"] = true, ["-mno-save-args"] = true,
}

-- Flags that mean nothing here and must not be mistaken for a file.
local IGNORE = {
	["-Wall"] = true, ["-Wextra"] = true, ["-w"] = true, ["-g"] = true,
	["-pipe"] = true, ["-pthread"] = true, ["-rdynamic"] = true,
	["-s"] = true,
	["-no-pie"] = true,
	["-fno-PIC"] = true, ["-nostartfiles"] = true, ["-v"] = false,
}

-- `-Wp,a,b` hands a and b to the preprocessor, which is this program
-- too, so they are read as ordinary options.  In that spelling -MD and
-- -MMD name the file they write, which is how kbuild asks for one.
do
	local flat = {}

	for _, a in ipairs(arg) do
		if a:sub(1, 4) == "-Wp," then
			local part = {}

			for w in a:sub(5):gmatch("[^,]+") do
				part[#part + 1] = w
			end
			local j = 1

			while j <= #part do
				local w = part[j]

				if (w == "-MD" or w == "-MMD") and
				   part[j + 1] and
				   part[j + 1]:sub(1, 1) ~= "-" then
					flat[#flat + 1] = "-MF" .. part[j + 1]
					j = j + 1
				else
					flat[#flat + 1] = w
				end
				j = j + 1
			end
		else
			flat[#flat + 1] = a
		end
	end
	arg = flat
end

local i = 1
local function value(a, n)
	if #a > n then return a:sub(n + 1) end
	i = i + 1
	return arg[i] or die("missing argument after " .. a)
end

while i <= #arg do
	local a = arg[i]
	local two = a:sub(1, 2)

	if a == "-c" or a == "-S" or a == "-E" then
		o.stop = a:sub(2)
	elseif a == "-M" or a == "-MM" then
		-- The list of files read, and nothing else.  A configure
		-- script asks this way; a build system asks with -MD,
		-- which writes the same list beside the object.
		o.stop, o.deponly = "E", true
	elseif a == "-dM" then
		o.dumpmacros = true
	elseif a == "-pie" then
		-- A program the loader relocates, which is a program the
		-- loader runs.
		if not o.static then o.dynamic = true end
	elseif a == "-r" then
		-- The inputs made into one object for a later link,
		-- which is how OpenBSD's library rules build.
		o.relocatable = true
	elseif a == "-X" then
		-- Which local names to drop from the table: they are
		-- only names, and keeping them changes nothing.  (`-x`
		-- is the language of the next input, as gcc has it.)
	elseif a == "-shared" then
		o.shared, o.pic = true, true
	elseif a:match("^%-fvisibility=") then
		o.visibility = a:sub(14)
	elseif a == "-fpic" or a == "-fPIC" or a == "-fpie" or
	       a == "-fPIE" then
		o.pic, o.picsaid = true, true
	elseif a == "-fno-pic" or a == "-fno-PIC" or a == "-fno-pie" or
	       a == "-fno-PIE" then
		-- Asked for by name, so nothing below turns it back on.
		o.pic, o.picsaid = false, true
	elseif a == "-static" then
		o.static = true
	elseif a == "-nostdlib" or a == "-nodefaultlibs" then
		o.nostdlib = true
	elseif a == "-ffreestanding" then
		o.freestanding = true
	elseif a == "-nostdinc" then
		o.nostdinc = true
	elseif a == "-o" then
		o.out = value(a, 2)
		-- `-o -` is standard output, which is what gcc does and
		-- what anyone typing it expects.  Taken as a file name
		-- it writes a file called `-` in the working directory,
		-- silently and with nothing on the terminal, and the
		-- next person to run `ls` has to work out what it is.
		if o.out == "-" then o.out = "/dev/stdout" end
	elseif two == "-I" then
		o.incs[#o.incs + 1] = value(a, 2)
	elseif a:sub(1, 8) == "-isystem" and #a > 8 then
		o.incs[#o.incs + 1] = a:sub(9)
	elseif a:sub(1, 11) == "-idirafter" and #a > 10 then
		o.incs[#o.incs + 1] = a:sub(11)
	elseif a == "-isystem" or a == "-idirafter" then
		-- A system directory is searched like any other here: this
		-- compiler warns about nothing, so the distinction that
		-- makes elsewhere does not arise.
		o.incs[#o.incs + 1] = value(a, #a)
	elseif a == "-include" then
		o.preinc[#o.preinc + 1] = value(a, 8)
	elseif a == "-MD" or a == "-MMD" then
		o.mdauto = true
	elseif a == "-MP" then
		o.mphony = true
	elseif a:sub(1, 3) == "-MF" then
		o.depfile = value(a, 3)
	elseif a:sub(1, 3) == "-MQ" or a:sub(1, 3) == "-MT" then
		o.deptarget = value(a, 3)
	elseif two == "-D" then
		local d = value(a, 2)
		local k, v = d:match("^([^=]+)=(.*)$")
		o.defs[k or d] = v or true
	elseif two == "-U" then
		o.defs[value(a, 2)] = nil
	elseif two == "-L" then
		o.libdirs[#o.libdirs + 1] = value(a, 2)
	elseif two == "-l" then
		o.libs[#o.libs + 1] = value(a, 2)
	elseif a == "-T" then
		o.script = value(a, 2)
		o.nostdlib = true
	elseif a:sub(1, 2) == "-T" and #a > 2 then
		o.script = a:sub(3)
		o.nostdlib = true
	elseif a == "-e" or a == "--entry" then
		o.entry = value(a, 2)
	elseif a:sub(1, 9) == "--target=" or a:sub(1, 8) == "-target=" then
		settarget(a:match("=(.*)$"))
	elseif a == "-t" or a == "--target" or a == "-target" then
		settarget(value(a, 2))
	elseif a:sub(1, 4) == "-Wl," then
		for w in a:sub(5):gmatch("[^,]+") do
			o.wl[#o.wl + 1] = w
		end
	elseif a == "-Xlinker" then
		o.wl[#o.wl + 1] = value(a, 8)
	elseif a == "-m16" or a == "-m32" or a == "-m64" then
		-- gcc's word size switches, which on x86 pick the target
		-- as well as the width of the object.  gcc's own -m16 is
		-- the 32-bit code generator with `.code16gcc` in front,
		-- and this one is the same.
		o.bits = tonumber(a:sub(3))
		if o.target == "amd64" or o.target == "i386" then
			o.target = o.bits == 64 and "amd64" or "i386"
		end
	elseif a:sub(1, 10) == "-mregparm=" then
		-- How many arguments the convention puts in registers,
		-- which only i386 has a choice about.
		o.regparm = tonumber(a:sub(11)) or
			die("bad " .. a)
	elseif a:sub(1, 27) == "-mpreferred-stack-boundary=" then
		o.stackbound = tonumber(a:sub(28)) or die("bad " .. a)
	elseif a == "-v" or a == "--verbose" then
		-- A linker answers `-v` with its own name.  libtool
		-- greps that answer for GNU and gives a linker that
		-- does not say so archive_cmds="", so it builds no
		-- shared library at all, however well it links one.
		if prog == "mld" then
			print("mld " .. VERSION .. " (compatible with " ..
				"GNU linkers)")
			sys.exit(0)
		end
		o.verbose = true
	elseif a == "--version" then
		-- The commit is written by the build system, so a copy
		-- that was installed says which one it was built from.
		-- One run out of the source tree has no such file.
		local ok, id = pcall(require, "mccbuild")

		print(prog .. " (mcc) " .. VERSION ..
			(ok and (" " .. id) or ""))
		print("Mischief's Compiler Collection.  " ..
			"Compatible with GNU C.")
		sys.exit(0)
	elseif a == "-dumpversion" then
		print(VERSION)
		sys.exit(0)
	elseif a:match("^%-print%-file%-name=") then
		-- Where a build system looks for the headers this
		-- compiler brings with it.  gcc answers with the path if
		-- it has the file and with the name if it does not.
		local want = a:sub(18)
		local at = here .. "/" .. want
		local f = io.open(at)
		local d = not f and io.open(at .. "/.")

		if f then f:close() end
		if d then d:close() end
		print((f or d) and at or want)
		sys.exit(0)
	elseif a == "-print-search-dirs" then
		print("install: " .. here .. "/")
		print("programs: =" .. here)
		print("libraries: =" .. here)
		sys.exit(0)
	elseif a == "-dumpmachine" then
		print((MACHINE[o.target] or o.target) .. "-unknown-" ..
			(TUPLE[o.os] or o.os))
		sys.exit(0)
	elseif a:sub(1, 9) == "-mcmodel=" then
		-- Where in the address space the program is linked.  Only
		-- `kernel` changes anything here: it says the code sits
		-- in the top two gigabytes, so a name's address is a
		-- constant the instruction carries rather than a
		-- distance from where the code stands.  A link script
		-- may put a name far outside that range, and a distance
		-- would not reach.
		o.cmodel = a:sub(10)
		-- A model this compiler does not build for is refused
		-- rather than taken and ignored: a flag that changes
		-- where the code may sit is not a hint, and a program
		-- linked above four gigabytes built as if it were below
		-- would fail at the link if it were lucky.
		if o.cmodel ~= "small" and o.cmodel ~= "kernel" then
			io.stderr:write("mcc: no code model " .. o.cmodel ..
				"\n")
			sys.exit(1)
		end
	elseif a:sub(1, 2) == "-O" then
		-- -O0 writes what the code table said and nothing else,
		-- which is what a debugger and a bug report want.
		local n = a:sub(3)

		o.opt = n == "" and 1 or (tonumber(n) or 1)
		-- -Os and -Oz ask for small code.  This compiler has one
		-- lever for that and it is a large one: a body written
		-- without `inline` is left out of line, which is what
		-- makes the difference on code with a size limit.
		o.small = (n == "s" or n == "z") or nil
	-- The hardening a kernel asks for.  Each one is a few instructions
	-- around a call or a branch, not a pass of its own.
	elseif a == "-x" then
		-- What the files after this one are, whatever they are
		-- called.  `none` goes back to reading the name.
		local k = value(a, 2)

		o.lang = XLANG[k]
		if k ~= "none" and not o.lang then
			die("unknown language " .. k)
		end
	elseif a:sub(1, 4) == "-Wa," then
		-- A build system asks the assembler its version before it
		-- will use it.  This one answers for the GNU assembler it
		-- is written to stand in for.
		if a:find("--version", 1, true) then
			print("GNU assembler (mcc) 2.42")
			sys.exit(0)
		end
	elseif a:sub(1, 5) == "-std=" then
		local n = a:sub(6):gsub("^gnu", "c")

		o.stdc = STDC[n] or o.stdc
	elseif a == "-dynamic" or a == "--dynamic" then
		-- Link a program the system's loader runs, against the
		-- system's own shared libraries.
		o.dynamic = true
	elseif a:sub(1, 10) == "--sysroot=" then
		-- Where the target's own headers, libraries and startup
		-- files are, for a build that is not for this machine.
		o.sysroot = a:sub(11):gsub("/$", "")
	elseif a == "--interp" then
		o.interp = value(a, #a)
	elseif a == "--syslink" or a == "--elf" then
		-- Hand the link to the system's own driver, which knows
		-- where its startup files and libraries are.  --elf is
		-- the old name, from when the objects were the choice.
		o.syslink = true
	elseif a == "-P" then
		-- -E without the line markers, which a build system that
		-- reads the output word by word asks for
		o.nomarkers = true
	elseif a == "-fret-clean" then
		o.retclean = true
	elseif a == "-fno-ret-clean" then
		o.retclean = false
	elseif a:sub(1, 18) == "-fcf-protection=no" or
	       a == "-fno-cf-protection" then
		o.cet = false
	elseif a:sub(1, 15) == "-fcf-protection" then
		o.cet = true
	elseif a == "-fstack-protector" then
		o.ssp = true
	elseif a == "-fstack-protector-all" then
		o.ssp = "all"
	elseif a == "-fstack-protector-strong" then
		o.ssp = "strong"
	elseif a:sub(1, 26) == "-mstack-protector-guard=" ..
	       "gl" then
		-- The canary is a plain global rather than something
		-- the thread block holds, which is what a kernel asks
		-- for and what `__stack_chk_guard` names.
		o.guardsym = o.guardsym or "__stack_chk_guard"
		o.guardfail = "__stack_chk_fail"
	elseif a:sub(1, 31) == "-mstack-protector-guard-symbol=" then
		o.guardsym = a:sub(32)
		o.guardfail = "__stack_chk_fail"
	elseif a:sub(1, 28) == "-mstack-protector-guard-reg=" then
		-- The canary is one of the machine's per-cpu words, so
		-- the name is read through a segment.  linux keeps one
		-- per cpu as soon as it has more than one.
		o.guardreg = a:sub(29)
		o.guardfail = "__stack_chk_fail"
	elseif a == "-fno-stack-protector" then
		o.ssp = nil
	elseif a == "-mretpoline" or a == "-mretpoline-external-thunk" or
	       a:sub(1, 18) == "-mindirect-branch=" and
	       a ~= "-mindirect-branch=keep" then
		o.retpoline = true
	elseif a == "-mno-sse" or a == "-mno-sse2" then
		-- What this changes is the float save area a variadic
		-- function keeps for its caller: a kernel asks for none,
		-- so that a call into it never has to save the float
		-- registers.  Both spellings drive the one lever.
		--
		-- It does not stop this compiler using %xmm for
		-- arithmetic on a float, which it does on amd64
		-- whatever these say.  gcc refuses float under
		-- -mno-sse; mcc compiles it.  Nothing in a kernel
		-- reaches that, because gcc would not have built it
		-- either, but the difference is here and not in the
		-- flag's name.
		o.nosse = true
	elseif a == "-msse" or a == "-msse2" then
		-- And back on, which is how openbsd builds the display
		-- arithmetic in its drm driver: the kernel is built
		-- -mno-sse throughout and two files ask for it back.
		o.nosse = false
	elseif a:match("^%-ffile%-prefix%-map=") or
	       a:match("^%-fmacro%-prefix%-map=") then
		-- old=new: __FILE__ names a file under old as under new.
		local old, new = a:match("^[^=]*=([^=]*)=(.*)$")

		if old then
			o.prefixmap = o.prefixmap or {}
			o.prefixmap[#o.prefixmap + 1] = {old, new}
		end
	elseif a == "-fshort-wchar" then
		-- `L"..."` is two bytes an element, which is what UEFI
		-- and the linux EFI stub are built for.
		o.shortwchar = true
	elseif a == "-fno-short-wchar" then
		o.shortwchar = false
	elseif a == "-mno-retpoline" or a == "-mindirect-branch=keep" then
		o.retpoline = false
	-- Every return goes through a thunk, which is how a kernel keeps
	-- the return stack buffer out of the guess.
	elseif a:sub(1, 18) == "-mfunction-return=" and
	       a ~= "-mfunction-return=keep" then
		o.rethunk = true
	elseif a == "-mfunction-return=keep" then
		o.rethunk = false
	elseif a:sub(1, 2) == "-m" and MFLAG[a] == nil and
	       MFLAG[a:match("^(-m[%w-]*=)") or ""] == nil then
		-- A machine flag this compiler has never been told
		-- about.  It may be a hint and it may change the ABI,
		-- and there is no way to tell from here, so it is
		-- refused and named: the list above is where the answer
		-- goes once someone has read what it means.
		die("no machine flag " .. a .. " -- see MFLAG in " ..
		    "drive.lua")
	elseif IGNORE[a] or a:sub(1, 2) == "-W" or
	       a:sub(1, 2) == "-n" and a ~= "-nostdinc" or
	       a:sub(1, 2) == "-g" or a:sub(1, 5) == "-std=" or
	       a:sub(1, 2) == "-m" or a:sub(1, 2) == "-f" then
		-- a flag for a compiler that has these things
	elseif SEPARATE[a] then
		value(a, #a)
	elseif a:sub(1, 1) == "-" and a ~= "-" then
		-- an unknown flag with no argument is likewise no business
		-- of this compiler
	else
		o.files[#o.files + 1] = a
	end
	i = i + 1
end

-- `-Wl,--version` asks what the linker is, and a build system asks that
-- before it has anything to link.
for _, w in ipairs(o.wl) do
	if w == "--version" or w == "-v" then
		-- libtool asks `$LD -v` and greps the answer for GNU
		-- or "with BFD"; a linker that does not say so is
		-- given archive_cmds="" and builds no shared library
		-- at all, however well it links one.  lld answers the
		-- same way and for the same reason.
		print("mld " .. VERSION .. " (compatible with GNU " ..
			"linkers), the linker of Mischief's Compiler " ..
			"Collection")
		sys.exit(0)
	end
end

if #o.files == 0 then die("no input files") end

-- The machine this is running on, which decides whether the system
-- headers are the right ones to read.
local function host()
	-- Each system has its own name for the same machine.
	return ({x86_64 = "amd64", amd64 = "amd64", aarch64 = "arm64",
		 arm64 = "arm64", riscv64 = "riscv64"})[sys.uname().machine
							 or ""]
end

-- This compiler's own headers come after whatever was named, the way a
-- system include path does.  Building for this machine, the system
-- headers come after those.  -ffreestanding and -nostdlib keep them, as
-- gcc and clang do; only -nostdinc removes them.
if not o.nostdinc then
	o.incs[#o.incs + 1] = here .. "/include"
	-- The libc a program is linked against owns its own headers, so
	-- they come before the stand-ins here.
	if o.target == host() then
		for _, dir in ipairs{"/usr/local/include", "/usr/include"} do
			local d = o.sysroot .. dir
			local f = io.open(d .. "/stdio.h")
			if f then
				f:close()
				o.incs[#o.incs + 1] = d
			end
		end
	end
	o.incs[#o.incs + 1] = here ..
		((o.freestanding or o.nostdlib) and "/include/freestanding"
		 or "/include/hosted")
end

local root = here
local arch = ARCH[o.target] or die("no target " .. o.target)

-- Everything runs in this process; the compiler is a library.
local cpp = require "cpp"
local parse = require "parse"
local widert = require "widert"
local t = require("target." .. o.target)

if o.regparm then
	if not t.regparm then
		die("-mregparm is not a choice on " .. o.target)
	end
	t.regparm(o.regparm)
end

if o.stackbound and t.stackboundary then t.stackboundary(o.stackbound) end
if t.setpic then t.setpic(o.pic) end

-- -fshort-wchar halves `wchar_t` and every `L"..."` with it.  This
-- comes first so that it stands in front of what the machine says.
if o.shortwchar then
	local w = {__SIZEOF_WCHAR_T__ = "2",
		   __WCHAR_TYPE__ = "short unsigned int",
		   __WCHAR_MAX__ = "65535", __WCHAR_MIN__ = "0"}

	for k, v in pairs(w) do
		if o.defs[k] == nil then o.defs[k] = v end
	end
end
for k, v in pairs(t.predef or {}) do
	if o.defs[k] == nil then o.defs[k] = v end
end

-- What the system calls itself.  A header asks, and an OpenBSD one asks
-- often: parts of a struct stand behind `#ifdef __OpenBSD__`.
local OSDEF = {
	openbsd = {__OpenBSD__ = "1", __unix__ = "1", __unix = "1",
		   unix = "1"},
	linux = {__linux__ = "1", __linux = "1", linux = "1",
		 __gnu_linux__ = "1", __unix__ = "1", __unix = "1",
		 unix = "1"},
	freebsd = {__FreeBSD__ = "1", __unix__ = "1", __unix = "1",
		   unix = "1"},
	netbsd = {__NetBSD__ = "1", __unix__ = "1", __unix = "1",
		  unix = "1"},
	darwin = {__APPLE__ = "1", __MACH__ = "1", __unix__ = "1",
		  __unix = "1"},
}
for k, v in pairs(OSDEF[o.os] or {}) do
	if o.defs[k] == nil then o.defs[k] = v end
end
if o.os == "openbsd" and o.target == "amd64" then
	CRT.amd64 = "rt/openbsd-amd64.s"
end
-- The stack protector's canary where the C library keeps it.  OpenBSD
-- has __guard_local, which the target writes by default; glibc and musl
-- keep it in the thread block and fail through __stack_chk_fail.
if o.ssp and not o.guardsym and not o.guardreg and o.os ~= "openbsd" and
   not o.freestanding then
	if o.target == "amd64" then
		o.guardreg, o.guardsym = "fs", "40"
	elseif o.target == "i386" then
		o.guardreg, o.guardsym = "gs", "20"
	end
	if o.guardreg then
		o.guardfail = o.guardfail or "__stack_chk_fail"
	end
end

-- One text cache for the whole run: several sources share their headers,
-- and on a machine whose files live in flash reading them again is not
-- free.
local text = {}

-- A name no other run of this program will pick.  Two compiles of files
-- with the same basename run at once under a parallel build, so the
-- clock is not enough to tell them apart.
-- Taken on first use: a compile that goes straight to an object needs
-- no scratch file, and so no name for one.
local token

local function tmp(name)
	local d = sys.getenv("TMPDIR") or "/tmp"

	token = token or (sys.tmpname():gsub(".*/", ""))
	return ("%s/mcc-%s-%s"):format(d, token, name)
end

local made = {}
local function scrap(path)
	made[#made + 1] = path
	return path
end

local function cleanup()
	for _, f in ipairs(made) do sys.remove(f) end
	made = {}
end

-- The scratch files go whatever happens, not only when the compiler
-- finishes: /tmp is memory on many machines, and a build where half
-- the files fail would otherwise fill it.
local sweep <close> = setmetatable({}, {__close = cleanup})

local function base(path)
	return (path:gsub(".*/", ""):gsub("%.[^.]*$", ""))
end

-- A stage's output that only the next stage reads.  The compiler and the
-- assembler run in this one process, so the text is handed over as it
-- is and never written to a scratch file.
local function membuf()
	local parts = {}

	return {
		write = function(self, ...)
			for i = 1, select("#", ...) do
				parts[#parts + 1] = select(i, ...)
			end
			-- Thousands of small strings cost more than the text
			-- they hold, so they are folded into one as they come.
			if #parts > 2048 then
				parts = {table.concat(parts)}
			end
			return self
		end,
		close = function() end,
		text = function() return table.concat(parts) end,
	}
end

-- A string as C would write it: the lexer keeps what the escapes mean,
-- and -E has to put them back.
local ESC = {["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n",
	     ["\t"] = "\\t", ["\r"] = "\\r", ["\f"] = "\\f",
	     ["\v"] = "\\v", ["\a"] = "\\a", ["\b"] = "\\b",
	     ["\0"] = "\\0"}

local function escape(s)
	return (tostring(s or ""):gsub('[%z\1-\31\\"\127-\255]', function(c)
		return ESC[c] or ("\\%03o"):format(c:byte())
	end))
end

-- .c -> .s
-- `pponly` stops after the preprocessor whatever -E says, which is what
-- an assembly source spelled with a capital S wants.
local function compile(path, out, pponly)
	local w = type(out) == "table" and out or assert(io.open(out, "w"))
	-- `-` is the standard input, which is how a build system asks the
	-- compiler what it defines.
	if path == "-" then
		text["-"] = io.read("a") or ""
	end
	local defs = o.defs

	if pponly then
		defs = {__ASSEMBLER__ = "1"}
		for k, v in pairs(o.defs) do defs[k] = v end
	end
	local src = cpp.new{file = path, path = o.incs, define = defs,
		text = text, keeptext = #o.files > 1 or not o.stop,
		preinclude = o.preinc, stdc = o.stdc,
		freestanding = o.freestanding, prefixmap = o.prefixmap,
		charsigned = t.charsigned ~= false,
		nojoin = pponly or o.stop == "E", asm = pponly,
		everything = pponly or o.stop == "E"}

	-- -dM lists what is defined at the end rather than what came out.
	if o.dumpmacros then
		while src:next().kind ~= "eof" do end
		local names = {}

		for k, m in pairs(src.macros) do
			if k ~= "__LINE__" and k ~= "__FILE__" and
			   k ~= "__COUNTER__" then
				names[#names + 1] = k
			end
		end
		table.sort(names)
		for _, k in ipairs(names) do
			local m = src.macros[k]
			local args = ""

			if m.params then
				local ps = {}
				for j, q in ipairs(m.params) do
					ps[j] = m.variadic and
						j == #m.params and
						(q == "__VA_ARGS__" and "..."
						 or q .. "...") or q
				end
				args = "(" .. table.concat(ps, ",") .. ")"
			end
			w:write("#define ", k, args, " ", m.body or "", "\n")
		end
	elseif o.deponly then
		-- Every file the preprocessor opened, in a make rule.
		-- The tokens go nowhere: reading them is only how the
		-- list is gathered.
		while src:next().kind ~= "eof" do end

		local d = o.depfile and assert(io.open(o.depfile, "w")) or w
		local seen = {}

		d:write(o.deptarget or
			(path:match("([^/]*)%.[^.]*$") or path) .. ".o", ":")
		for _, f in ipairs(src.read) do
			if not seen[f] then
				seen[f] = true
				d:write(" ", (f:gsub("[ \\]", "\\%0")))
			end
		end
		d:write("\n")
		if d ~= w then d:close() end
	elseif pponly or o.stop == "E" then
		-- Preprocessed source as a program would write it: a
		-- token on the line it came from, with the spacing that
		-- separated it.  Tools read this.
		local file, line, col = nil, 0, 0

		-- A marker for the file itself, before any token.  A
		-- translation unit that is all comments still has to say
		-- which file it came from: autoconf greps for the name.
		if not o.nomarkers then
			file, line = path, 1
			w:write(('# 1 "%s"\n'):format(path))
		end
		while true do
			local tk = src:next()

			if tk.kind == "eof" then break end
			if tk.file ~= file or tk.line < line then
				file, line = tk.file, tk.line
				if not o.nomarkers then
					w:write(('\n# %d "%s"\n')
						:format(line, file or "-"))
				else
					w:write("\n")
				end
				col = 0
			elseif tk.line > line then
				-- a run of blank lines, up to a point:
				-- past that a marker says where we are
				if tk.line - line > 8 and not o.nomarkers then
					w:write(('\n# %d "%s"\n')
						:format(tk.line, file or "-"))
				elseif tk.line - line > 8 then
					w:write("\n")
				else
					w:write(("\n"):rep(tk.line - line))
				end
				line, col = tk.line, 0
			elseif col > 0 and tk.ws then
				w:write(" ")
			end
			if tk.kind == "str" and tk.spell then
				w:write(tk.spell)
			elseif tk.kind == "str" then
				w:write(tk.pfx or "", '"',
					tk.raw or escape(tk.text), '"')
			elseif tk.kind == "chr" then
				w:write("'", escape(tk.text or ""), "'")
			else
				w:write(tk.text or tostring(tk.val or
					tk.kind))
			end
			col = col + 1
		end
		w:write("\n")
	else
		-- -m16 is the 32-bit code generator in 16-bit mode, which
		-- is what gcc's own -m16 is and what a kernel's real mode
		-- trampoline is built with.
		if o.bits == 16 then w:write("\t.code16gcc\n") end
		local p = parse.new(src, t, function(s) w:write(s) end,
			{wide = sys.getenv("WIDE") ~= nil, pic = o.pic,
			 cmodel = o.cmodel,
			 opt = o.opt, small = o.small,
			 retclean = o.retclean,
			 cet = o.cet, retpoline = o.retpoline,
			 rethunk = o.rethunk, nosse = o.nosse,
			 shortwchar = o.shortwchar,
			 guardsym = o.guardsym, guardfail = o.guardfail,
			 guardreg = o.guardreg,
			 ssp = o.ssp, visibility = o.visibility})

		-- An error the parser did not raise itself says nothing
		-- about where it happened, so the token in hand is added.
		local ok, err = pcall(p.program, p)

		if not ok then
			if type(err) == "string" and
			   err:match("^[^\n]*%.lua:%d+: ") then
				err = ("%s:%d: %s"):format(
					p.tok.file or path,
					p.tok.line or 0, err)
			end
			error(err, 0)
		end
		widert.emit(p, function(x) w:write(x) end, t, here,
			{pic = o.pic, cmodel = o.cmodel,
			 opt = o.opt, small = o.small,
			 retclean = o.retclean,
			 cet = o.cet, retpoline = o.retpoline,
			 rethunk = o.rethunk, nosse = o.nosse})
		if t.unitend then
			t.unitend(p.g, function(x) w:write(x) end)
		end
		if t.trailer then w:write(t.trailer) end
	end
	w:close()
	-- -MF names a file listing what was read, which a build system
	-- reads to know when to build again.  -MD alone names it after
	-- the object, the way gcc does: `-o x.o` writes x.d, and with no
	-- -o the source's own name ends in .d here.
	local depfile = o.depfile
	if not depfile and o.mdauto then
		depfile = o.out and o.stop == "c" and
			o.out:gsub("%.[^./]*$", "") .. ".d" or base(path) .. ".d"
	end
	if depfile and not o.deponly then
		local d = assert(io.open(depfile, "w"))
		local seen = {}

		d:write(o.deptarget or o.out or
			(type(out) == "string" and out or base(path) .. ".o"),
			":")
		for _, f in ipairs(src.read) do
			if not seen[f] then
				seen[f] = true
				d:write(" ", (f:gsub("[ \\]", "\\%0")))
			end
		end
		d:write("\n")
		-- -MP: every header is a target of its own with nothing to
		-- do, so deleting one does not stop the build.
		if o.mphony then
			for i, f in ipairs(src.read) do
				if i > 1 and seen[f] then
					seen[f] = nil
					d:write("\n", (f:gsub("[ \\]", "\\%0")),
						":\n")
				end
			end
		end
		d:close()
	end
end

-- .s -> .o
-- Which ELF the object is written as.  Only x86 has a narrow one that
-- is not a target of its own, and only because a kernel links its real
-- mode trampoline as elf32-i386.
local function objtarget()
	if o.target == "amd64" and o.bits and o.bits < 64 then
		return "i386"
	end
	return o.target
end

local function assemble(path, out)
	local text

	if type(path) == "table" then
		text = path:text()
	elseif path == "-" then
		text = io.read("a") or ""
	else
		local f = assert(io.open(path))

		text = f:read("a")
		f:close()
	end
	local u = as.assemble(text, {arch = arch,
		srcname = type(path) == "string" and path ~= "-" and path or nil,
		bits = o.bits ~= 64 and o.bits or nil,
		pinsyscalls = o.os == "openbsd" and o.target == "amd64",
		xlen = o.target == "riscv32" and 32 or 64})
	local w = assert(io.open(out, "wb"))

	w:write(elf.relocatable(u, objtarget()))
	w:close()
end

local function crtpath(name)
	for _, dir in ipairs{"/usr/lib64", "/usr/lib/x86_64-linux-gnu",
			     "/usr/lib", "/lib64", "/usr/lib/gcc"} do
		local d = o.sysroot .. dir
		local f = io.open(d .. "/" .. name, "rb")

		if f then
			f:close()
			return d .. "/" .. name
		end
	end
	return nil
end

-- A system whose programs are position independent compiles that way
-- too, and it has to: an object built for a fixed address reaches a
-- library's data with a pc-relative instruction, which no loader can
-- Which loader a hosted program asks for.  A sysroot may hold a libc
-- other than the one this machine runs, and musl puts its loader
-- where glibc does not.
local function interpof()
	local m = MUSL[o.target]
	-- A sysroot is the root to look in.  With none, the machine this
	-- is running on is the root, but only for a program built for it:
	-- a cross build has nothing here to look at.
	local root = o.sysroot ~= "" and o.sysroot or
		(o.target == host() and "" or nil)

	if m and root then
		local f = io.open(root .. m)

		if f then
			f:close()
			return m
		end
	end
	return (INTERP[o.os] or {})[o.target]
end

-- fix up once the library lands somewhere else.  An object says nothing
-- about how it will be linked, so the decision is made here, where the
-- target is known.  A freestanding or hand-linked image is its own
-- world and wants none of it, a static link has no loader to fill a
-- table in, and `-fno-pic` settles it either way.
if not o.picsaid and
   not (o.nostdlib or o.freestanding or o.script or o.syslink or
        o.static) and
   o.target == host() and interpof() then
	o.pic = true
end

-- A hosted program built for the machine this is running on links
-- against the system's own library, the way any other compiler would.
-- The runtime here is for a program with no system to speak of.
-- A sysroot is not a reason to leave the hosted path: a cross build
-- against one is still a program with a libc and a loader, and the
-- start-up files being there is the evidence of that.
if not (o.nostdlib or o.freestanding or o.shared or o.dynamic or
	o.script or o.syslink or o.static or o.stop) and
   o.target == host() and interpof() and
   crtpath((CRTSET[o.os] or {})[1]) then
	o.dynamic = true
	local havec = false

	for _, l in ipairs(o.libs) do
		if l == "c" then havec = true end
	end
	if not havec then o.libs[#o.libs + 1] = "c" end
end

-- A build system does not know whether a flag belongs to the driver or
-- to the linker, so it hands the linker script over with -Wl and lets
-- the driver pass it on.  This driver is the linker, so it reads it.
do
	-- Which driver option a linker flag that takes a value sets.
	local word = {
		["-T"] = "script", ["--script"] = "script",
		["-e"] = "entry", ["--entry"] = "entry",
		["-h"] = "soname", ["-soname"] = "soname",
		["--soname"] = "soname",
		["-I"] = "interp", ["--dynamic-linker"] = "interp",
	}
	-- The same flags written as one word.  A single letter is left
	-- out on purpose: `-export-dynamic` begins with `-e`.
	local glued = {["--script="] = "script", ["-T"] = "script",
		       ["--entry="] = "entry",
		       ["--soname="] = "soname", ["-soname="] = "soname",
		       ["--dynamic-linker="] = "interp"}
	local i = 1

	while i <= #o.wl do
		local w = o.wl[i]
		local put = word[w]

		if put and o.wl[i + 1] then
			o[put] = o.wl[i + 1]
			table.remove(o.wl, i)
			table.remove(o.wl, i)
		else
			for pfx, dst in pairs(glued) do
				if #w > #pfx and w:sub(1, #pfx) == pfx then
					put, o[dst] = dst, w:sub(#pfx + 1)
					break
				end
			end
			if put then
				table.remove(o.wl, i)
			else
				i = i + 1
			end
		end
	end
end

local objs = {}
-- The shared objects named on the command line, which become names the
-- loader looks up rather than anything read into the image.
local shlibs = {}

-- Where the system keeps the object that starts a program.
-- A path or a flag as one word of a command line.
local function quote(s)
	if s:match("^[%w@%%_%-%+=:,./]+$") then return s end
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Where a stage's output goes: -o names it when there is one file, and
-- otherwise it takes the input's name in the working directory.  Anything
-- that is only on its way somewhere else goes to a scratch file.
local function output(name, ext, final)
	if not final then return scrap(tmp(name .. ext)) end
	if o.out and #o.files == 1 then return o.out end
	return name .. ext
end

-- The control variable of a for loop may not be assigned to, and each
-- stage below hands the next one a new name for the same file.
for _, given in ipairs(o.files) do
	local f = given
	-- `-` is C on the standard input, which is how a build system asks
	-- the compiler about itself.
	local kind = o.lang or (f == "-" and "c" or f:match("%.(%w+)$"))

	-- `.i` is C already through the preprocessor; running it through
	-- again changes nothing.
	if kind == "i" then kind = "c" end
	local name = f == "-" and "stdin" or base(f)

	if kind == "c" then
		if o.stop == "E" and not o.out then
			compile(f, "/dev/stdout")
			goto next
		end
		local final = o.stop == "S" or o.stop == "E"
		local s = final and output(name, o.stop == "E" and ".i" or
			".s", true) or membuf()

		compile(f, s)
		if o.stop == "S" or o.stop == "E" then goto next end
		f, kind = s, "s"
	end
	-- A capital S means the assembly goes through the preprocessor
	-- first, which is how a header hands macros to it.
	if kind == "S" then
		if o.stop == "E" and not o.out then
			compile(f, "/dev/stdout", true)
			goto next
		end
		local i = o.stop == "E" and output(name, ".s", true) or
			membuf()

		compile(f, i, true)
		if o.stop == "E" then goto next end
		f, kind = i, "s"
	end
	if kind == "s" then
		local ofile = output(name, ".o", o.stop == "c")

		assemble(f, ofile)
		f, kind = ofile, "o"
	end
	-- A shared object named on the command line is a library this
	-- program wants, not something to copy from.  The loader is told
	-- its name and finds it; nothing of it is read into the image.
	if f:match("%.so$") or f:match("%.so%.[%d.]+$") then
		shlibs[#shlibs + 1] = f
		-- Naming a shared object is asking for a program the
		-- loader runs, whatever else was said.
		if not o.static and not o.shared then o.dynamic = true end
	elseif o.stop ~= "c" then
		-- Anything left is for the linker, whatever it is
		-- called.  A compiler does not know every suffix a build
		-- system invents: musl names its shared objects `.lo`,
		-- and dropping them quietly builds an empty library.
		objs[#objs + 1] = f
	elseif f == given then
		-- Nothing here made an object of it, and with no link
		-- nothing reads it: say so, as gcc does.
		io.stderr:write(("%s: warning: %s: linker input file " ..
			"unused because linking not done\n"):format(prog,
			given))
	end
	::next::
end

if o.stop then
	cleanup()
	sys.exit(0)
end

-- What the runtime objects depend on: the runtime sources and the
-- parts of the compiler that turn them into bytes.  A cached object
-- is only good while every one of these is unchanged, so the key is
-- read from their contents rather than from a version number.
local rtkey

local function rtstamp(list)
	if rtkey then return rtkey end
	local h = 5381
	local function eat(path)
		local f = io.open(path, "rb")

		if not f then return end
		local d = f:read("a")

		f:close()
		for i = 1, #d, 61 do
			h = (h * 33 + d:byte(i)) & 0xffffffff
		end
		h = (h * 33 + #d) & 0xffffffff
	end

	for _, f in ipairs(list) do eat(f) end
	for _, m in ipairs{"drive.lua", "parse.lua", "gen.lua", "as.lua",
			   "cpp.lua", "lex.lua", "md.lua", "tree.lua",
			   "peep.lua", "ir.lua",
			   "target/" .. o.target .. ".lua",
			   "as/" .. o.target .. ".lua"} do
		eat(root .. "/" .. m)
	end
	rtkey = ("%08x"):format(h)
	return rtkey
end

-- Compile and assemble runtime sources into objects appended to `into`.
-- Every link used to build the whole runtime again, which is most of
-- what a small link costs.
local function rtbuild(list, into)
	local key = rtstamp(list)
	local dir = sys.getenv("TMPDIR") or "/tmp"

	for _, f in ipairs(list) do
		local keep = ("%s/mcc-rt-%s-%s-%s-O%d.o"):format(dir,
			o.target, key, base(f), o.opt or 0)
		local have = io.open(keep, "rb")

		if have then
			have:close()
			into[#into + 1] = keep
			goto next
		end
		do
		local a

		if f:match("%.c$") then
			local save = o.incs
			o.incs = {root .. "/include",
				  root .. "/include/freestanding"}
			a = membuf()
			compile(f, a)
			o.incs = save
		else
			a = f
		end
		-- Built under a name of this run's own and moved into
		-- place, because several compilers share the directory
		-- and a half-written object is a wrong answer.
		local part = scrap(tmp(base(f) .. ".rt.o"))

		assemble(a, part)
		os.rename(part, keep)
		into[#into + 1] = io.open(keep, "rb") and keep or part
		end
		::next::
	end
end

-- Linking against a real system: the objects are ELF, so the system's
-- own driver knows where its startup files and libraries are and this
-- one does not have to.  That is how a new compiler is brought up.
if o.syslink then
	local cmd = {sys.getenv("MCC_SYSLD") or "cc"}

	if o.shared then cmd[#cmd + 1] = "-shared" end
	if o.static then cmd[#cmd + 1] = "-static" end
	-- Our objects are not position independent, so a driver that
	-- defaults to PIE has to be told otherwise.
	if not o.shared and not o.pic then cmd[#cmd + 1] = "-no-pie" end
	-- The arithmetic this target does with calls, which the system
	-- library does not have.
	if not o.nostdlib then
		local extra = {}

		for _, f in ipairs(RTMATH) do
			extra[#extra + 1] = root .. "/" .. f
		end
		rtbuild(extra, objs)
	end
	for _, f in ipairs(objs) do cmd[#cmd + 1] = f end
	for _, d in ipairs(o.libdirs) do cmd[#cmd + 1] = "-L" .. d end
	for _, l in ipairs(o.libs) do cmd[#cmd + 1] = "-l" .. l end
	for _, a in ipairs(o.wl) do cmd[#cmd + 1] = "-Wl," .. a end
	cmd[#cmd + 1] = "-o"
	cmd[#cmd + 1] = o.out or "a.out"
	local ok, why = sys.exec(cmd, {verbose = o.verbose})

	if not ok and why and not o.verbose then
		io.stderr:write(prog .. ": " .. why .. "\n")
	end
	cleanup()
	sys.exit(ok and 0 or 1)
end

local ld = require "ld"
local so = require "so"

-- `-r`: the objects on the command line become one, and nothing else
-- goes in: no start-up file, no library, no runtime.
if o.relocatable then
	local ok, why = pcall(ld.relocatable, objs, o.out or "a.out",
		objtarget())

	if not ok then io.stderr:write(prog .. ": " .. tostring(why) .. "\n") end
	cleanup()
	sys.exit(ok and 0 or 1)
end

-- `-Wl,--wrap=name` is a rename the linker does as it reads, so it has
-- to be in place before anything is read.
do
	local names = {}

	for _, a in ipairs(o.wl) do
		local n = a:match("^%-%-wrap=(.+)$")

		if n then names[#names + 1] = n end
	end
	if #names > 0 then require("elf").wrap(names) end
end

-- The compiler's own helpers: what the code generator calls when the
-- machine cannot do a thing in one instruction.  They are not the C
-- library, so `-nostdlib` keeps them, and they go in an archive so a
-- program that needs none of them carries none.
if o.nostdlib then
	local src, built = {}, {}

	for _, f in ipairs(RTMATH) do src[#src + 1] = root .. "/" .. f end
	rtbuild(src, built)
	if #built > 0 then
		local lib = scrap(tmp("rt.a"))

		require("ar").write(lib, built)
		objs[#objs + 1] = lib
	end
end

-- the pieces a program needs that no source named
if not o.nostdlib then
	local extra = {}

	if o.dynamic then
		-- The system's own startup files: this program is run by
		-- the system's loader and calls the system's library.
		for _, f in ipairs(CRTSET[o.os] or CRTSET.linux) do
			local p = crtpath(f)

			if p then objs[#objs + 1] = p end
		end
	elseif o.shared then
		if o.target == host() then
			for _, f in ipairs(SHAREDCRT[o.os] or {}) do
				local p = crtpath(f)

				if p then objs[#objs + 1] = p end
			end
		end
	else
		extra[#extra + 1] = root .. "/" .. (CRT[o.target] or
			error("no start-up file for " .. o.target ..
				": link with the system compiler", 0))
		for _, f in ipairs(RTIO) do
			extra[#extra + 1] = root .. "/" .. f
		end
	end
	for _, f in ipairs(RTMATH) do extra[#extra + 1] = root .. "/" .. f end
	rtbuild(extra, objs)
end

local PRESET = {
	xtensa = {base = 0xfe000000, detached = true,
		  place = {[".window"] = 0x2000},
		  symbols = {_stack_top = 0xfe7fffc0}},
}
local preset = PRESET[o.target] or {}
local out = o.out or (o.shared and "a.so" or "a.out")

-- A `-l` that only has a shared library to offer is a program the
-- loader runs, whatever else was said.  openbsd defines `_ctype_` in
-- libc.so alone, and its libc.a asks for it, so a static link of
-- anything that touches <ctype.h> cannot be made.
if not (o.static or o.shared or o.dynamic or o.script or o.syslink) and
   #o.libs > 0 then
	local dirs = {}

	for _, d in ipairs(o.libdirs) do dirs[#dirs + 1] = d end
	for _, d in ipairs{"/usr/lib64", "/lib64", "/usr/lib",
			   "/usr/lib/x86_64-linux-gnu"} do
		dirs[#dirs + 1] = o.sysroot .. d
	end
	for _, l in ipairs(o.libs) do
		local a, so = false, false

		for _, d in ipairs(dirs) do
			local f = io.open(d .. "/lib" .. l .. ".a", "rb")

			if f then a = true f:close() end
			if #sys.sharedlibs(d, l) > 0 then so = true end
			if a or so then break end
		end
		if so and not a then o.dynamic = true end
	end
end
-- A static link made as a linker, the way mld is run, takes each `-l`
-- as the archive: `mld -static crt0.o t.o -lc` wants libc.a.  The
-- driver's own static programs link its runtime instead and leave the
-- system's archives alone.
if o.nostdlib and not (o.dynamic or o.shared or o.script) and
   #o.libs > 0 then
	local dirs = {}

	for _, d in ipairs(o.libdirs) do dirs[#dirs + 1] = d end
	for _, d in ipairs{"/usr/lib64", "/lib64", "/usr/lib",
			   "/usr/lib/x86_64-linux-gnu"} do
		dirs[#dirs + 1] = o.sysroot .. d
	end
	for _, l in ipairs(o.libs) do
		local found

		for _, d in ipairs(dirs) do
			local at = d .. "/lib" .. l .. ".a"
			local f = io.open(at, "rb")

			if f then f:close() found = at break end
		end
		if not found then
			error("no archive for -l" .. l, 0)
		end
		objs[#objs + 1] = found
	end
end
local w = assert(io.open(out, "wb"))
local ok, err

if o.script then
	-- The program says for itself what its image looks like.
	ok, err = pcall(ld.scriptlink, objs, w, {
		target = o.target, script = o.script, entry = o.entry,
	})
elseif o.shared or o.dynamic then
	-- A GNU ld script standing in for a library: take the archives
	-- it names, which the loader knows nothing about.
	local function groupof(path)
		local f = io.open(path, "rb")

		if not f then return nil end
		local head = f:read(4) or ""

		if head == "\127ELF" or head == "!<ar" then
			f:close()
			return nil
		end
		f:seek("set", 0)
		local text = f:read("a") or ""

		f:close()
		local shared, archives = nil, {}

		for g in text:gmatch("GROUP%s*%(([^)]*)%)") do
			for name in g:gmatch("[%w%p]+") do
				local at = name

				if not at:match("^/") then
					at = path:gsub("/[^/]*$", "/") .. name
				end
				if name:match("%.a$") and io.open(at) then
					archives[#archives + 1] = at
				elseif name:match("%.so[%.%d]*$") and
				    not shared and io.open(at) then
					shared = at
				end
			end
		end
		if not shared and #archives == 0 then return nil end
		return shared, archives
	end

	-- The libraries asked for, by the name each answers to.
	local LIBDIR = {}

	for _, d in ipairs{"/usr/lib64", "/lib64", "/usr/lib",
			   "/usr/lib/x86_64-linux-gnu"} do
		LIBDIR[#LIBDIR + 1] = o.sysroot .. d
	end
	local need = {}

	local dirs = {}

	for _, d in ipairs(o.libdirs) do dirs[#dirs + 1] = d end
	for _, d in ipairs(LIBDIR) do dirs[#dirs + 1] = d end
	-- Where each library really is, so the version each name in it
	-- answers to by default can be read from it.
	local libpaths = {}

	for _, l in ipairs(o.libs) do
		local nm, found

		for _, d in ipairs(dirs) do
			local at = d .. "/lib" .. l .. ".so"
			-- The file under that name may be a script
			-- rather than a library: glibc keeps a few
			-- functions, atexit among them, in an archive
			-- beside the shared object and names both in a
			-- GROUP.  The loader cannot read that, so the
			-- archive is linked in here.
			local shared, archives = groupof(at)

			if shared or archives then
				for _, a in ipairs(archives or {}) do
					objs[#objs + 1] = a
				end
				nm = shared and elf.soname(shared)
				if not nm and shared then
					nm = shared:match("[^/]*$")
				end
				if nm then found = shared end
			else
				nm = elf.soname(at)
				if nm then found = at end
			end
			-- A system that versions the file name rather
			-- than keeping a plain one: take the newest.
			-- Newest by number, not by spelling: openbsd
			-- ships libc.so.9.0 beside libc.so.104.0 and
			-- nine sorts after a hundred and four.
			if not nm then
				local best, bestv

				for _, line in ipairs(sys.sharedlibs(d, l)) do
					local v = {}

					-- Only the versioned names: a
					-- plain lib.so was tried above.
					for n in (line:match("%.so%.(.*)$")
					    or ""):gmatch("%d+") do
						v[#v + 1] = tonumber(n)
					end
					local newer = bestv == nil

					for i = 1, math.max(#v, #(bestv or {}))
					do
						local a = v[i] or -1
						local b = (bestv or {})[i] or -1

						if a ~= b then
							newer = a > b
							break
						end
					end
					if #v > 0 and newer then
						best, bestv = line, v
					end
				end
				nm = best and elf.soname(best)
				if nm then found = best end
			end
			if nm then break end
			-- No shared library here, but an archive: its
			-- members are linked in, as any linker does.
			local a = d .. "/lib" .. l .. ".a"
			local f = io.open(a, "rb")

			if f then
				f:close()
				objs[#objs + 1] = a
				break
			end
		end
		-- A NEEDED belongs to a shared library the loader will
		-- have to open.  A `-l` that found an archive, or found
		-- nothing at all, leaves nothing in .dynamic: musl keeps
		-- the whole of libm and libdl inside libc, and asking
		-- the loader for a file that was never there fails the
		-- program at its first run.
		if nm then
			need[#need + 1] = nm
			libpaths[#libpaths + 1] = found
		end
	end
	-- A shared object named on the command line is a library this
	-- program wants, not an object to copy from: the loader is told
	-- its name and looks it up, which is what any other linker does
	-- with one.  The startup files and the libc that a build hands
	-- over by path arrive this way.
	for _, f in ipairs(shlibs) do
		local nm = elf.soname(f) or f:gsub(".*/", "")
		local seen = false

		for _, n in ipairs(need) do
			if n == nm then seen = true end
		end
		if not seen then need[#need + 1] = nm end
		libpaths[#libpaths + 1] = f
	end
	o.needed = need
	-- A program the system's loader runs: position independent, with
	-- the name of the loader in it and the libraries it wants named
	-- for the loader to find.
	-- A shared object has no loader of its own and no entry point,
	-- but it wants the same list of libraries: what it calls and
	-- does not have has to be found somewhere.
	ok, err = pcall(so.link, ld.inputs(objs), w, {
		soname = o.shared and (o.soname or out:gsub(".*/", ""))
			or nil,
		interp = not o.shared and (o.interp or interpof()) or nil,
		needed = o.needed,
		entry = o.entry or (not o.shared and "_start" or nil),
		libpaths = libpaths, osnote = o.os,
	})
else
	ok, err = pcall(ld.linkfiles, objs, w, {
		target = o.target, base = preset.base, place = preset.place,
		symbols = preset.symbols, detached = preset.detached,
		entry = o.entry,
		-- OpenBSD will not let a program make a system call from
		-- anywhere it has not been told about ahead of time.
		pinsyscalls = o.os == "openbsd" and o.target == "amd64",
	})
end
w:close()
cleanup()
if not ok then
	-- A half-written program is worse than none: a build that reads
	-- the file rather than the exit status would take it for good.
	sys.remove(out)
	io.stderr:write(prog .. ": " .. tostring(err) .. "\n")
	sys.exit(1)
end
sys.executable(out)
