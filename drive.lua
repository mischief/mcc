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
-- become a program.  Each stage stops if the flags say to.  The option
-- reader, the compiler and the link are modules under mcc/drive, each
-- loaded only when its stage runs.

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. here .. "/?/init.lua;" .. package.path
package.cpath = here .. "/?.so;" .. package.cpath

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
require("mcc.strict").on()
-- Most of what a compile makes is dead a moment later, and what it
-- keeps, the bodies of a header's inline functions held for replay,
-- is large and long lived.  A collector that sweeps only the young
-- objects most of the time suits that: a few percent of a kernel
-- file's time, at the same peak memory.
collectgarbage("generational")

local sys = require "mcc.sys"

-- MCC_GCPAUSE trades time for memory: an incremental collector that
-- starts a cycle when the heap has grown by that percent.  150 holds a
-- kernel file to about four fifths of the memory for 7% more time.
local gcpause = tonumber(sys.getenv("MCC_GCPAUSE") or "")

if gcpause then collectgarbage("incremental", gcpause) end

-- Whichever of the three was called, so that a complaint names the
-- program the caller asked for.
local prog = sys.getenv("MCC_PROG") or
	(arg[0]:gsub(".*/", ""):gsub("%.lua$", ""))

local function die(msg)
	io.stderr:write(prog .. ": " .. msg .. "\n")
	sys.exit(1)
end

-- What the driver's parts share.  The parts that run once reach it as
-- the module mcc.drive.
local d = {here = here, prog = prog, die = die, text = {}}

package.loaded["mcc.drive"] = d

-- The modules the driver holds for the whole run.  Anything loaded
-- after is let go between stages, so a link does not carry the
-- compiler and a preprocessor does not carry the code generator.
local resident = {}

for k in pairs(package.loaded) do resident[k] = true end

local function drop()
	d.t, d.cc, d.text = nil, nil, {}
	for k in pairs(package.loaded) do
		-- the wasm units wait there for the module to be written
		if not resident[k] and k ~= "mcc.drive.wasm" then
			package.loaded[k] = nil
		end
	end
	collectgarbage()
end

-- Run a part that is needed once, and let it go.
local function once(name)
	require(name)
	package.loaded[name] = nil
end

-- The target, set up as the command line says.  It loads again after a
-- drop, set up the same way.
function d.target()
	if not d.t then
		local o = d.o
		local t = require("mcc.target." .. o.target)

		if o.regparm then
			if not t.regparm then
				die("-mregparm is not a choice on " .. o.target)
			end
			t.regparm(o.regparm)
		end
		if o.stackbound and t.stackboundary then
			t.stackboundary(o.stackbound)
		end
		if t.setpic then t.setpic(d.pic0) end
		d.t = t
	end
	return d.t
end

-- What the target and the system define, added once to what the
-- command line defined, and what the preprocessor needs of the target.
-- Only a compile asks, so a link of objects never loads the target.
function d.defines()
	if d.charsigned ~= nil then return end
	local o = d.o
	local t = d.target()

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
	for k, v in pairs(require("mcc.drive.host").OSDEF[o.os] or {}) do
		if o.defs[k] == nil then o.defs[k] = v end
	end
	d.charsigned = t.charsigned ~= false
end

function d.compile(...)
	d.defines()
	d.cc = d.cc or require "mcc.drive.cc"
	return d.cc(d, ...)
end

d.argv = arg
once("mcc.drive.opts")

local o = d.o

-- A name no other run of this program will pick.  Two compiles of files
-- with the same basename run at once under a parallel build, so the
-- clock is not enough to tell them apart.
-- Taken on first use: a compile that goes straight to an object needs
-- no scratch file, and so no name for one.
local token

function d.tmp(name)
	local dir = sys.getenv("TMPDIR") or "/tmp"

	token = token or (sys.tmpname():gsub(".*/", ""))
	return ("%s/mcc-%s-%s"):format(dir, token, name)
end

