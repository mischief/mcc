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

local as = require "as"
local obj = require "obj"

local HOST = "amd64"
local ARCH = {amd64 = "amd64", x86_64 = "amd64", riscv64 = "riscv",
	      riscv32 = "riscv", xtensa = "xtensa", arm64 = "arm64",
	      aarch64 = "arm64"}
-- the runtime a program gets when nothing says otherwise
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
	target = HOST, out = nil, stop = nil, pic = false, shared = false,
	nostdlib = false, defs = {}, incs = {}, libdirs = {}, libs = {},
	files = {}, wl = {}, verbose = false, entry = nil,
}

-- Whichever of the three was called, so that a complaint names the
-- program the caller asked for.
local prog = os.getenv("MCC_PROG") or
	(arg[0]:gsub(".*/", ""):gsub("%.lua$", ""))

local function die(msg)
	io.stderr:write(prog .. ": " .. msg .. "\n")
	os.exit(1)
end

-- Flags that carry their value in the next argument, as gcc has them.
local SEPARATE = {["-o"] = true, ["-I"] = true, ["-D"] = true,
		  ["-U"] = true, ["-L"] = true, ["-l"] = true,
		  ["-include"] = true, ["-isystem"] = true, ["-e"] = true,
		  ["-MF"] = true, ["-MT"] = true, ["-MQ"] = true,
		  ["-Xlinker"] = true, ["-z"] = true, ["--target"] = true}
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
	elseif a == "-e" or a == "--entry" then
		o.entry = value(a, 2)
	elseif a:sub(1, 9) == "--target=" then
		o.target = a:sub(10)
	elseif a == "-t" or a == "--target" then
		o.target = value(a, 2)
	elseif a:sub(1, 4) == "-Wl," then
		for w in a:sub(5):gmatch("[^,]+") do
			o.wl[#o.wl + 1] = w
		end
	elseif a == "-Xlinker" then
		o.wl[#o.wl + 1] = value(a, 8)
	elseif a == "-v" or a == "--verbose" then
		o.verbose = true
	elseif a == "--version" then
		print(prog .. " 0.2")
		os.exit(0)
	elseif IGNORE[a] or a:sub(1, 2) == "-O" or a:sub(1, 2) == "-W" or
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

if #o.files == 0 then die("no input files") end

-- This compiler's own headers come after whatever was named, the way a
-- system include path does.
if not o.nostdinc then
	o.incs[#o.incs + 1] = here .. "/include"
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

-- One text cache for the whole run: several sources share their headers,
-- and on a machine whose files live in flash reading them again is not
-- free.
local text = {}

local function tmp(name)
	local d = os.getenv("TMPDIR") or "/tmp"
	return ("%s/comp-%d-%s"):format(d, os.time() % 100000, name)
end

local made = {}
local function scrap(path)
	made[#made + 1] = path
	return path
end

local function base(path)
	return (path:gsub(".*/", ""):gsub("%.[^.]*$", ""))
end

-- .c -> .s
local function compile(path, out)
	local w = assert(io.open(out, "w"))
	local src = cpp.new{file = path, path = o.incs, define = o.defs,
		text = text}

	if o.stop == "E" then
		while true do
			local tk = src:next()

			if tk.kind == "eof" then break end
			if tk.kind == "str" then
				w:write('"', (tk.text:gsub('[\\"]', "\\%0")),
					'"\n')
			else
				w:write(tk.text or tostring(tk.val or
					tk.kind), "\n")
			end
		end
	else
		local p = parse.new(src, t, function(s) w:write(s) end,
			{wide = os.getenv("WIDE") ~= nil, pic = o.pic})

		p:program()
		if t.trailer then w:write(t.trailer) end
	end
	w:close()
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
	local kind = f:match("%.(%w+)$")
	local name = base(f)

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
	if kind == "s" or kind == "S" then
		local ofile = output(name, ".o", o.stop == "c")

		assemble(f, ofile)
		f, kind = ofile, "o"
	end
	if kind == "o" and o.stop ~= "c" then
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

if o.shared then
	ok, err = pcall(so.link, objs, w, {soname = out:gsub(".*/", "")})
else
	ok, err = pcall(ld.linkfiles, objs, w, {
		target = o.target, base = preset.base, place = preset.place,
		symbols = preset.symbols, detached = preset.detached,
		entry = o.entry,
	})
end
w:close()
for _, f in ipairs(made) do os.remove(f) end
if not ok then
	io.stderr:write(prog .. ": " .. tostring(err) .. "\n")
	os.exit(1)
end
os.execute("chmod +x " .. out)
