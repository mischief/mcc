-- SPDX-License-Identifier: ISC
-- The driver's command line, read once into the options table.  This
-- runs once and is dropped: none of it is needed after the options
-- are settled.  A flag that only asks a question answers it and exits.

local d = require "mcc.drive"
local argv = d.argv
local sys = require "mcc.sys"
local H = require "mcc.drive.host"
local here, prog, die = d.here, d.prog, d.die

local HOST = "amd64"
local ARCH = {amd64 = "amd64", x86_64 = "amd64", riscv64 = "riscv",
	      riscv32 = "riscv", xtensa = "xtensa", arm64 = "arm64",
	      aarch64 = "arm64", i386 = "amd64", i486 = "amd64",
	      i586 = "amd64", i686 = "amd64", wasm = "wasm",
	      wasm32 = "wasm"}
-- The tuple names the part; the target is the one code generator that
-- covers them all.
local CPUALIAS = {wasm32 = "wasm", x86_64 = "amd64", aarch64 = "arm64",
		  i486 = "i386", i586 = "i386", i686 = "i386"}
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
	defs = {}, userdefs = {}, incs = {}, after = {}, libdirs = {},
	libs = {},
	files = {}, wl = {}, preinc = {}, verbose = false, entry = nil,
	soname = nil,
	opt = 0,
}
d.o = o

local VERSION = "0.3"

-- What mld says it is.  linux's scripts/ld-version.sh takes the first
-- line apart and wants "GNU ld" and then a version it knows, and libtool
-- greps for GNU; the words in parentheses say which linker it really is.
local function ldversion()
	local ok, id = pcall(require, "mcc.mccbuild")

	return "GNU ld (mld " .. VERSION .. (ok and (" " .. id) or "") ..
		", Mischief's Compiler Collection) 2.46"
end
-- The gnu triple each target answers -dumpmachine with.
local MACHINE = {amd64 = "x86_64", arm64 = "aarch64",
		 riscv64 = "riscv64", riscv32 = "riscv32",
		 xtensa = "xtensa", i386 = "i386"}
-- what the system is called in a tuple
local TUPLE = {linux = "linux-gnu", openbsd = "openbsd", none = "elf",
	       freebsd = "freebsd", netbsd = "netbsd", darwin = "darwin"}

local function settarget(s)
	local arch, sys = splittarget(s)

	o.target = CPUALIAS[arch] or arch
	if o.target == "i386" then o.bits = 32 end
	if sys then o.os = sys end
end

-- Flags that carry their value in the next argument, as gcc has them.
-- What each standard calls itself in __STDC_VERSION__.  gcc 8 defaults
-- to gnu17, and this compiler says the same.
local STDC = {c89 = nil, c90 = nil, c99 = "199901L", c11 = "201112L",
	      c17 = "201710L", c18 = "201710L", c23 = "202311L",
	      c2x = "202311L"}

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
	["-Wall"] = true, ["-Wextra"] = true, ["-w"] = true,
	["-pipe"] = true, ["-rdynamic"] = true,
	["-fno-PIC"] = true, ["-nostartfiles"] = true, ["-v"] = false,
}

-- `-Wp,a,b` hands a and b to the preprocessor, which is this program
-- too, so they are read as ordinary options.  In that spelling -MD and
-- -MMD name the file they write, which is how kbuild asks for one.
do
	local flat = {}

	for _, a in ipairs(argv) do
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
	argv = flat
end

local i = 1
local function value(a, n)
	if #a > n then return a:sub(n + 1) end
	i = i + 1
	return argv[i] or die("missing argument after " .. a)
end