local made = {}
function d.scrap(path)
	made[#made + 1] = path
	return path
end

function d.cleanup()
	for _, f in ipairs(made) do sys.remove(f) end
	made = {}
end

-- The scratch files go whatever happens, not only when the compiler
-- finishes: /tmp is memory on many machines, and a build where half
-- the files fail would otherwise fill it.
local sweep <close> = setmetatable({}, {__close = function()
	d.cleanup()
end})

function d.base(path)
	return (path:gsub(".*/", ""):gsub("%.[^.]*$", ""))
end

local tmp, scrap, cleanup, base = d.tmp, d.scrap, d.cleanup, d.base
local compile = d.compile

-- A stage's output that only the next stage reads.  The compiler and the
-- assembler run in this one process, so the text is handed over as it
-- is and never written to a scratch file.
function d.membuf()
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

local membuf = d.membuf

-- .s -> .o
-- Which ELF the object is written as.  Only x86 has a narrow one that
-- is not a target of its own, and only because a kernel links its real
-- mode trampoline as elf32-i386.
function d.objtarget()
	if o.target == "amd64" and o.bits and o.bits < 64 then
		return "i386"
	end
	return o.target
end

-- `name` is the source the object says it came from: by default a file
-- named here, and none for text this compiler wrote.  "" says none.
function d.assemble(path, out, name)
	local as = require "mcc.as"
	local elf = require "mcc.elf"
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
	if name == nil and type(path) == "string" and path ~= "-" then
		name = path
	end
	local u = as.assemble(text, {arch = d.arch,
		srcname = name ~= "" and name or nil,
		bits = o.bits ~= 64 and o.bits or nil,
		pinsyscalls = o.os == "openbsd" and o.target == "amd64",
		xlen = o.target == "riscv32" and 32 or 64})
	local w = assert(io.open(out, "wb"))

	w:write(elf.relocatable(u, d.objtarget()))
	w:close()
end

local assemble = d.assemble

-- One pass of a staged compile, in whatever process runs it.
local function runpass(p)
	if p.kind == "cpp" or p.kind == "cc" then
		compile(p.input, p.out, false, p)
	elseif p.kind == "cppasm" then
		compile(p.input, p.out, true, {kind = "cpp", name = p.name})
	elseif p.kind == "as" then
		assemble(p.input, p.out, p.name)
	else
		die("no pass " .. tostring(p.kind))
	end
end

-- A process started to run one pass does that and nothing else.  Only
-- the compiler proper needs the target once the macros are known.
if o.pass then
	if o.pass.kind ~= "cc" then
		if o.pass.kind ~= "as" then d.defines() end
		drop()
	end
	runpass(o.pass)
	sys.exit(0)
end

-- MCC_STAGED runs a compile as passes with files between them, each
-- pass in a process of its own where this system can start one and in
-- this process otherwise, with the modules of the last pass let go.
-- The peak is then the largest pass rather than all of them together.
-- MCC_STAGED=here keeps the passes in this process.
local staged = sys.getenv("MCC_STAGED")
local self = staged and staged ~= "here" and sys.self()

staged = staged and staged ~= "" and staged ~= "0" and
	o.stop ~= "E" and not o.dumpmacros

-- Preprocessing needs nothing more of the target than its macros, and
-- a staged compile leaves the target to its passes.
if o.stop == "E" then d.defines() end
if o.stop == "E" or staged then drop() end

local function pass(kind, input, out, name)
	if not self then
		drop()
		runpass{kind = kind, input = input, out = out, name = name}
		drop()
		return
	end
	local argv = table.move(self, 1, #self, 1, {})

	table.move(arg, 1, #arg, #argv + 1, argv)
	for _, w in ipairs{"--mcc-pass", kind, input, out, name} do
		argv[#argv + 1] = w
	end
	-- The pass has said what went wrong already.
	if not sys.exec(argv, {verbose = o.verbose}) then
		cleanup()
		sys.exit(1)
	end
end

local objs = {}
-- The shared objects named on the command line, which become names the
-- loader looks up rather than anything read into the image.
local shlibs = {}

-- Whether a file is an ELF relocatable object.
local function relocatable(path)
	local h = io.open(path, "rb")
	local head = h and h:read(18) or ""

	if h then h:close() end
	return #head == 18 and head:sub(1, 4) == "\127ELF" and
		string.unpack("<I2", head, 17) == 1
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
local function kindof(f)
	-- `-` is C on the standard input, which is how a build system asks
	-- the compiler about itself.
	local kind = o.lang or (f == "-" and "c" or f:match("%.(%w+)$"))

	-- `.i` is C already through the preprocessor; running it through
	-- again changes nothing.
	if kind == "i" then kind = "c" end
	-- A header goes through the preprocessor like C: perl's Errno
	-- reads `cc -E -dM errno.h`.
	if kind == "h" and o.stop == "E" then kind = "c" end
	return kind
end

-- The last input the compiler reads.  Past it the compiler is let go
-- before the assembler loads.
local lastcc = 0

for n, f in ipairs(o.files) do
	local kind = kindof(f)

	if kind == "c" or kind == "S" then lastcc = n end
end

for n, given in ipairs(o.files) do
	local f = given
	-- whether f is text this compiler wrote rather than a file named
	local ours = false
	local kind = kindof(f)
	local name = f == "-" and "stdin" or base(f)

	if kind == "c" then
		if o.stop == "E" and not o.out then
			compile(f, "/dev/stdout")
			goto next
		end
		local final = o.stop == "S" or o.stop == "E"

		if staged then
			local i = scrap(tmp(name .. ".i"))
			local s = final and output(name, ".s", true) or
				scrap(tmp(name .. ".s"))

			pass("cpp", f, i, final and s or "")
			pass("cc", i, s, f)
			if final then goto next end
			f, kind, ours = s, "s", true
		else
			local s = final and output(name, o.stop == "E" and
				".i" or ".s", true) or membuf()

			compile(f, s)
			if final then goto next end
			f, kind = s, "s"
		end
	end
	-- A capital S means the assembly goes through the preprocessor
	-- first, which is how a header hands macros to it.
	if kind == "S" then
		if o.stop == "E" and not o.out then
			compile(f, "/dev/stdout", true)
			goto next
		end
		local i = o.stop == "E" and output(name, ".s", true) or
			staged and scrap(tmp(name .. ".s")) or membuf()

		if staged then
			pass("cppasm", f, i, "")
			ours = true
		else
			compile(f, i, true)
		end
		if o.stop == "E" then goto next end
		f, kind = i, "s"
	end
	-- A wasm module is whole: there is no relocatable object to make
	-- and nothing to link it against, so the text is kept and the
	-- module written once every input has been read.
	-- An object here is the unit's text with a line saying so, and
	-- each is given its own names only when the module is put
	-- together, where the order is known.
	if kind == "s" and o.target == "wasm" then
		local text

		-- the compiler's own output is held in memory, a file named
		-- on the command line is read
		if type(f) == "table" then
			text = f:text()
		else
			local h = assert(io.open(f))

			text = h:read("a")
			h:close()
		end
		if o.stop == "c" then
			local w = assert(io.open(output(name, ".o", true), "w"))

			w:write(require("mcc.drive.wasm").OBJ, text)
			w:close()
		else
			local W = require "mcc.drive.wasm"

			W.text[#W.text + 1] = W.scope(text)
		end
		goto next
	end
	if o.target == "wasm" and o.stop ~= "c" then
		local W = require "mcc.drive.wasm"
		local WASMOBJ = W.OBJ
		local h = assert(io.open(f, "rb"))
		local text = h:read("a")

		h:close()
		if text:sub(1, #WASMOBJ) == WASMOBJ then
			W.text[#W.text + 1] = W.scope(text:sub(#WASMOBJ + 1))
		elseif text:sub(1, 8) == "!<arch>\n" then
			for _, m in ipairs(require("mcc.ar").members(f)) do
				local body = text:sub(m.off + 1, m.off + m.size)

				if body:sub(1, #WASMOBJ) == WASMOBJ then
					W.text[#W.text + 1] =
					    W.scope(body:sub(#WASMOBJ + 1))
				end
			end
		else
			die(f .. ": not a wasm object")
		end
		goto next
	end
	if kind == "s" then
		local ofile = output(name, ".o", o.stop == "c")

		if staged then
			pass("as", f, ofile, ours and "" or f)
		else
			if n == lastcc then drop() end
			assemble(f, ofile)
		end
		f, kind = ofile, "o"
	end
	-- A shared object named on the command line is a library this
	-- program wants, not something to copy from.  The loader is told
	-- its name and finds it; nothing of it is read into the image.
	-- The name is a guess and the file settles it: OpenBSD's
	-- bsd.lib.mk calls the objects it builds for a shared library
	-- `bar.so`, and those are objects to link in.
	if (f:match("%.so$") or f:match("%.so%.[%d.]+$")) and
	   not relocatable(f) then
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

-- The compiler is done with, and the link starts from the driver alone.
drop()
d.objs, d.shlibs = objs, shlibs
once("mcc.drive.link")
