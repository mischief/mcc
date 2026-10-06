-- SPDX-License-Identifier: ISC
-- The last stage: objects become a program, a shared object or a wasm
-- module, with the runtime this compiler carries built on demand.  The
-- driver runs this once, after the compiler has been let go.

local d = require "mcc.drive"
local objs, shlibs = d.objs, d.shlibs
local sys = require "mcc.sys"
local H = require "mcc.drive.host"
local o, root, prog, die = d.o, d.here, d.prog, d.die
local tmp, scrap, cleanup, base = d.tmp, d.scrap, d.cleanup, d.base

local CRT = {amd64 = "rt/linux-amd64.s", riscv64 = "rt/linux-riscv.s",
	     riscv32 = "rt/linux-riscv.s", xtensa = "rt/sim-xtensa.s",
	     arm64 = "rt/linux-arm64.s"}
-- The arithmetic a target cannot do in instructions, which any object may
-- need, and the few library calls a program does.  A shared object gets
-- only the first: it has an interpreter or a program around it for the
-- rest, and an unused system call in it would be an import nothing
-- satisfies.
local RTMATH = {"rt/softfp.c", "rt/wide.c", "rt/widefp.c", "rt/bits.c",
		"rt/half.c",
		"rt/atomic.c", "rt/dso.c", "rt/varargs.c", "rt/complex.c"}
local RTIO = {"rt/miniio.c", "rt/ministr.c"}
-- What compiled Lua calls: it runs on the system's C library.
local RTLUA = {"rt/lua/lrt.c", "rt/lua/lrtlib.c", "rt/lua/lrtstr.c",
	       "rt/lua/lrtio.c", "rt/lua/lrtpkg.c", "rt/lua/lrtco.c"}
if o.os == "openbsd" and o.target == "amd64" then
	CRT.amd64 = "rt/openbsd-amd64.s"
end