while i <= #argv do
	local a = argv[i]
	local two = a:sub(1, 2)

	if prog == "mld" and (a == "-S" or a == "--strip-debug") then
		-- To the compiler -S means something else.
		o.strip = o.strip or "debug"
	elseif a == "-s" or prog == "mld" and a == "--strip-all" then
		o.strip = "all"
	elseif prog == "mld" and a == "--archive-debug" then
		-- An archive member's compressed debug sections are
		-- dropped unless this asks for them.
		o.archivedebug = true
	elseif prog == "mld" and (a == "-x" or a == "--discard-all") then
	elseif prog == "mld" and (a == "-m" or a:match("^%-m%a")) then
		-- The emulation, which says the machine.  elf_i386 is the
		-- 32-bit one a boot block links as; the rest name the
		-- machine the objects say already.
		local em = a == "-m" and value(a, 2) or a:sub(3)

		if em == "elf_i386" or em == "elf_i386_obsd" then
			settarget("i386")
		end
	elseif a == "--whole-archive" or a == "--no-whole-archive" then
		-- Every member of the archives between the two goes in,
		-- asked for or not: kbuild makes vmlinux.o that way.
		o.wholeon = a == "--whole-archive"
	elseif a == "--start-group" or a == "--end-group" or a == "-(" or
	       a == "-)" then
		-- The archives are read until nothing more is found
		-- anyway, so a group changes nothing here.
	elseif a == "-c" or a == "-S" or a == "-E" then
		o.stop = a:sub(2)
	elseif a == "-M" or a == "-MM" then
		-- The list of files read, and nothing else.  A configure
		-- script asks this way; a build system asks with -MD,
		-- which writes the same list beside the object.
		o.stop, o.deponly = "E", true
	elseif a == "-dM" then
		o.dumpmacros = true
	elseif a == "-no-pie" or a == "-nopie" then
		o.nopie = true
	elseif a == "-pie" then
		-- A program the loader relocates, which is a program the
		-- loader runs.  Decided after the hosted link below, which
		-- adds the C library to one.
		o.pie = true
	elseif a == "-r" then
		-- The inputs made into one object for a later link,
		-- which is how OpenBSD's library rules build.
		o.relocatable = true
	elseif a == "-X" then
		-- Which local names to drop from the table: they are
		-- only names, and keeping them changes nothing.  (`-x`
		-- is the language of the next input, as gcc has it.)
	-- The install step builds the runtime once, into the directory
	-- this names, for the target and flags given with it.
	elseif a:sub(1, 16) == "--mcc-runtime-to" then
		o.rtinto = a:match("^%-%-mcc%-runtime%-to=(.+)$") or
			die("--mcc-runtime-to=DIR")
	elseif a == "--trace" or (prog == "mld" and a == "-t") then
		o.trace = true
	elseif a:sub(1, 14) == "--why-extract=" then
		o.why = a:sub(15)
	elseif prog == "mld" and a == "--image-base" then
		-- where a PE image goes; an ELF one says it with -Ttext
		i = i + 1
	elseif a == "-shared" or a == "--shared" or a == "-Bshareable" then
		o.shared, o.pic = true, true
	elseif a == "--version-script" or a:match("^%-%-version%-script=") then
		-- Which names a shared object offers.
		o.versionscript = a:match("=(.*)$") or value(a, #a)
	elseif a == "-Bsymbolic" then
		o.symbolic = true
	elseif a == "-g" or a:match("^%-g[123]$") or a:match("^%-ggdb") or
	       a:match("^%-gdwarf") then
		o.debug = true
	elseif a == "-g0" then
		o.debug = false
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
	elseif a:sub(1, 10) == "-idirafter" and #a > 10 then
		o.after[#o.after + 1] = a:sub(11)
	elseif a == "-idirafter" then
		-- searched after every other directory, the system's too
		o.after[#o.after + 1] = value(a, #a)
	elseif a == "-isystem" then
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
		-- each one names another target of the same rule
		local t = value(a, 3)

		o.deptarget = o.deptarget and o.deptarget .. " " .. t or t
	elseif two == "-D" then
		local d = value(a, 2)
		local k, v = d:match("^([^=]+)=(.*)$")
		o.defs[k or d] = v or true
		o.userdefs[k or d] = true
	elseif two == "-U" then
		o.defs[value(a, 2)] = nil
		o.userdefs[value(a, 2)] = true
	elseif two == "-L" then
		o.libdirs[#o.libdirs + 1] = value(a, 2)
	elseif two == "-l" then
		o.libs[#o.libs + 1] = value(a, 2)
	elseif ({text = true, data = true, bss = true,
		 ["text-segment"] = true})[a:match("^%-T([%a%-]+)") or ""] then
		-- `-Ttext 0`: where a section starts, which boot blocks
		-- link with.  A script saying so is written before the link.
		local which, v = a:match("^%-T([%a%-]+)=?(.*)$")

		if v == "" then v = value(a, #a) end
		o.secat = o.secat or {}
		o.secat[which == "text-segment" and "text" or which] = v
		o.script, o.nostdlib = o.script or "", true
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
			-- These two are about the files around them on
			-- the line, so they are read in place.
			if w == "--whole-archive" or
			   w == "--no-whole-archive" then
				o.wholeon = w == "--whole-archive"
			else
				o.wl[#o.wl + 1] = w
			end
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
			print(ldversion())
			sys.exit(0)
		end
		o.verbose = true
	elseif a == "--version" then
		-- The commit is written by the build system, so a copy
		-- that was installed says which one it was built from.
		-- One run out of the source tree has no such file.
		local ok, id = pcall(require, "mcc.mccbuild")

		if prog == "mld" then
			print(ldversion())
		else
			print(prog .. " (mcc) " .. VERSION ..
				(ok and (" " .. id) or ""))
		end
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
		-- Answered once every option is read: --sysroot may follow.
		o.printdirs = true
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
		-- The same as -fuse-ld=cc.  --elf is the old name, from
		-- when the objects were the choice.
		o.syslink = "cc"
	elseif a:sub(1, 9) == "-fuse-ld=" then
		-- mld, or none, is this compiler's own linker.  Anything
		-- else hands the link to the system's driver, which knows
		-- where its startup files and libraries are: cc as it
		-- is, or cc told to run that linker.
		local ld = a:sub(10)

		o.syslink = (ld ~= "mld" and ld ~= "") and ld or nil
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
	       a:match("^%-fmacro%-prefix%-map=") or
	       a:match("^%-fdebug%-prefix%-map=") then
		-- old=new: a path under old is written as under new.  The
		-- macro map is for __FILE__, the debug map for the paths
		-- in debug information, and the file map is both.
		local old, new = a:match("^[^=]*=([^=]*)=(.*)$")

		if old and not a:match("^%-fdebug") then
			o.prefixmap = o.prefixmap or {}
			o.prefixmap[#o.prefixmap + 1] = {old, new}
		end
		if old and not a:match("^%-fmacro") then
			o.debugmap = o.debugmap or {}
			o.debugmap[#o.debugmap + 1] = {old, new}
		end
	elseif a == "-fcanon-prefix-map" then
		-- Paths are made absolute and plain before a map is tried.
		o.canonmap = true
	elseif a == "-fno-canon-prefix-map" then
		o.canonmap = false
	elseif a == "-pthread" then
		o.pthread = true
	elseif a == "-fcommon" then
		o.common = true
	elseif a == "-fno-common" then
		o.common = false
	elseif a == "-fshort-wchar" then
		-- `L"..."` is two bytes an element, which is what UEFI
		-- and the linux EFI stub are built for.
		o.shortwchar = true
	elseif a == "-fno-short-wchar" then
		o.shortwchar = false
	elseif a == "-mluaos" then
		-- a wasm program for lua-os: its one way out is lua-os's
		-- system call, in place of WASI
		o.luaos = true
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
		    "mcc/drive/opts.lua")
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
		if o.wholeon then
			o.whole = o.whole or {}
			o.whole[a] = true
		end
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
		print(ldversion())
		sys.exit(0)
	end
end

-- libtool reads the libraries line to find a library's dependencies,
-- and makes a static library alone when the system's are not there.
if o.printdirs then
	local libs = {here}

	for _, d in ipairs(o.libdirs) do libs[#libs + 1] = d end
	for _, d in ipairs{"/usr/lib64", "/lib64", "/usr/lib", "/lib",
			   "/usr/lib/x86_64-linux-gnu"} do
		local f = io.open(o.sysroot .. d .. "/.", "r")

		if f then
			f:close()
			libs[#libs + 1] = o.sysroot .. d
		end
	end
	print("install: " .. here .. "/")
	print("programs: =" .. here)
	print("libraries: =" .. table.concat(libs, ":"))
	sys.exit(0)
end
if #o.files == 0 and not o.rtinto then die("no input files") end

-- This compiler's own headers come after whatever was named, the way a
-- system include path does.  Building for this machine, the system
-- headers come after those.  -ffreestanding and -nostdlib keep them, as
-- gcc and clang do; only -nostdinc removes them.
if not o.nostdinc then
	local sysdirs = {}

	-- The libc a program is linked against owns its own headers, so
	-- they come before the stand-ins here.
	if o.target == H.host() then
		for _, dir in ipairs{"/usr/local/include", "/usr/include"} do
			local d = o.sysroot .. dir
			local f = io.open(d .. "/stdio.h")
			if f then
				f:close()
				sysdirs[#sysdirs + 1] = d
			end
		end
	end
	-- A -I that names a system directory is dropped, as gcc does, so
	-- this compiler's own headers, float.h among them, still come
	-- first.
	local issys = {}

	for _, d in ipairs(sysdirs) do issys[d] = true end
	for k = #o.incs, 1, -1 do
		if issys[(o.incs[k]:gsub("/+$", ""))] then
			table.remove(o.incs, k)
		end
	end
	o.incs[#o.incs + 1] = here .. "/include"
	for _, d in ipairs(sysdirs) do o.incs[#o.incs + 1] = d end
	o.incs[#o.incs + 1] = here ..
		((o.freestanding or o.nostdlib) and "/include/freestanding"
		 or "/include/hosted")
end
for _, d in ipairs(o.after) do o.incs[#o.incs + 1] = d end

d.arch = ARCH[o.target] or die("no target " .. o.target)
-- The target as the command line set it up.  A reload later sets it up
-- the same way, with the position independence it had here.  It loads
-- now only to refuse a -mregparm it has no use for.
d.pic0 = o.pic
if o.regparm then d.target() end

-- OpenBSD's compiler takes -fcommon unless told otherwise, and its tree
-- has yacc parsers that each define yyss with no value.
if o.common == nil then o.common = o.os == "openbsd" end
-- The stack protector's canary where the C library keeps it.  OpenBSD
-- has __guard_local, which the target writes by default; glibc and musl
-- keep it in the thread block and fail through __stack_chk_fail.  The
-- target decides, not -ffreestanding: musl builds itself freestanding.
if o.ssp and not o.guardsym and not o.guardreg and o.os ~= "openbsd" then
	if o.target == "amd64" then
		o.guardreg, o.guardsym = "fs", "40"
	elseif o.target == "i386" then
		o.guardreg, o.guardsym = "gs", "20"
	end
	if o.guardreg then
		o.guardfail = o.guardfail or "__stack_chk_fail"
	end
end

-- A system whose programs are position independent compiles that way
-- too, and it has to: an object built for a fixed address reaches a
-- library's data with a pc-relative instruction, which no loader can
-- fix up once the library lands somewhere else.  An object says nothing
-- about how it will be linked, so the decision is made here, where the
-- target is known.  A freestanding or hand-linked image is its own
-- world and wants none of it, a static link has no loader to fill a
-- table in, and `-fno-pic` settles it either way.
if not o.picsaid and
   not (o.nostdlib or o.freestanding or o.script or o.syslink or
        o.static) and
   o.target == H.host() and H.interpof(o) then
	o.pic = true
end
-- A wasm module is loaded where it was built for, in a memory of its
-- own, and has no table for a loader to fill: position independence
-- means nothing there, whatever a build system asked for.
if o.target == "wasm" then o.pic = false end
-- The module writer carries no DWARF, so -g says nothing here.
if o.target == "wasm" then o.debug = nil end

-- A hosted program built for the machine this is running on links
-- against the system's own library, the way any other compiler would.
-- The runtime here is for a program with no system to speak of.
-- A sysroot is not a reason to leave the hosted path: a cross build
-- against one is still a program with a libc and a loader, and the
-- start-up files being there is the evidence of that.
-- -pthread links the thread library, ahead of the C library.
if o.pthread and not (o.stop or o.nostdlib or o.freestanding) then
	o.libs[#o.libs + 1] = "pthread"
end
if not (o.nostdlib or o.freestanding or o.shared or o.dynamic or
	o.script or o.syslink or o.static or o.stop) and
   o.target == H.host() and H.interpof(o) and
   H.crtpath(o, (H.CRTSET[o.os] or {})[1]) then
	o.dynamic = true
	local havec = false

	for _, l in ipairs(o.libs) do
		if l == "c" then havec = true end
	end
	if not havec then o.libs[#o.libs + 1] = "c" end
end
if o.pie and not o.static and not o.stop then o.dynamic = true end
-- `-static` for this machine links the system's own libc.a.
if o.static and not (o.nostdlib or o.freestanding or o.stop) and
   o.target == H.host() and H.STATICCRT[o.os] and
   H.crtpath(o, H.STATICCRT[o.os][1][1]) then
	o.hostedstatic = true
	-- OpenBSD's cc makes a static program position independent
	-- unless told not to; rcrt0.o relocates it before main.
	if o.os == "openbsd" and not o.nopie then o.staticpie = true end
end
-- A shared library built for this machine names the C library too, as
-- gcc links one on Linux: glibc's libc.so is a script that also brings
-- libc_nonshared.a, where atexit lives.  OpenBSD's cc adds nothing, and
-- neither does this there.
if o.shared and not (o.nostdlib or o.freestanding or o.stop) and
   o.os ~= "openbsd" and o.target == H.host() and H.interpof(o) then
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
		["-dynamic-linker"] = "interp",
		["--version-script"] = "versionscript",
	}
	-- The same flags written as one word.  A single letter is left
	-- out on purpose: `-export-dynamic` begins with `-e`.
	local glued = {["--script="] = "script", ["-T"] = "script",
		       ["--entry="] = "entry",
		       ["--soname="] = "soname", ["-soname="] = "soname",
		       ["--dynamic-linker="] = "interp",
		       ["-dynamic-linker="] = "interp",
		       ["--version-script="] = "versionscript"}
	local i = 1

	while i <= #o.wl do
		local w = o.wl[i]
		local put = word[w]
		local rp = w:match("^%-%-?rpath=(.+)$")

		-- Where the loader looks for this program's libraries
		-- first.  Each one adds to the list.
		if (w == "-rpath" or w == "--rpath" or w == "-R") and
		   o.wl[i + 1] then
			rp = o.wl[i + 1]
			table.remove(o.wl, i)
		end
		if rp then
			o.rpath = o.rpath or {}
			o.rpath[#o.rpath + 1] = rp
			table.remove(o.wl, i)
			put = false
		elseif w == "--trace" or w == "-t" then
			o.trace = true
			table.remove(o.wl, i)
			put = false
		elseif w:sub(1, 14) == "--why-extract=" then
			o.why = w:sub(15)
			table.remove(o.wl, i)
			put = false
		elseif w == "-S" or w == "--strip-debug" then
			o.strip = o.strip or "debug"
			table.remove(o.wl, i)
			put = false
		elseif w == "-s" or w == "--strip-all" then
			o.strip = "all"
			table.remove(o.wl, i)
			put = false
		elseif w == "--archive-debug" then
			o.archivedebug = true
			table.remove(o.wl, i)
			put = false
		elseif w == "-disable-new-dtags" or
		       w == "--disable-new-dtags" or
		       w == "-enable-new-dtags" or
		       w == "--enable-new-dtags" then
			-- The old DT_RPATH also serves the libraries this
			-- one needs; DT_RUNPATH serves only this one.
			o.oldrpath = w:find("disable") ~= nil
			table.remove(o.wl, i)
			put = false
		elseif put and o.wl[i + 1] then
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
