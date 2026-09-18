-- Link what the assembler made into something to run.
--
-- One pass over the sections to give them addresses, one over the symbols,
-- one over the relocations.  There is no archive, no dynamic linking and no
-- section table in the output: a single program, laid out once.
--
-- Two shapes come out of it.  `ld.elf` writes a static ELF that Linux or an
-- emulator will run.  `ld.flat` writes the image and the list of words that
-- hold an address, which is what a loader that places the program somewhere
-- else has to fix up.

local buf = require "buf"
local obj = require "obj"
local ar  = require "ar"

local ld = {}

-- The order sections are placed in, and what may follow them.
local ORDER = {".reset", ".init", ".text", ".rodata", ".data", ".sdata",
	       ".bss"}

local function rank(name)
	for i, n in ipairs(ORDER) do
		if name == n then return i end
	end
	return #ORDER		-- anything unknown lands with the data
end

-- What a section may be done with, which decides the segment it lands
-- in.  A kernel that enforces W^X refuses a segment that is both.
local PERM = {[".reset"] = 5, [".init"] = 5, [".text"] = 5,
	      [".rodata"] = 4, [".note.openbsd.ident"] = 4}

local function perm(name)
	return PERM[name] or 6		-- anything else is data
end

ld.perm = perm

local function align(v, a)
	return ((v + a - 1) // a) * a
end

-- Give every section an address.  A symbol that is not global belongs to
-- its own unit, because two files may both call a label .L19.
-- `place` pins a section at an address of its own, which is how a vector
-- table lands where the hardware looks for it.
-- Give every section an address.  Nothing here looks at a symbol, so a
-- link can do this from the sizes alone.
function ld.place(units, base, place)
	local secs = {}
	place = place or {}
	for _, a in ipairs(units) do
		for _, s in ipairs(a.order) do
			s.unit = a
			secs[#secs + 1] = s
		end
	end
	table.sort(secs, function(x, y)
		return rank(x.name) < rank(y.name)
	end)
	local addr, pinned, was = base, {}, nil
	for _, s in ipairs(secs) do
		local at = place[s.name]
		if at then
			s.addr = align(pinned[s.name] or at,
				math.max(s.align, 1))
			pinned[s.name] = s.addr + s.size
		else
			-- A change of permission starts a new page: a
			-- segment covers whole pages, so two with
			-- different rights cannot share one.
			local p = perm(s.name)

			if was and p ~= was then addr = align(addr, 0x1000) end
			was = p
			addr = align(addr, math.max(s.align, 1))
			s.addr = addr
			addr = addr + s.size
		end
	end
	return secs, addr
end

-- Where the global symbols ended up, and the local ones of each unit.
function ld.symbols(units, secs, base, globals, keeplocal)
	globals = globals or {}
	for _, a in ipairs(units) do
		local addrs = {}
		for name, d in pairs(a.syms) do
			if d.sec then
				addrs[name] = d.sec.addr + d.off
				if d.global then
					if globals[name] then
						error("two definitions of " ..
							name)
					end
					globals[name] = addrs[name]
				end
			end
		end
		if keeplocal then a.addrs = addrs end
	end
	-- Code the system compiler made reaches its small data through gp,
	-- so the symbol it points at has to exist even though nothing here
	-- uses it.
	if not globals["__global_pointer$"] then
		local d
		for _, s in ipairs(secs) do
			if s.name == ".sdata" or s.name == ".data" or
			   s.name == ".sbss" or s.name == ".bss" then
				d = d or s.addr
			end
		end
		globals["__global_pointer$"] = (d or base) + 0x800
	end
	return globals
end

function ld.layout(units, base, place)
	local secs, addr = ld.place(units, base, place)
	return secs, ld.symbols(units, secs, base, nil, true), addr
end

local function word(bytes, off)
	local a, b, c, d = bytes:byte(off + 1, off + 4)
	return a | b << 8 | c << 16 | d << 24
end

local function bin(v, n)
	local b = {}
	for i = 0, n - 1 do b[i + 1] = string.char(v >> (8 * i) & 255) end
	return table.concat(b)
end

-- What one relocation puts in place of the bytes it covers: the value and
-- how many bytes of it.  `hi` carries a RISC-V auipc's distance to the low
-- half that pairs with it.
local function fill(bytes, r, target, here, hi)
	local k = r.kind
	if k == "abs64" then return bin(target, 8), 8, true end
	if k == "abs32" then return bin(target, 4), 4, true end
	local w = word(bytes, r.off)
	local d = target - here
	if k == "branch" then
		w = w & 0x01fff07f
		w = w | ((d >> 12) & 1) << 31
		w = w | ((d >> 5) & 0x3f) << 25
		w = w | ((d >> 1) & 0xf) << 8
		w = w | ((d >> 11) & 1) << 7
	elseif k == "jal" then
		w = w & 0x00000fff
		w = w | ((d >> 20) & 1) << 31
		w = w | ((d >> 1) & 0x3ff) << 21
		w = w | ((d >> 11) & 1) << 20
		w = w | ((d >> 12) & 0xff) << 12
	elseif k == "pc32" or k == "plt32" then
		-- amd64 reaches everything from the instruction after the
		-- field, which is what the addend already says
		return bin(d, 4), 4, false
	elseif k == "gotpcrel" then
		error("a static link has no global offset table")
	-- AArch64.  A page is twenty-one bits of the distance between the
	-- two pages; the offset that follows is the low twelve bits of the
	-- target itself, scaled by the width of the access.
	elseif k == "a64_adrp" then
		local page = (target >> 12) - (here >> 12)
		local w = word(bytes, r.off) & 0x9f00001f

		w = w | (page & 3) << 29 | ((page >> 2) & 0x7ffff) << 5
		return bin(w, 4), 4, false
	elseif k == "a64_add_lo12" then
		local w = word(bytes, r.off) & 0xffc003ff

		return bin(w | (target & 0xfff) << 10, 4), 4, false
	elseif k:match("^a64_ldst%d+_lo12$") then
		-- the width is the one in ldstNN, not the one in the a64
		-- that comes before it
		local size = tonumber(k:match("ldst(%d+)_")) // 8
		local w = word(bytes, r.off) & 0xffc003ff

		if target % size ~= 0 then
			error("misaligned access to " .. r.sym)
		end
		-- the low twelve bits of the address, and then scaled:
		-- scaling first would carry bits in from above the page
		return bin(w | ((target & 0xfff) // size) << 10, 4), 4, false
	elseif k == "a64_call26" or k == "a64_jump26" then
		local w = word(bytes, r.off) & 0xfc000000

		return bin(w | ((d >> 2) & 0x3ffffff), 4), 4, false
	elseif k == "a64_condbr19" then
		local w = word(bytes, r.off) & 0xff00001f

		return bin(w | ((d >> 2) & 0x7ffff) << 5, 4), 4, false
	elseif k == "xt_call" then
		-- CALLn counts words from its own address rounded down,
		-- and keeps its low six bits
		w = (w & 0x3f) | ((target - ((here & ~3) + 4)) >> 2 &
			0x3ffff) << 6
		return bin(w, 3), 3, false
	elseif k == "pcrel_hi20" then
		hi[r.off] = d
		w = w & 0x00000fff
		w = w | ((((d + 0x800) // 4096) & 0xfffff) << 12)
	elseif k == "pcrel_lo12_i" or k == "pcrel_lo12_jalr" then
		local p = hi[r.pair]
		if not p then error("a low half with no auipc") end
		w = (w & 0x000fffff) | (((p + 0x800) % 4096 - 0x800) &
			0xfff) << 20
	else
		error("no relocation " .. k)
	end
	return bin(w, 4), 4, false
end

-- Fill in every place in one section that needed an address, in one pass
-- over its bytes.  Splicing each one in turn would copy the whole section
-- once per relocation.
function ld.patch(s, bytes, relocs, lookup, absolute)
	if #relocs == 0 then return bytes end
	table.sort(relocs, function(x, y) return x.off < y.off end)
	local out, at, hi = buf.new(), 0, {}
	for _, r in ipairs(relocs) do
		local target = lookup(r.sym)
		if not target then
			error("undefined symbol " .. r.sym)
		end
		local text, n, abs = fill(bytes, r, target + r.addend,
			s.addr + r.off, hi)
		out:add(bytes:sub(at + 1, r.off))
		out:add(text)
		at = r.off + n
		if abs and absolute then
			absolute[#absolute + 1] = {s.addr + r.off, n}
		end
	end
	out:add(bytes:sub(at + 1))
	return out:text()
end

-- Fill in every place that needed an address.  The list of absolute ones
-- comes back, because a loader that moves the program has to add its base
-- to each.
function ld.relocate(secs, globals)
	local absolute = {}
	for _, s in ipairs(secs) do
		local own = s.unit and s.unit.addrs or {}
		s.bytes = ld.patch(s, s.bytes, s.relocs, function(n)
			return own[n] or globals[n]
		end, absolute)
	end
	return absolute
end

-- ELF ------------------------------------------------------------------

local EM = {riscv64 = 243, riscv32 = 243, amd64 = 62, xtensa = 94,
	    arm64 = 183}

local function u(v, n)
	local b = {}
	for i = 0, n - 1 do b[i + 1] = string.char(v >> (8 * i) & 255) end
	return table.concat(b)
end

-- Sections that sit near one another share a segment; a gap wider than a
-- page starts a new one, because filling it would put the whole hole in the
-- file.
function ld.segments(secs, base, detached)
	local live = {}
	for _, s in ipairs(secs) do
		if s.size > 0 then live[#live + 1] = s end
	end
	table.sort(live, function(x, y) return x.addr < y.addr end)
	local segs = {}
	local cur
	for _, s in ipairs(live) do
		local p = ld.perm(s.name)

		if cur and p == cur.perm and s.addr >= cur.addr and
		   s.addr - cur["end"] <= 0x1000 then
			cur[#cur + 1] = s
			cur["end"] = s.addr + s.size
		else
			cur = {s, addr = s.addr, perm = p,
			       ["end"] = s.addr + s.size}
			segs[#segs + 1] = cur
		end
	end
	-- A note has a program header of its own, which a kernel reads to
	-- learn what system the program is for.
	for _, s in ipairs(live) do
		if s.name:sub(1, 6) == ".note." then
			segs.note = s
			break
		end
	end
	-- The headers go in front of whichever segment holds the base, and
	-- that segment goes first in the file so that its offset is zero.
	-- A machine that starts at the base address instead wants them out
	-- of the way, in the part of the file no segment covers.
	for i, g in ipairs(segs) do
		if detached then break end
		if base >= g.addr - 0x1000 and base <= g["end"] then
			g.addr = base
			g.headers = true
			table.remove(segs, i)
			table.insert(segs, 1, g)
			break
		end
	end
	return segs
end

-- A static executable.  Nothing here needs a section table: the loader
-- reads the program headers.  `bytes` hands over one section at a time, so
-- that a link does not have to hold the whole image.
function ld.elf(w, secs, entry, base, endaddr, target, segs, detached, bytes,
		syscalls)
	local bits = (target == "riscv32" or target == "xtensa") and 32 or 64
	local ehsize = bits == 64 and 64 or 52
	local phsize = bits == 64 and 56 or 32
	segs = segs or ld.segments(secs, base, detached)
	local nph = #segs + (segs.note and 1 or 0) + (syscalls and 1 or 0)
	local start = ehsize + nph * phsize

	-- Where each segment's bytes go.  A loader maps a whole page, so a
	-- segment's offset in the file has to agree with its address to
	-- the page; the gap that makes is padding.
	local at = start
	for i, g in ipairs(segs) do
		local hdr = g.headers and start or 0
		local last = g.addr + hdr
		for _, s in ipairs(g) do
			if not s.bss then last = s.addr + s.size end
		end
		if not g.headers then
			at = at + ((g.addr - at) % 0x1000)
		end
		g.offset = g.headers and 0 or at
		g.filesz = last - g.addr
		g.memsz = g["end"] - g.addr
		-- The last segment holds whatever the program asked for
		-- beyond what is in the file, which is its bss.
		if i == #segs then
			g.memsz = math.max(g.memsz, endaddr - g.addr)
		end
		at = at + (last - g.addr - hdr)
	end
	local sysoff = at

	w:write("\127ELF")
	w:write(string.char(bits == 64 and 2 or 1, 1, 1, 0))
	w:write(string.rep("\0", 8))
	w:write(u(2, 2))			-- ET_EXEC
	w:write(u(EM[target] or 243, 2))
	w:write(u(1, 4))
	if bits == 64 then
		w:write(u(entry, 8))
		w:write(u(ehsize, 8))		-- phoff
		w:write(u(0, 8))		-- shoff
	else
		w:write(u(entry, 4))
		w:write(u(ehsize, 4))
		w:write(u(0, 4))
	end
	w:write(u(target == "riscv64" and 4 or 0, 4))	-- e_flags
	w:write(u(ehsize, 2))
	w:write(u(phsize, 2))
	w:write(u(nph, 2))
	w:write(u(bits == 64 and 64 or 40, 2))
	w:write(u(0, 2))
	w:write(u(0, 2))

	for _, g in ipairs(segs) do
		if bits == 64 then
			w:write(u(1, 4))	-- PT_LOAD
			w:write(u(g.perm or 7, 4))
			w:write(u(g.offset, 8))
			w:write(u(g.addr, 8))	-- vaddr
			w:write(u(g.addr, 8))	-- paddr
			w:write(u(g.filesz, 8))
			w:write(u(g.memsz, 8))
			w:write(u(0x1000, 8))
		else
			w:write(u(1, 4))
			w:write(u(g.offset, 4))
			w:write(u(g.addr, 4))
			w:write(u(g.addr, 4))
			w:write(u(g.filesz, 4))
			w:write(u(g.memsz, 4))
			w:write(u(g.perm or 7, 4))
			w:write(u(0x1000, 4))
		end
	end
	-- Where every system call instruction stands, which OpenBSD asks
	-- for and will not run a program without.  The table goes after
	-- everything else in the file and is not mapped.
	if syscalls then
		table.sort(syscalls, function(x, y)
			return x.addr < y.addr
		end)
		local t = {}

		for i, c in ipairs(syscalls) do
			t[i] = u(c.addr, 4) .. u(c.sysno, 4)
		end
		t = table.concat(t)
		segs.systab = t
		segs.sysoff = sysoff
		if bits == 64 then
			w:write(u(0x65a3dbe9, 4))	-- PT_OPENBSD_SYSCALLS
			w:write(u(4, 4))		-- read only
			w:write(u(sysoff, 8))
			w:write(u(0, 8))
			w:write(u(0, 8))
			w:write(u(#t, 8))
			w:write(u(#t, 8))
			w:write(u(4, 8))
		else
			w:write(u(0x65a3dbe9, 4))
			w:write(u(sysoff, 4))
			w:write(u(0, 4))
			w:write(u(0, 4))
			w:write(u(#t, 4))
			w:write(u(#t, 4))
			w:write(u(4, 4))
			w:write(u(4, 4))
		end
	end
	-- The note, whose bytes are inside a segment already; this header
	-- only says where they are.
	if segs.note then
		local n = segs.note
		local off

		for _, g in ipairs(segs) do
			if n.addr >= g.addr and n.addr < g["end"] then
				off = g.offset + (n.addr - g.addr) +
					(g.headers and start or 0)
			end
		end
		if bits == 64 then
			w:write(u(4, 4))	-- PT_NOTE
			w:write(u(4, 4))	-- read only
			w:write(u(off or 0, 8))
			w:write(u(n.addr, 8))
			w:write(u(n.addr, 8))
			w:write(u(n.size, 8))
			w:write(u(n.size, 8))
			w:write(u(4, 8))
		else
			w:write(u(4, 4))
			w:write(u(off or 0, 4))
			w:write(u(n.addr, 4))
			w:write(u(n.addr, 4))
			w:write(u(n.size, 4))
			w:write(u(n.size, 4))
			w:write(u(4, 4))
			w:write(u(4, 4))
		end
	end

	local wrote = start
	for _, g in ipairs(segs) do
		local here = g.addr + (g.headers and start or 0)

		-- the padding that puts this segment at its own offset
		if not g.headers and g.offset > wrote then
			w:write(string.rep("\0", g.offset - wrote))
			wrote = g.offset
		end
		for _, s in ipairs(g) do
			if not s.bss then
				if s.addr < here then
					error("sections overlap")
				end
				w:write(string.rep("\0", s.addr - here))
				w:write(bytes(s))
				wrote = wrote + (s.addr - here) + s.size
				here = s.addr + s.size
			end
		end
	end
	if segs.systab then
		if segs.sysoff > wrote then
			w:write(string.rep("\0", segs.sysoff - wrote))
		elseif segs.sysoff < wrote then
			error("the system call table is misplaced")
		end
		w:write(segs.systab)
	end
end

-- Link one or more assembled units into a static executable.
function ld.link(units, opt)
	opt = opt or {}
	local base = opt.base or 0x10000
	local target = opt.target or "riscv64"
	local bits = (target == "riscv32" or target == "xtensa") and 32 or 64
	local ehsize, phsize = bits == 64 and 64 or 52, bits == 64 and 56 or 32
	local detached = opt.detached
	-- The header space depends on how many segments there are, and that
	-- depends on where the sections landed.  Lay out once to count them.
	local secs, globals, endaddr, segs
	local n = 1
	repeat
		local start = ehsize + n * phsize
		secs, globals, endaddr = ld.layout(units,
			detached and base or (base + start), opt.place)
		segs = ld.segments(secs, base, detached)
		local again = #segs + (segs.note and 1 or 0) ~= n
		n = #segs + (segs.note and 1 or 0)
	until not again
	for k, v in pairs(opt.symbols or {}) do
		if not globals[k] then globals[k] = v end
	end
	local absolute = ld.relocate(secs, globals)
	local entry = globals[opt.entry or "_start"]
	if not entry then error("no entry symbol") end
	local w = buf.new()
	ld.elf(w, secs, entry, base, endaddr, target, segs, detached,
		function(s) return s.bytes end)
	return w:text(), globals, absolute
end

-- What a set of named files really contributes.  An object contributes
-- itself; an archive contributes only the members that something still
-- needs, and taking one member may make another needed, so the pass
-- repeats until nothing more is pulled in.
function ld.inputs(paths)
	local ins, arcs = {}, {}
	local defined, wanted = {}, {}

	local function take(path, at0)
		local h = obj.header(path, false, at0)

		ins[#ins + 1] = {path = path, at0 = at0}
		for name, d in pairs(h.syms) do
			if d.global then defined[name] = true end
		end
		for _, name in ipairs(h.symnames) do
			if not h.syms[name] then wanted[name] = true end
		end
	end

	for _, p in ipairs(paths) do
		local ms = ar.members(p)

		if ms then
			arcs[#arcs + 1] = {path = p, members = ms}
		else
			take(p, 0)
		end
	end
	local again = true
	while again do
		again = false
		for _, a in ipairs(arcs) do
			for _, m in ipairs(a.members) do
				if m.taken then goto next end
				local h = obj.header(a.path, false, m.off)

				for name, d in pairs(h.syms) do
					if d.global and wanted[name] and
					   not defined[name] then
						m.taken = true
						take(a.path, m.off)
						again = true
						break
					end
				end
				::next::
			end
		end
	end
	return ins
end

-- Link object files straight to an output file.  Only the headers are held
-- -- section sizes and the global symbols -- and one section at a time is
-- read, relocated and written, so what this needs does not grow with the
-- size of the program.
function ld.linkfiles(paths, w, opt)
	opt = opt or {}
	local base = opt.base or 0x10000
	local target = opt.target or "riscv64"
	local bits = (target == "riscv32" or target == "xtensa") and 32 or 64
	local ehsize, phsize = bits == 64 and 64 or 52, bits == 64 and 56 or 32
	local detached = opt.detached

	local ins = ld.inputs(paths)
	-- The sizes alone decide where everything goes, so the first look at
	-- each object skips its symbols.
	local units = {}
	for i, f in ipairs(ins) do
		units[i] = obj.header(f.path, true, f.at0)
	end

	local extra = opt.pinsyscalls and 1 or 0
	local secs, endaddr, segs
	local n = 1
	repeat
		local start = ehsize + n * phsize
		secs, endaddr = ld.place(units,
			detached and base or (base + start), opt.place)
		segs = ld.segments(secs, base, detached)
		local want = #segs + (segs.note and 1 or 0) + extra
		local again = want ~= n
		n = want
	until not again

	-- Then the global symbols, one object at a time: what a unit says
	-- about its own labels is read again when its bytes go out.
	local globals = {}
	for i, u in ipairs(units) do
		local h = obj.header(ins[i].path, false, ins[i].at0)
		for k, d in ipairs(h.order) do d.addr = u.order[k].addr end
		ld.symbols({h}, secs, base, globals, false)
	end
	for k, v in pairs(opt.symbols or {}) do
		if not globals[k] then globals[k] = v end
	end
	local entry = globals[opt.entry or "_start"]
	if not entry then error("no entry symbol") end

	-- The list of absolute words is for a loader that moves the program;
	-- a static executable has no use for it and it is as long as the
	-- relocations are.
	-- What a unit knows about its own labels is only needed while its
	-- bytes are going out, so drop it and read it back a unit at a time.
	for i, u in ipairs(units) do
		u.path, u.at0 = ins[i].path, ins[i].at0
	end

	-- The list of absolute words is for a loader that moves the program;
	-- a static executable has no use for it and it is as long as the
	-- relocations are.
	local absolute = opt.absolute and {} or nil
	-- Every system call instruction, at the address it ended up at.
	local syscalls
	if opt.pinsyscalls then
		syscalls = {}
		-- every system call instruction, at the address it got
		for _, u in ipairs(units) do
			local h = obj.header(u.path, true, u.at0)

			for k, x in ipairs(h.order) do
				for _, c in ipairs(obj.syscalls(h, x)) do
					syscalls[#syscalls + 1] = {
						addr = u.order[k].addr + c.off,
						sysno = c.sysno}
				end
			end
		end
	end
	local at, own, names = nil, nil, nil
	ld.elf(w, secs, entry, base, endaddr, target, segs, detached,
		function(s)
			local u = s.unit
			if at ~= u then
				local h = obj.header(u.path, false, u.at0)
				own = {}
				for name, d in pairs(h.syms) do
					for i, x in ipairs(h.order) do
						if x == d.sec then
							own[name] =
							    u.order[i].addr +
							    d.off
						end
					end
				end
				names, at = h.symnames, u
			end
			local bytes, relocs = obj.section(u, s, names)
			return ld.patch(s, bytes, relocs, function(name)
				return own[name] or globals[name]
			end, absolute)
		end, syscalls)
	return globals, absolute
end

return ld