-- A module is written in one piece, from the text of every input at
-- once: there is no object to link and nothing to link it against.
if o.target == "wasm" then
	local W = require "mcc.drive.wasm"
	local out = o.out or "a.wasm"

	-- The runtime this compiler carries, compiled the same way and
	-- kept with the rest: a module has no archive to pull it from.
	-- -nostdlib drops the C library half and keeps what the code
	-- generated here calls, as libgcc would be kept.
	local rtfiles = { "rt/wasmjmp.c", "rt/varargs.c", "rt/bits.c",
		"rt/wide.c", "rt/wasmfp.c", "rt/atomic.c" }

	if not o.nostdlib then
		if o.luaos then
			rtfiles[#rtfiles + 1] = "rt/wasmluaos.c"
		else
			rtfiles[#rtfiles + 1] = "rt/wasm.c"
			rtfiles[#rtfiles + 1] = "rt/wasi.c"
		end
		for _, f in ipairs({
		    "rt/wasmsys.c", "rt/wasmio.c", "rt/ministr.c",
		    "rt/wasmstr.c", "rt/wasmfmt.c", "rt/wasmmath.c",
		    "rt/wasmheap.c", "rt/wasmbig.c" }) do
			rtfiles[#rtfiles + 1] = f
		end
	end
	do
		local save = o.incs

		o.incs = { root .. "/include",
			root .. "/include/freestanding" }
		-- what the caller already named, so a runtime file given
		-- on the command line is not compiled a second time
		local given = {}

		for _, p in ipairs(o.files) do
			given[(p:gsub(".*/", ""))] = true
		end
		for _, f in ipairs(rtfiles) do
		    if not given[(f:gsub(".*/", ""))] then
			local a = scrap(tmp(base(f) .. ".rt.s"))

			d.compile(root .. "/" .. f, a)
			local h = assert(io.open(a))

			W.text[#W.text + 1] = W.scope(h:read("a"))
			h:close()
		    end
		end
		o.incs = save
	end
	local w = assert(io.open(out, "wb"))
	local whole = table.concat(W.text, "\n")
	local dump = os.getenv("WASM_DUMP")

	if dump then
		local h = io.open(dump, "w")

		h:write(whole)
		h:close()
	end
	local ok, err = pcall(function()
		w:write(require("mcc.as.wasm").module(whole))
	end)

	w:close()
	if not ok then
		os.remove(out)
		die(tostring(err))
	end
	cleanup()
	os.exit(0)
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
	for _, f in ipairs{"rt/lua/lrt.h", "rt/lua/lrtaux.h"} do
		eat(root .. "/" .. f)
	end
	for _, m in ipairs{"drive.lua", "mcc/parse.lua", "mcc/gen.lua",
			   "mcc/as.lua", "mcc/cpp.lua", "mcc/lex.lua",
			   "mcc/md.lua", "mcc/tree.lua", "mcc/peep.lua",
			   "mcc/ir.lua", "mcc/drive/cc.lua",
			   "mcc/target/" .. o.target .. ".lua",
			   "mcc/as/" .. o.target .. ".lua"} do
		eat(root .. "/" .. m)
	end
	rtkey = ("%08x"):format(h)
	return rtkey
end

-- The flags that change the code the runtime compiles to, as a word for
-- its name.  Empty is the plain build the install step makes; anything
-- else, a kernel's code model or retpolines, is built on demand.
local function rtvariant()
	local w = {}

	for _, k in ipairs{"cmodel", "small", "retclean", "cet",
			   "retpoline", "rethunk", "nosse", "shortwchar",
			   "guardsym", "guardfail", "guardreg"} do
		local v = o[k]

		if v and v ~= "" then
			w[#w + 1] = k .. (v == true and "" or ("=" .. tostring(v)))
		end
	end
	return table.concat(w, ",")
end

-- Compile one runtime source into the object at `dest`.  The program's
-- own -D, -include, stack protector and optimizing level are not the
-- runtime's: it is always built optimized and position independent,
-- which a static program, a PIE and a shared object can all take.
-- Whether a Lua program's runtime has to be position independent.
local function luapic()
	return (o.pic or o.shared or o.pie) and true or false
end

local function rtcompile(f, dest, hosted)
	local a

	d.defines()

	if f:match("%.c$") then
		local keep = {incs = o.incs, debug = o.debug, defs = o.defs,
			      preinc = o.preinc, ssp = o.ssp, opt = o.opt,
			      visibility = o.visibility, pic = o.pic}

		-- What the machine and the system define stays; what the
		-- command line defined or took away does not.
		local defs = {}

		for k, v in pairs(o.defs) do
			if not o.userdefs[k] then defs[k] = v end
		end
		for _, set in ipairs{d.target().predef or {},
				       H.OSDEF[o.os] or {}} do
			for k, v in pairs(set) do
				if defs[k] == nil then defs[k] = v end
			end
		end
		-- The Lua runtime is a hosted program's and keeps the
		-- system's headers.
		if not hosted then
			o.incs = {root .. "/include",
				  root .. "/include/freestanding"}
		end
		o.debug, o.defs, o.preinc, o.ssp = nil, defs, {}, nil
		-- Hidden, as libgcc's are: a shared object uses its own
		-- copy and offers none of it.
		o.opt, o.visibility, o.pic = 1, "hidden", true
		-- The Lua runtime goes into the program it is linked with,
		-- and is position independent only when that is: a global
		-- reached through the table the loader fills costs a load on
		-- every use, and the runtime reaches its own all the time.
		if hosted then o.pic = luapic() end
		a = d.membuf()
		d.compile(f, a)
		for k, v in pairs(keep) do o[k] = v end
	else
		a = f
	end
	-- Built under a name of this run's own and moved into place,
	-- because several compilers share the directory and a
	-- half-written object is a wrong answer.
	local part = scrap(tmp(base(f) .. ".rt.o"))

	d.assemble(a, part)
	-- The install step's directory is on another filesystem than
	-- TMPDIR, where a rename cannot reach: copy it there, then move
	-- the copy into place.
	if not os.rename(part, dest) then
		local i = assert(io.open(part, "rb"))
		local bytes = i:read("a")

		i:close()
		local w = assert(io.open(dest .. ".part", "wb"))

		w:write(bytes)
		w:close()
		assert(os.rename(dest .. ".part", dest))
	end
end

local function isfile(p)
	local h = io.open(p, "rb")

	if h then h:close() end
	return h ~= nil
end

-- The name a runtime object has, built or installed.
local function rtname(f, var)
	return ("%s%s.o"):format(base(f),
		var ~= "" and ("-" .. var:gsub("[^%w=,]", "_")) or "")
end

-- Runtime objects for the sources in `list`, appended to `into`.  The
-- install step built the plain ones next to this file; anything else is
-- built once and kept in TMPDIR under a key of the compiler's own
-- sources, since building it again is most of what a small link costs.
local function rtbuild(list, into, hosted)
	local var = rtvariant()

	if hosted and not luapic() then
		var = var .. (var ~= "" and "," or "") .. "nopic"
	end
	local key, dir

	for _, f in ipairs(list) do
		local name = rtname(f, var)
		local pre = ("%s/rtobj/%s/%s"):format(root, o.target, name)

		if var == "" and isfile(pre) then
			into[#into + 1] = pre
			goto next
		end
		key = key or rtstamp(list)
		dir = dir or sys.getenv("TMPDIR") or "/tmp"
		do
		local keep = ("%s/mcc-rt-%s-%s-%s"):format(dir, o.target,
			key, name)

		if not isfile(keep) then
			rtcompile(f, keep, hosted)
			-- A new key means mcc changed, so the objects an
			-- older one built are dead.  Only those ten minutes
			-- old go: another tree may be in the middle of a
			-- link with its own, and a link reads them within
			-- seconds of choosing them.
			for _, g in ipairs(sys.glob(("%s/mcc-rt-%s-*-%s")
					:format(dir, o.target, name))) do
				if g.path ~= keep and
				   g.mtime < os.time() - 600 then
					os.remove(g.path)
				end
			end
		end
		into[#into + 1] = keep
		end
		::next::
	end
end

-- A program written in Lua: its runtime, and the maths library that
-- calls.
if d.lua and not o.shared and not o.nostdlib then
	local src = {}

	for _, f in ipairs(RTLUA) do src[#src + 1] = root .. "/" .. f end
	-- the coroutine switch, where the machine has one of its own
	if o.target == "amd64" then
		src[#src + 1] = root .. "/rt/lua/coswitch-amd64.s"
	end
	rtbuild(src, objs, true)
	o.libs[#o.libs + 1] = "m"
end

-- --mcc-runtime-to: every runtime source this target links, built into
-- DIR/<target>, and nothing else done.
if o.rtinto then
	local list = {}

	for _, f in ipairs(RTMATH) do list[#list + 1] = f end
	for _, f in ipairs(RTIO) do list[#list + 1] = f end
	if CRT[o.target] then list[#list + 1] = CRT[o.target] end
	if o.target == "amd64" then list[#list + 1] = "rt/openbsd-amd64.s" end
	local dir = o.rtinto .. "/" .. o.target

	os.execute("mkdir -p '" .. dir:gsub("'", "'\\''") .. "'")
	-- A source this target cannot build is left out, and a link that
	-- needs it builds it on demand and fails there as it would have.
	local bad = false

	for _, f in ipairs(list) do
		local ok, err = pcall(rtcompile, root .. "/" .. f,
			dir .. "/" .. rtname(f, ""))

		if not ok then
			io.stderr:write(prog .. ": " .. tostring(err) .. "\n")
			bad = true
		end
	end
	cleanup()
	sys.exit(bad and 1 or 0)
end

-- Linking against a real system: the objects are ELF, so the system's
-- own driver knows where its startup files and libraries are and this
-- one does not have to.  That is how a new compiler is brought up.
if o.syslink then
	local cmd = {sys.getenv("MCC_SYSLD") or "cc"}

	if o.syslink ~= "cc" then
		cmd[#cmd + 1] = "-fuse-ld=" .. o.syslink
	end
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

local elf = require "mcc.elf"
local ld = require "mcc.ld"
if o.trace then ld.trace = function(s) io.write(s, "\n") end end
-- lld's --why-extract: each archive member taken, who asked, for what.
if o.why then
	local f = o.why == "-" and io.stdout or
		assert(io.open(o.why, "w"))

	f:write("reference\textracted\tsymbol\n")
	ld.why = function(by, member, name)
		f:write(by, "\t", member, "\t", name, "\n")
		f:flush()
	end
end
local so = require "mcc.so"

-- `-r`: the objects on the command line become one, and nothing else
-- goes in: no start-up file, no library, no runtime.
if o.relocatable then
	local ok, why = pcall(ld.relocatable, objs, o.out or "a.out",
		d.objtarget(), nil, o.whole)

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
	if #names > 0 then require("mcc.elf").wrap(names) end
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

		require("mcc.ar").write(lib, built)
		objs[#objs + 1] = lib
	end
end

local function exists(p)
	local f = io.open(p, "rb")

	if f then f:close() end
	return f ~= nil
end

-- A GNU ld script standing in for a library: GROUP and INPUT
-- name the files it stands for, AS_NEEDED among them.  A plain
-- name is looked for beside the script and then along the library
-- path, `-lfoo` along the library path, and an absolute one in the
-- sysroot first.  Answers the shared objects and the archives, or
-- nil for a file that is not a script.
local function groupof(path, dirs, depth)
	local f = io.open(path, "rb")

	if not f then return nil end
	local head = f:read(4) or ""

	if head == "\127ELF" or head == "!<ar" then
		f:close()
		return nil
	end
	f:seek("set", 0)
	local text = (f:read("a") or ""):gsub("/%*.-%*/", " ")

	f:close()
	local shared, archives, any = {}, {}, false
	local here = path:gsub("/[^/]*$", "")

	local function find(name)
		local l = name:match("^%-l(.+)$")

		if l then
			for _, d in ipairs(dirs) do
				for _, x in ipairs{".so", ".a"} do
					local at = d .. "/lib" .. l .. x

					if exists(at) and
					   elf.fits(at, o.target) then
						return at
					end
				end
			end
			return nil
		end
		if name:match("^/") then
			if o.sysroot ~= "" and
			   exists(o.sysroot .. name) then
				return o.sysroot .. name
			end
			return exists(name) and name or nil
		end
		if exists(here .. "/" .. name) then
			return here .. "/" .. name
		end
		for _, d in ipairs(dirs) do
			if exists(d .. "/" .. name) then
				return d .. "/" .. name
			end
		end
		return nil
	end
	for kw, body in text:gmatch("(%u+)%s*(%b())") do
		if kw == "GROUP" or kw == "INPUT" then
			any = true
			for name in body:gsub("AS_NEEDED", " ")
			    :gmatch("[^%s(),]+") do
				local at = find(name)

				if not at then
					die(("cannot find %s, which " ..
					     "%s names"):format(name, path))
				end
				local sub = (depth or 0) < 4 and
					groupof(at, dirs, (depth or 0) + 1)

				if sub then
					for _, x in ipairs(sub.shared) do
						shared[#shared + 1] = x
					end
					for _, x in ipairs(sub.archives) do
						archives[#archives + 1] = x
					end
				elseif at:match("%.a$") then
					archives[#archives + 1] = at
				elseif not at:match("/ld%-[^/]*$") then
					-- glibc's script names the
					-- loader AS_NEEDED; it is
					-- there already.
					shared[#shared + 1] = at
				end
			end
		end
	end
	if not any then return nil end
	return {shared = shared, archives = archives}
end

-- the pieces a program needs that no source named
if not o.nostdlib then
	local extra = {}

	if o.dynamic then
		-- The system's own startup files: this program is run by
		-- the system's loader and calls the system's library.
		for _, f in ipairs(H.CRTSET[o.os] or H.CRTSET.linux) do
			local p = H.crtpath(o, f)

			if p then objs[#objs + 1] = p end
		end
	elseif o.hostedstatic then
		-- The system's start-up files and its libc.a, as cc -static
		-- links them: a program that calls pledge or opendev needs
		-- the real library, not this compiler's small runtime.
		local set = H.STATICCRT[o.os]

		if o.staticpie then set = H.STATICPIECRT[o.os] end

		for k = #set[1], 1, -1 do
			table.insert(objs, 1, H.crtpath(o, set[1][k]))
		end
		local dirs = {}

		for _, d in ipairs(o.libdirs) do dirs[#dirs + 1] = d end
		for _, d in ipairs{"/usr/lib64", "/lib64", "/usr/lib",
				   "/usr/lib/x86_64-linux-gnu"} do
			dirs[#dirs + 1] = o.sysroot .. d
		end
		local libs = {}

		for _, l in ipairs(o.libs) do libs[#libs + 1] = l end
		libs[#libs + 1] = "c"
		-- OpenBSD's libc.a calls into compiler_rt, which its cc
		-- adds too: __cpu_features2 lives there.
		if o.os == "openbsd" then libs[#libs + 1] = "compiler_rt" end
		-- glibc's libc.a calls libgcc for its unwinder and its
		-- binary128 compares, which gcc -static adds.  It lives
		-- under the newest gcc's own directory.
		if o.os == "linux" then
			local best, bestv
			local triple = ({amd64 = "x86_64", arm64 = "aarch64",
				riscv64 = "riscv64", i386 = "i?86"})[o.target]
				or o.target

			for _, g in ipairs(sys.glob(o.sysroot ..
			    "/usr/lib/gcc/" .. triple .. "-*/*/libgcc.a")) do
				local v = tonumber(g.path:match("/(%d+)[^/]*/" ..
					"libgcc%.a$") or "") or -1

				if not bestv or v > bestv then
					best, bestv = g.path, v
				end
			end
			if best then
				dirs[#dirs + 1] = best:gsub("/libgcc%.a$", "")
				libs[#libs + 1] = "gcc"
				libs[#libs + 1] = "gcc_eh"
			end
		end
		for _, l in ipairs(libs) do
			local found

			for _, d in ipairs(dirs) do
				local at = d .. "/lib" .. l .. ".a"
				local f = io.open(at, "rb")

				if f then
					f:close()
					if elf.fits(at, o.target) then
						found = at
						break
					end
				end
			end
			if not found then error("no archive for -l" .. l, 0) end
			-- glibc's libm.a is a script naming the real
			-- archive and libmvec.a.
			local g = groupof(found, dirs)

			if g then
				for _, a in ipairs(g.archives) do
					objs[#objs + 1] = a
				end
			else
				objs[#objs + 1] = found
			end
		end
		for _, f in ipairs(set[2]) do objs[#objs + 1] = H.crtpath(o, f) end
		o.libs = {}
	elseif o.shared then
		-- crtbeginS.o goes first and crtendS.o last: each gives half
		-- of _init and _fini, and the halves have to meet.
		local set = o.target == H.host() and H.SHAREDCRT[o.os] or {}
		local first, last = set[1] and H.crtpath(o, set[1]),
			set[2] and H.crtpath(o, set[2])

		if first then table.insert(objs, 1, first) end
		if last then objs[#objs + 1] = last end
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
			local at = d .. "/lib" .. l .. ".a"
			local f = io.open(at, "rb")

			if f then
				f:close()
				a = elf.fits(at, o.target)
			end
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

			if f then
				f:close()
				if elf.fits(at, o.target) then
					found = at
					break
				end
			end
		end
		if not found then
			error("no archive for -l" .. l, 0)
		end
		objs[#objs + 1] = found
	end
end
local w = assert(io.open(out, "wb"))
local ok, err

-- The script -Ttext and its kin stand for: the sections in the usual
-- order, each where it was asked to start or straight after the last,
-- as GNU ld lays them out under -N.
if o.secat and o.script == "" then
	local at = o.secat
	local function sec(name, pats, addr)
		return ("\t%s %s: { %s }\n"):format(name,
			addr and (addr .. " ") or "", pats)
	end
	-- and the names GNU ld's own script gives the ends of each part
	local t = {"SECTIONS\n{\n",
		at.text and ("\t. = %s;\n"):format(at.text) or "",
		sec(".text", "*(.text .text.*)"),
		"\t_etext = .; etext = .;\n",
		sec(".rodata", "*(.rodata .rodata.*)"),
		sec(".data", "*(.data .data.*)", at.data),
		"\t_edata = .; edata = .; __bss_start = .;\n",
		sec(".bss", "*(.bss .bss.*) *(COMMON) . = ALIGN(" ..
			(o.target == "i386" and 4 or 8) .. ");", at.bss),
		"\t_end = .; end = .;\n",
		"}\n"}
	local path = scrap(tmp("sect.ld"))
	local f = assert(io.open(path, "w"))

	f:write(table.concat(t))
	f:close()
	o.script = path
end
-- Whether the output keeps the debug sections of its inputs: unless
-- told to strip, with or without -g, as GNU ld does.  A build often
-- compiles with -g and links without it.  -s drops the symbols too.
local keepdebug = not o.strip
local nosyms = o.strip == "all"

if o.script then
	-- The program says for itself what its image looks like.
	ok, err = pcall(ld.scriptlink, objs, w, {
		debug = keepdebug, archivedebug = o.archivedebug,
		whole = o.whole,
		target = o.target, script = o.script, entry = o.entry,
		shared = o.shared, versionscript = o.versionscript,
		symbolic = o.symbolic,
	})
elseif o.shared or o.dynamic or o.staticpie then
	-- A GNU ld script standing in for a library: take the archives
	-- it names, which the loader knows nothing about.
	-- The libraries asked for, by the name each answers to.
	local LIBDIR = {}

	for _, d in ipairs{"/usr/lib64", "/lib64", "/usr/lib", "/lib",
			   "/usr/lib/x86_64-linux-gnu"} do
		LIBDIR[#LIBDIR + 1] = o.sysroot .. d
	end
	local dirs = {}

	for _, d in ipairs(o.libdirs) do dirs[#dirs + 1] = d end
	for _, d in ipairs(LIBDIR) do dirs[#dirs + 1] = d end



	local need = {}
	-- Where each library really is, so the version each name in it
	-- answers to by default can be read from it.
	local libpaths = {}

	for _, l in ipairs(o.libs) do
		local nm, found

		for _, d in ipairs(dirs) do
			local at = d .. "/lib" .. l .. ".so"

			-- A library for another machine is passed over.
			if not elf.fits(at, o.target) or
			   not elf.fits(d .. "/lib" .. l .. ".a", o.target) then
				goto nextdir
			end
			-- The file under that name may be a script
			-- rather than a library: glibc keeps a few
			-- functions, atexit among them, in an archive
			-- beside the shared object and names both in a
			-- GROUP.  The loader cannot read that, so the
			-- archive is linked in here.
			local g = groupof(at, dirs)

			if g then
				for _, a in ipairs(g.archives) do
					objs[#objs + 1] = a
				end
				-- Every shared object it names is wanted;
				-- the first stands for the -l.
				for k, sh in ipairs(g.shared) do
					local n = elf.soname(sh) or
						sh:match("[^/]*$")

					if k == 1 then
						nm, found = n, sh
					else
						need[#need + 1] = n
						libpaths[#libpaths + 1] = sh
					end
				end
				if not nm and #g.archives > 0 then break end
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
			::nextdir::
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
	ok, err = pcall(so.link, ld.inputs(objs, o.whole), w, {
		debug = keepdebug, archivedebug = o.archivedebug,
		soname = o.shared and (o.soname or out:gsub(".*/", ""))
			or nil,
		interp = not (o.shared or o.staticpie) and
			(o.interp or H.interpof(o)) or nil,
		needed = o.needed,
		-- rcrt0.o names its entry __start only.
		entry = o.entry or (o.staticpie and "__start") or
			(not o.shared and "_start" or nil),
		libpaths = libpaths, osnote = o.os,
		rpath = o.rpath and table.concat(o.rpath, ":"),
		oldrpath = o.oldrpath, static = o.staticpie,
		versionscript = o.versionscript, nosyms = nosyms,
	})
else
	ok, err = pcall(ld.linkfiles, objs, w, {
		debug = keepdebug, archivedebug = o.archivedebug,
		nosyms = nosyms,
		whole = o.whole,
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
