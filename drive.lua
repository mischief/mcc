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
-- Reading a global that was never set is a mistake here, and a local
-- named later in a file is a global to the code above it.
require("strict").on()

local as = require "as"
local elf = require "elf"

local HOST = "amd64"
local ARCH = {amd64 = "amd64", x86_64 = "amd64", riscv64 = "riscv",
	      riscv32 = "riscv", xtensa = "xtensa", arm64 = "arm64",
	      aarch64 = "arm64"}
-- the runtime a program gets when nothing says otherwise
-- The system a program is built for, which decides the entry code, the
-- system call numbers, and what the preprocessor says it is.  It comes
-- from the target tuple, and from the machine this runs on when the
-- tuple says only an architecture.
local SYSTEM = {linux = "linux", openbsd = "openbsd", freebsd = "freebsd",
		netbsd = "netbsd", darwin = "darwin", none = "none",
		elf = "none", macosx = "darwin", apple = "darwin"}

local function system()
	local p = io.popen("uname -s 2>/dev/null")

	if not p then return "linux" end
	local n = p:read("l")

	p:close()
	return SYSTEM[(n or "linux"):lower()] or "linux"
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
		"rt/atomic.c", "rt/dso.c", "rt/varargs.c"}
local RTIO = {"rt/miniio.c", "rt/ministr.c"}

local o = {
	target = HOST, os = OS, out = nil, stop = nil, pic = false,
	shared = false, retclean = false, cet = false, retpoline = false,
	nomarkers = false, lang = nil, syslink = false,
	dynamic = false, interp = nil, needed = {}, sysroot = "",
	stdc = "201710L",
	ssp = nil,
	nostdlib = false, visibility = nil,
	defs = {}, incs = {}, libdirs = {}, libs = {},
	files = {}, wl = {}, preinc = {}, verbose = false, entry = nil,
	opt = 0,
}

-- Whichever of the three was called, so that a complaint names the
-- program the caller asked for.
local VERSION = "0.2"
-- The gnu triple each target answers -dumpmachine with.
local MACHINE = {amd64 = "x86_64", arm64 = "aarch64",
		 riscv64 = "riscv64", riscv32 = "riscv32",
		 xtensa = "xtensa"}
-- what the system is called in a tuple
local TUPLE = {linux = "linux-gnu", openbsd = "openbsd", none = "elf",
	       freebsd = "freebsd", netbsd = "netbsd", darwin = "darwin"}

local prog = os.getenv("MCC_PROG") or
	(arg[0]:gsub(".*/", ""):gsub("%.lua$", ""))

local function settarget(s)
	local arch, sys = splittarget(s)

	o.target = arch
	if sys then o.os = sys end
end

local function die(msg)
	io.stderr:write(prog .. ": " .. msg .. "\n")
	os.exit(1)
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
local CRTSET = {linux = {"Scrt1.o", "crti.o", "crtn.o"},
		openbsd = {"crt0.o", "crtbegin.o", "crtend.o"}}

-- What -x calls each kind of input.
local XLANG = {c = "c", ["c-header"] = "c", assembler = "s",
	       ["assembler-with-cpp"] = "S"}

local SEPARATE = {["-o"] = true, ["-I"] = true, ["-D"] = true,
		  ["-U"] = true, ["-L"] = true, ["-l"] = true,
		  ["-e"] = true,
		  ["-Xlinker"] = true, ["-z"] = true, ["--target"] = true,
		  ["-x"] = true}
