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
-- The tokenizer's C module sits beside the Lua, when it was built.
package.cpath = here .. "/?.so;" .. package.cpath
-- Reading a global that was never set is a mistake here, and a local
-- named later in a file is a global to the code above it.
require("strict").on()

local as = require "as"
local obj = require "obj"

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
local RTMATH = {"rt/softfp.c", "rt/wide.c", "rt/widefp.c", "rt/varargs.c"}
local RTIO = {"rt/miniio.c", "rt/ministr.c"}

local o = {
	target = HOST, os = OS, out = nil, stop = nil, pic = false,
	shared = false, retclean = false, cet = false, retpoline = false,
	ssp = nil,
	nostdlib = false, defs = {}, incs = {}, libdirs = {}, libs = {},
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
	["-no-pie"] = true, ["-pie"] = true, ["-fno-pic"] = true,
	["-fno-PIC"] = true, ["-nostartfiles"] = true, ["-v"] = false,
}

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
	elseif a == "-fpic" or a == "-fPIC" or a == "-fpie" or
	       a == "-fPIE" then
		o.pic = true
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
	elseif a == "-MF" then
		o.depfile = value(a, 3)
	elseif a == "-MQ" or a == "-MT" then
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
		print(prog .. " (mcc) " .. VERSION)
		print("Mischief's Compiler Collection.  " ..
			"Compatible with GNU C.")
		os.exit(0)
	elseif a == "-dumpversion" then
		print(VERSION)
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
	return ({x86_64 = "amd64", aarch64 = "arm64",
		 riscv64 = "riscv64"})[m or ""]
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
local token = (os.tmpname():gsub(".*/", ""))

local function tmp(name)
	local d = os.getenv("TMPDIR") or "/tmp"
	return ("%s/mcc-%s-%s"):format(d, token, name)
end

local made = {}
local function scrap(path)
	made[#made + 1] = path
	return path
end

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
		text = text, preinclude = o.preinc}

	-- -dM lists what is defined at the end rather than what came out.
	if o.dumpmacros then
		while src:next().kind ~= "eof" do end
		local names = {}

		for k, m in pairs(src.macros) do
			if k ~= "__LINE__" and k ~= "__FILE__" then
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

		while true do
			local tk = src:next()

			if tk.kind == "eof" then break end
			if tk.file ~= file or tk.line < line then
				file, line = tk.file, tk.line
				w:write(('\n# %d "%s"\n'):format(line,
					file or "-"))
				col = 0
			elseif tk.line > line then
				-- a run of blank lines, up to a point:
				-- past that a marker says where we are
				if tk.line - line > 8 then
					w:write(('\n# %d "%s"\n')
						:format(tk.line, file or "-"))
				else
					w:write(("\n"):rep(tk.line - line))
				end
				line, col = tk.line, 0
			elseif col > 0 and tk.ws then
				w:write(" ")
			end
			if tk.kind == "str" then
				w:write('"', escape(tk.text), '"')
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
			 ssp = o.ssp})

		p:program()
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

	w:write(obj.write(u, arch))
	w:close()
end

local objs = {}

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
	local kind = f == "-" and "c" or f:match("%.(%w+)$")
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
	if (kind == "o" or kind == "a") and o.stop ~= "c" then
		objs[#objs + 1] = f
	end
	::next::
end

if o.stop then
	for _, f in ipairs(made) do os.remove(f) end
	os.exit(0)
end

-- linking
local ld = require "ld"
local so = require "so"

-- the pieces a program needs that no source named
if not o.nostdlib then
	local extra = {}

	if not o.shared then
		extra[#extra + 1] = root .. "/" .. CRT[o.target]
		for _, f in ipairs(RTIO) do
			extra[#extra + 1] = root .. "/" .. f
		end
	end
	for _, f in ipairs(RTMATH) do extra[#extra + 1] = root .. "/" .. f end
	for _, f in ipairs(extra) do
		local s = scrap(tmp(base(f) .. ".rt.s"))

		if f:match("%.c$") then
			local save = o.incs
			o.incs = {root .. "/include",
				  root .. "/include/freestanding"}
			compile(f, s)
			o.incs = save
		else
			local h = assert(io.open(f))
			local w = assert(io.open(s, "w"))

			w:write(h:read("a"))
			h:close()
			w:close()
		end
		local ofile = scrap(tmp(base(f) .. ".rt.o"))

		assemble(s, ofile)
		objs[#objs + 1] = ofile
	end
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
elseif o.shared then
	ok, err = pcall(so.link, objs, w, {soname = out:gsub(".*/", "")})
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
for _, f in ipairs(made) do os.remove(f) end
if not ok then
	io.stderr:write(prog .. ": " .. tostring(err) .. "\n")
	os.exit(1)
end
os.execute("chmod +x " .. out)