-- Flags that mean nothing here and must not be mistaken for a file.
local IGNORE = {
	["-Wall"] = true, ["-Wextra"] = true, ["-w"] = true, ["-g"] = true,
	["-pipe"] = true, ["-pthread"] = true, ["-rdynamic"] = true,
	["-s"] = true, ["-MD"] = true, ["-MMD"] = true, ["-MP"] = true,
	["-no-pie"] = true, ["-pie"] = true,
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
	elseif a == "-dM" then
		o.dumpmacros = true
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
	elseif a == "-v" or a == "--verbose" then
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
		os.exit(0)
	elseif a == "-dumpversion" then
		print(VERSION)
		os.exit(0)
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
		os.exit(0)
	elseif a == "-print-search-dirs" then
		print("install: " .. here .. "/")
		print("programs: =" .. here)
		print("libraries: =" .. here)
		os.exit(0)
	elseif a == "-dumpmachine" then
		print((MACHINE[o.target] or o.target) .. "-unknown-" ..
			(TUPLE[o.os] or o.os))
		os.exit(0)
	elseif a:sub(1, 2) == "-O" then
		-- -O0 writes what the code table said and nothing else,
		-- which is what a debugger and a bug report want.
		local n = a:sub(3)

		o.opt = n == "" and 1 or (tonumber(n) or 1)
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
			os.exit(0)
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
	elseif a == "-fno-stack-protector" then
		o.ssp = nil
	elseif a == "-mretpoline" or a == "-mretpoline-external-thunk" then
		o.retpoline = true
	elseif a == "-mno-retpoline" then
		o.retpoline = false
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
		print("mld " .. VERSION ..
			", the linker of Mischief's Compiler Collection")
		os.exit(0)
	end
end

if #o.files == 0 then die("no input files") end

-- The machine this is running on, which decides whether the system
-- headers are the right ones to read.
local function host()
	local p = io.popen("uname -m 2>/dev/null")
	if not p then return nil end
	local m = p:read("l")
	p:close()
	-- Each system has its own name for the same machine.
	return ({x86_64 = "amd64", amd64 = "amd64", aarch64 = "arm64",
		 arm64 = "arm64", riscv64 = "riscv64"})[m or ""]
end

-- This compiler's own headers come after whatever was named, the way a
-- system include path does.  Building for this machine, the system
-- headers come after those: a hosted program wants the libc it will be
-- linked against, and a freestanding one owes nothing to any libc.
if not o.nostdinc then
	o.incs[#o.incs + 1] = here .. "/include"
	-- The libc a program is linked against owns its own headers, so
	-- they come before the stand-ins here.
	if not o.freestanding and not o.nostdlib and o.target == host() then
		for _, d in ipairs{"/usr/local/include", "/usr/include"} do
			d = o.sysroot .. d
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
local t = require("target." .. o.target)

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

-- One text cache for the whole run: several sources share their headers,
-- and on a machine whose files live in flash reading them again is not
-- free.
local text = {}

-- A name no other run of this program will pick.  Two compiles of files
-- with the same basename run at once under a parallel build, so the
-- clock is not enough to tell them apart.
-- os.tmpname makes the file as well as the name, and only the name is
-- wanted here.
local token = (function()
	local t = os.tmpname()

	os.remove(t)
	return (t:gsub(".*/", ""))
end)()

local function tmp(name)
	local d = os.getenv("TMPDIR") or "/tmp"
	return ("%s/mcc-%s-%s"):format(d, token, name)
end

local made = {}
local function scrap(path)
	made[#made + 1] = path
	return path
end

local function cleanup()
	for _, f in ipairs(made) do os.remove(f) end
	made = {}
end

-- The scratch files go whatever happens, not only when the compiler
-- finishes: /tmp is memory on many machines, and a build where half
-- the files fail would otherwise fill it.
local sweep <close> = setmetatable({}, {__close = cleanup})

local function base(path)
	return (path:gsub(".*/", ""):gsub("%.[^.]*$", ""))
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
	local w = assert(io.open(out, "w"))
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
		text = text, preinclude = o.preinc, stdc = o.stdc,
		charsigned = t.charsigned ~= false,
		nojoin = pponly or o.stop == "E", asm = pponly}

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
			if tk.kind == "str" then
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
		local p = parse.new(src, t, function(s) w:write(s) end,
			{wide = os.getenv("WIDE") ~= nil, pic = o.pic,
			 opt = o.opt, retclean = o.retclean,
			 cet = o.cet, retpoline = o.retpoline,
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
		if t.trailer then w:write(t.trailer) end
	end
	w:close()
	-- -MF names a file listing what was read, which a build system
	-- reads to know when to build again.
	if o.depfile then
		local d = assert(io.open(o.depfile, "w"))
		local seen = {}

		d:write(o.deptarget or o.out or out, ":")
		for _, f in ipairs(src.read) do
			if not seen[f] then
				seen[f] = true
				d:write(" ", (f:gsub("[ \\]", "\\%0")))
			end
		end
		d:write("\n")
		d:close()
	end
end

-- .s -> .o
local function assemble(path, out)
	local f = assert(io.open(path))
	local text = f:read("a")

	f:close()
	local u = as.assemble(text, {arch = arch,
		xlen = o.target == "riscv32" and 32 or 64})
	local w = assert(io.open(out, "wb"))

	w:write(elf.relocatable(u, o.target))
	w:close()
end

local function crtpath(name)
	for _, d in ipairs{"/usr/lib64", "/usr/lib/x86_64-linux-gnu",
			   "/usr/lib", "/lib64", "/usr/lib/gcc"} do
		d = o.sysroot .. d
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
-- fix up once the library lands somewhere else.  An object says nothing
-- about how it will be linked, so the decision is made here, where the
-- target is known.  A freestanding or hand-linked image is its own
-- world and wants none of it, a static link has no loader to fill a
-- table in, and `-fno-pic` settles it either way.
if not o.picsaid and
   not (o.nostdlib or o.freestanding or o.script or o.syslink or
        o.static) and
   o.sysroot == "" and
   o.target == host() and (INTERP[o.os] or {})[o.target] then
	o.pic = true
end

-- A hosted program built for the machine this is running on links
-- against the system's own library, the way any other compiler would.
-- The runtime here is for a program with no system to speak of.
if not (o.nostdlib or o.freestanding or o.shared or o.dynamic or
	o.script or o.syslink or o.static or o.stop) and
   o.sysroot == "" and
   o.target == host() and (INTERP[o.os] or {})[o.target] and
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
	local i = 1

	while i <= #o.wl do
		local w = o.wl[i]

		if (w == "-T" or w == "--script") and o.wl[i + 1] then
			o.script = o.wl[i + 1]
			table.remove(o.wl, i)
			table.remove(o.wl, i)
		elseif w:sub(1, 2) == "-T" and #w > 2 then
			o.script = w:sub(3)
			table.remove(o.wl, i)
		elseif w:sub(1, 9) == "--script=" then
			o.script = w:sub(10)
			table.remove(o.wl, i)
		else
			i = i + 1
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

for _, f in ipairs(o.files) do
	-- `-` is C on the standard input, which is how a build system asks
	-- the compiler about itself.
	local kind = o.lang or (f == "-" and "c" or f:match("%.(%w+)$"))
	local name = f == "-" and "stdin" or base(f)

	if kind == "c" then
		if o.stop == "E" and not o.out then
			compile(f, "/dev/stdout")
			goto next
		end
		local s = output(name, o.stop == "E" and ".i" or ".s",
			o.stop == "S" or o.stop == "E")

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
		local i = output(name, ".s", o.stop == "E")

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
	elseif (kind == "o" or kind == "a") and o.stop ~= "c" then
		objs[#objs + 1] = f
	end
	::next::
end

if o.stop then
	cleanup()
	os.exit(0)
end

-- Compile and assemble runtime sources into objects appended to `into`.
local function rtbuild(list, into)
	for _, f in ipairs(list) do
		local a = scrap(tmp(base(f) .. ".rt.s"))

		if f:match("%.c$") then
			local save = o.incs
			o.incs = {root .. "/include",
				  root .. "/include/freestanding"}
			compile(f, a)
			o.incs = save
		else
			local h = assert(io.open(f))
			local w = assert(io.open(a, "w"))

			w:write(h:read("a"))
			h:close()
			w:close()
		end
		local ofile = scrap(tmp(base(f) .. ".rt.o"))

		assemble(a, ofile)
		into[#into + 1] = ofile
	end
end

-- Linking against a real system: the objects are ELF, so the system's
-- own driver knows where its startup files and libraries are and this
-- one does not have to.  That is how a new compiler is brought up.
if o.syslink then
	local cmd = {os.getenv("MCC_SYSLD") or "cc"}

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
	for _, f in ipairs(objs) do cmd[#cmd + 1] = quote(f) end
	for _, d in ipairs(o.libdirs) do cmd[#cmd + 1] = "-L" .. quote(d) end
	for _, l in ipairs(o.libs) do cmd[#cmd + 1] = "-l" .. quote(l) end
	for _, a in ipairs(o.wl) do
		cmd[#cmd + 1] = "-Wl," .. quote(a)
	end
	cmd[#cmd + 1] = "-o"
	cmd[#cmd + 1] = quote(o.out or "a.out")
	local line = table.concat(cmd, " ")

	if o.verbose then io.stderr:write(line .. "\n") end
	local ok = os.execute(line)

	cleanup()
	os.exit(ok and 0 or 1)
end

local ld = require "ld"
local so = require "so"

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
	elseif not o.shared then
		extra[#extra + 1] = root .. "/" .. CRT[o.target]
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
			if not nm then
				local best
				local ls = io.popen(("ls -1 %s/lib%s.so.* " ..
					"2>/dev/null"):format(d, l))

				for line in ls:lines() do best = line end
				ls:close()
				nm = best and elf.soname(best)
				if nm then found = best end
			end
			if nm then break end
		end
		need[#need + 1] = nm or ("lib" .. l .. ".so")
		if found then libpaths[#libpaths + 1] = found end
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
		soname = o.shared and out:gsub(".*/", "") or nil,
		interp = not o.shared and
			(o.interp or (INTERP[o.os] or {})[o.target]) or nil,
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
	io.stderr:write(prog .. ": " .. tostring(err) .. "\n")
	os.exit(1)
end
os.execute("chmod +x " .. out)
