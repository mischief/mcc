-- SPDX-License-Identifier: ISC
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

local buf = require "mcc.buf"
local elf = require "mcc.elf"
local ar  = require "mcc.ar"

-- Two object formats go in: this compiler's own, and ELF.  Which one a
-- file is is a question about its first four bytes, and nothing below
-- here asks anything else about it.
local function rd(path, at0)
	return elf
end

local function header(path, light, at0)
	return rd(path, at0).header(path, light, at0)
end

local function section(u, s, names)
	return (u.elf and elf or obj).section(u, s, names)
end

local function syscallsof(u, s)
	return (u.elf and elf or obj).syscalls(u, s)
end

local ld = {}

-- The order sections are placed in, and what may follow them.
local ORDER = {".reset", ".init", ".text", ".rodata", ".tdata", ".tbss",
	       ".data", ".sdata", ".bss"}

-- A linker puts the input sections together by the output section
-- they belong to, and the name says which: `.text.unlikely` is text
-- and `.rodata.str1.1` is read-only data.  Without that the sections
-- keep input order, permissions alternate all the way down the image,
-- and every section becomes a segment of its own.
local families = {}

local function family(name)
	local f = families[name]

	if f then return f end
	f = name
	for _, n in ipairs(ORDER) do
		if name == n or name:sub(1, #n + 1) == n .. "." then
			f = n
			break
		end
	end
	families[name] = f
	return f
end

-- OpenBSD's data that the kernel fills with random bytes, or leaves
-- writable after the rest is made immutable.
local function openbsddata(name)
	return name:match("^%.openbsd%.randomdata") or
		name:match("^%.openbsd%.mutable")
end

local function rank(name)
	local f = openbsddata(name) and ".data" or family(name)

	for i, n in ipairs(ORDER) do
		if f == n then return i end
	end
	return #ORDER		-- anything unknown lands with the data
end

-- What a section may be done with, which decides the segment it lands
-- in.  A kernel that enforces W^X refuses a segment that is both.
local PERM = {[".reset"] = 5, [".init"] = 5, [".text"] = 5,
	      [".rodata"] = 4, [".note.openbsd.ident"] = 4}

-- A section says for itself what may be done with it; the name is
-- only a fallback for one that did not.
local function perm(name, sec)
	if sec and sec.perm then return sec.perm end
	return PERM[family(name)] or 6	-- anything else is data
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
-- Where a section goes among others of its kind.  A constructor with a
-- priority is in `.init_array.N`, and those run lowest first and before
-- the ones with none, as GNU ld lays them out: libc's own is
-- `.init_array.50`.  Anything else keeps its name as its order.
function ld.arraykey(name)
	local base, n = name:match("^(%.%a+_array)%.(%d+)$")

	if base then return base, tonumber(n) end
	if name:match("^%.%a+_array$") then return name, math.huge end
	return name, 0
end

local function byname(x, y)
	local xb, xn = ld.arraykey(x.name)
	local yb, yn = ld.arraykey(y.name)

	if xb ~= yb then return xb < yb end
	if xn ~= yn then return xn < yn end
	return x.name < y.name
end

-- The bounds of the arrays of functions run before main and after it,
-- which a static program's start-up code walks itself.
function ld.arraybounds(secs, globals, empty)
	local span = {}

	for _, s in ipairs(secs) do
		local base = s.name:match("^(%.%a+_array)")

		if base and s.addr then
			local e = span[base] or {lo = s.addr, hi = s.addr}

			span[base] = e
			if s.addr < e.lo then e.lo = s.addr end
			if s.addr + s.size > e.hi then e.hi = s.addr + s.size end
		end
	end
	for _, base in ipairs{".init_array", ".fini_array", ".preinit_array"} do
		local e = span[base] or {lo = empty, hi = empty}
		local nm = "__" .. base:sub(2)

		if globals[nm .. "_start"] == nil then
			globals[nm .. "_start"] = e.lo
		end
		if globals[nm .. "_end"] == nil then
			globals[nm .. "_end"] = e.hi
		end
	end
end

-- The names GNU ld defines for where the image starts and ends, which a
-- C library reads: glibc finds its own program headers through
-- __ehdr_start, and the ends of text, data and bss have old names too.
ld.MARKS = {"__executable_start", "_etext", "etext", "__etext", "_edata",
	    "edata", "__bss_start", "_end", "end"}

function ld.marks(secs, globals, base, endaddr, headers)
	local etext, edata = base, base

	for _, s in ipairs(secs) do
		if s.addr and s.size > 0 then
			if perm(s.name, s) == 5 then
				etext = math.max(etext, s.addr + s.size)
			end
			if not s.bss and family(s.name) ~= ".tbss" then
				edata = math.max(edata, s.addr + s.size)
			end
		end
	end
	local marks = {__executable_start = base, _etext = etext,
		       etext = etext, __etext = etext, _edata = edata,
		       edata = edata, __bss_start = edata, _end = endaddr,
		       ["end"] = endaddr,
		       __ehdr_start = headers and base or nil}

	for k, v in pairs(marks) do
		if globals[k] == nil then globals[k] = v end
	end
end

function ld.place(units, base, place)
	local secs = {}
	place = place or {}
	for _, a in ipairs(units) do
		for _, s in ipairs(a.order) do
			s.unit = a
			secs[#secs + 1] = s
			s.seq = #secs
		end
	end
	-- Within one output section the input order is kept: an array of
	-- pointers is walked from one end to the other, and the file that
	-- starts it and the file that ends it are not the same file.
	table.sort(secs, function(x, y)
		local a, b = rank(x.name), rank(y.name)

		if a ~= b then return a < b end
		if x.name ~= y.name then return byname(x, y) end
		return x.seq < y.seq
	end)
	local addr, pinned, was, inmut = base, {}, nil, false
	-- .tbss is the zero half of each thread's block.  The program
	-- itself never reads it, so it takes addresses after .tdata but
	-- no room: the data that follows starts where .tdata ends.
	local tbss
	for _, s in ipairs(secs) do
		local at = place[s.name]
		if family(s.name) == ".tbss" and not at then
			tbss = align(tbss or addr, math.max(s.align, 1))
			s.addr = tbss
			tbss = tbss + s.size
		elseif at then
			s.addr = align(pinned[s.name] or at,
				math.max(s.align, 1))
			pinned[s.name] = s.addr + s.size
		else
			-- A change of permission starts a new page: a
			-- segment covers whole pages, so two with
			-- different rights cannot share one.
			local p = perm(s.name, s)
			-- The mutable data takes whole pages of its own,
			-- because the kernel makes every other page of a
			-- static program immutable.
			local mut = s.name:match("^%.openbsd%.mutable") ~= nil

			if was and p ~= was then addr = align(addr, 0x1000) end
			if mut ~= inmut then addr = align(addr, 0x1000) end
			was, inmut = p, mut
			addr = align(addr, math.max(s.align, 1))
			s.addr = addr
			addr = addr + s.size
		end
	end
	if inmut then addr = align(addr, 0x1000) end
	return secs, addr
end

-- Where the global symbols ended up, and the local ones of each unit.
-- `weakdef` says which of the names already found came from a weak
-- definition, which a strong one may still replace.  The caller keeps
-- it because the units arrive one call at a time.
function ld.symbols(units, secs, base, globals, keeplocal, weakdef)
	globals = globals or {}
	weakdef = weakdef or {}
	for _, a in ipairs(units) do
		local addrs = {}
		for name, d in pairs(a.syms) do
			-- A section a linker script did not place is not
			-- in the image, and neither is what it held.
			if d.sec and d.sec.addr then
				addrs[name] = d.sec.addr + d.off
				if d.global then
					if globals[name] and
					   not weakdef[name] and not d.weak
					then
						error("two definitions of " ..
							name)
					end
					-- Of several commons the largest
					-- stands; weakdef holds its size.
					local was = weakdef[name]

					if globals[name] == nil or
					   (was and not d.weak) or
					   (d.common and math.type(was) ==
					    "integer" and d.size > was) then
						globals[name] = addrs[name]
						weakdef[name] = d.common and
							d.size or d.weak or false
					end
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

-- The low n bytes of v, least significant first.
local PACK = {[1] = "<I1", [2] = "<I2", [3] = "<I3", [4] = "<I4",
	      [8] = "<i8"}
local MASK = {[1] = 0xff, [2] = 0xffff, [3] = 0xffffff,
	      [4] = 0xffffffff}

-- A branch or call reaches a signed field of `bits` bits of bytes.  One
-- that does not reach is refused: the bits would land somewhere else.
local function reach(d, bits, sym)
	local half = 1 << (bits - 1)

	if d < -half or d >= half then
		error(("a call or branch to %s is %d bytes away, past what "
			.. "it reaches"):format(sym or "?", d))
	end
end

local function bin(v, n)
	if n == 8 then return string.pack("<i8", v) end
	return string.pack(PACK[n], v & MASK[n])
end

-- What one relocation puts in place of the bytes it covers: the value and
-- how many bytes of it.  `hi` carries a RISC-V auipc's distance to the low
-- half that pairs with it.
local function fill(bytes, r, target, here, hi)
	local k = r.kind
	if k == "abs64" then return bin(target, 8), 8, true end
	-- Offsets into the thread's block, which the lookup has already
	-- made relative.  Nothing moves them.
	if k == "tpoff32" or k == "dtpoff32" then return bin(target, 4), 4, false end
	if k == "tpoff64" or k == "dtpoff64" then return bin(target, 8), 8, false end
	if k == "abs32" or k == "abs32s" then
		return bin(target, 4), 4, true
	end
	-- The narrow fields sixteen-bit boot code writes.  Nothing can
	-- move them, so they are not on the list of absolute words.
	if k == "abs16" then return bin(target, 2), 2, false end
	if k == "abs8" then return bin(target, 1), 1, false end
	if k == "pc16" then return bin(target - here, 2), 2, false end
	if k == "pc8" then return bin(target - here, 1), 1, false end
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
	elseif k == "gotpcrelx" or k == "rexgotpcrelx" then
		-- Relaxed to an instruction that needs no table; what
		-- is left is the distance, as for any other of those.
		return bin(d, 4), 4, false
	-- AArch64.  A page is twenty-one bits of the distance between the
	-- two pages; the offset that follows is the low twelve bits of the
	-- target itself, scaled by the width of the access.
	elseif k == "a64_adrp" or k == "a64_got_page" then
		-- A static link has no table: the page of the GOT slot is
		-- the page of the name itself, and the load beside it
		-- becomes an add, as GNU ld relaxes the pair.
		local page = (target >> 12) - (here >> 12)
		local w = word(bytes, r.off) & 0x9f00001f

		w = w | (page & 3) << 29 | ((page >> 2) & 0x7ffff) << 5
		return bin(w, 4), 4, false
	elseif k == "a64_add_lo12" then
		local w = word(bytes, r.off) & 0xffc003ff

		return bin(w | (target & 0xfff) << 10, 4), 4, false
	elseif k == "a64_got_lo12" then
		-- `ldr xT, [xN, :got_lo12:sym]` becomes `add xT, xN,
		-- :lo12:sym`: the same registers, the address itself.
		local w = word(bytes, r.off)

		if w & 0xffc00000 ~= 0xf9400000 then
			error("cannot relax the GOT load of " .. r.sym, 0)
		end
		return bin(0x91000000 | (target & 0xfff) << 10 | (w & 0x3ff),
			4), 4, false
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

		reach(d, 28, r.sym)
		return bin(w | ((d >> 2) & 0x3ffffff), 4), 4, false
	elseif k == "a64_condbr19" then
		local w = word(bytes, r.off) & 0xff00001f

		reach(d, 21, r.sym)
		return bin(w | ((d >> 2) & 0x7ffff) << 5, 4), 4, false
	elseif k == "xt_call" then
		-- CALLn counts words from its own address rounded down,
		-- and keeps its low six bits
		local off = target - ((here & ~3) + 4)

		reach(off, 20, r.sym)
		w = (w & 0x3f) | (off >> 2 & 0x3ffff) << 6
		return bin(w, 3), 3, false
	elseif k == "pcrel_hi20" then
		-- Kept by where the auipc is, because the low half finds
		-- it by name: the ABI puts the label of the auipc in the
		-- second relocation rather than the symbol.
		hi[here] = d
		w = w & 0x00000fff
		w = w | ((((d + 0x800) // 4096) & 0xfffff) << 12)
	elseif k == "pcrel_lo12_i" or k == "pcrel_lo12_jalr" or
	       k == "pcrel_lo12_s" then
		local p = hi[target]

		if not p then error("a low half with no auipc") end
		local v = (p + 0x800) % 4096 - 0x800

		if k == "pcrel_lo12_s" then
			w = (w & 0x01fff07f) | (v >> 5 & 0x7f) << 25 |
				(v & 0x1f) << 7
		else
			w = (w & 0x000fffff) | (v & 0xfff) << 20
		end
	else
		error("no relocation " .. k)
	end
	return bin(w, 4), 4, false
end

-- Fill in every place in one section that needed an address, in one pass
-- over its bytes.  Splicing each one in turn would copy the whole section
-- once per relocation.
-- `weak` names the undefined references this unit marked weak.  C says
-- one of those stands for nothing rather than stopping the link, and
-- code that tests it for zero is the whole reason it is written that
-- way.
-- `mov sym@GOTPCREL(%rip), %reg` asks for the address out of a table.
-- A static link has no table, and does not need one: the same register
-- gets the same address from `lea sym(%rip), %reg`, which is the same
-- length and the same distance.  The relaxable spelling of the
-- relocation is what says the linker may do this.
-- The ALU operations a GOT load can stand in for, by opcode, and the
-- /digit of the immediate form each becomes.
local BINOP = {[0x03] = 0, [0x0b] = 1, [0x13] = 2, [0x1b] = 3, [0x23] = 4,
	       [0x2b] = 5, [0x33] = 6, [0x3b] = 7, [0x85] = 0}

local function relax(bytes, relocs)
	local out, at = nil, 0

	for _, r in ipairs(relocs) do
		if r.kind == "gotpcrelx" or r.kind == "rexgotpcrelx" then
			-- REX OPCODE MODRM DISP32, and the relocation
			-- names the last of those.
			local op = bytes:byte(r.off - 1)
			local modrm = bytes:byte(r.off)

			out = out or buf.new()
			if op == 0x8b then
				out:add(bytes:sub(at + 1, r.off - 2))
				out:add("\141")		-- lea
				at = r.off - 1
			elseif op == 0xff and modrm == 0x15 then
				-- `call *sym@GOTPCREL(%rip)` is
				-- `addr32 call sym`, as GNU ld writes it
				out:add(bytes:sub(at + 1, r.off - 2))
				out:add("\103\232")		-- 67 e8
				at = r.off
			elseif op == 0xff and modrm == 0x25 then
				-- `jmp *sym@GOTPCREL(%rip)` is `nop; jmp sym`
				out:add(bytes:sub(at + 1, r.off - 2))
				out:add("\144\233")		-- 90 e9
				at = r.off
			elseif BINOP[op] and modrm & 0xc7 == 0x05 then
				-- `cmp sym@GOTPCREL(%rip), %reg` and the
				-- rest are `cmp $sym, %reg`: the register
				-- moves from the reg field to rm, and its
				-- REX bit with it.  glibc's libc.a has these.
				local rex = bytes:byte(r.off - 2)
				local reg = modrm >> 3 & 7
				local ops = string.char(op == 0x85 and 0xf7 or
					0x81, 0xc0 | BINOP[op] << 3 | reg)

				if rex and rex & 0xf0 == 0x40 then
					out:add(bytes:sub(at + 1, r.off - 3))
					ops = string.char(rex & ~4 |
						(rex >> 2 & 1)) .. ops
				else
					out:add(bytes:sub(at + 1, r.off - 2))
				end
				out:add(ops)
				at = r.off
				r.kind = "abs32s"
				r.addend = 0
			else
				error(("cannot relax the reference to %s: " ..
				       "opcode %02x"):format(r.sym, op or 0))
			end
		end
	end
	if not out then return bytes end
	out:add(bytes:sub(at + 1))
	return out:text()
end

-- The debug sections of every unit, joined by name in the order met.
-- Their relocations are filled in here and not passed on: each names a
-- place in the image or a place in another debug section.  `find(u,
-- name)` answers the address of a name, or nil when the image does not
-- hold it, and then the place reads zero.
-- Where the thread-local block starts, which a debugger's offsets into it
-- count from.
function ld.tlslo(secs)
	local lo

	for _, s in ipairs(secs) do
		if (s.name == ".tdata" or s.name == ".tbss") and s.addr and
		   (not lo or s.addr < lo) then
			lo = s.addr
		end
	end
	return lo or 0
end

function ld.debug(units, find, tlslo)
	local out, byname, groups = {}, {}, {}

	-- The bytes come first: a compressed section says its size only
	-- once it is inflated.  A unit with a part that would not inflate
	-- keeps none, since one part names places in the others.  A
	-- section of a group another unit already gave is not read: a
	-- place in it means the same place in the first copy.
	for _, u in ipairs(units) do
		local got, bad = {}, false

		for i, e in ipairs(u.debug or {}) do
			local first = e.group and groups[e.group .. e.name]

			if first then
				e.same = first
			else
				got[i] = {section(u, e, u.symnames)}
				if e.dropped then bad = true end
			end
		end
		for i, e in ipairs(bad and {} or u.debug or {}) do
			if e.same then goto next end
			e.bytes, e.rel = got[i][1], got[i][2]
			if e.group then groups[e.group .. e.name] = e end

			local o = byname[e.name]

			if not o then
				o = {name = e.name, size = 0, align = 1,
				     parts = {}, strings = e.strings}
				byname[e.name] = o
				out[#out + 1] = o
			end
			o.size = align(o.size, e.align)
			e.outoff = o.size
			o.size = o.size + e.size
			if e.align > o.align then o.align = e.align end
			o.parts[#o.parts + 1] = e
			::next::
		end
	end
	for _, o in ipairs(out) do
		local b, at = buf.new(), 0

		for _, e in ipairs(o.parts) do
			local u = e.unit
			local bytes = ld.patch({addr = e.outoff}, e.bytes, e.rel,
				function(n, r)
					local d = u.dsyms and u.dsyms[n]

					if d then
						return (d.sec.same or d.sec).outoff
							+ d.off
					end
					local v = find(u, n) or 0

					if r.kind:match("^dtpoff") then
						v = v - (tlslo or 0)
					end
					return v
				end)

			b:add(string.rep("\0", e.outoff - at))
			b:add(bytes)
			at = e.outoff + #bytes
			e.bytes, e.rel = nil, nil
		end
		o.bytes = b:text()
	end
	return out
end

-- The units whose debug sections a link keeps.  An archive member whose
-- debug sections are compressed keeps none unless `opt.archivedebug`
-- says so: inflating a whole C library costs more than it is worth.
function ld.keepdebug(units, opt)
	local out = {}

	for _, un in ipairs(opt.debug and units or {}) do
		local squashed = false

		for _, e in ipairs(un.debug or {}) do
			if e.squashed then squashed = true end
		end
		if un.debug and (opt.archivedebug or not un.member or
		   not squashed) then
			out[#out + 1] = un
		end
	end
	return out
end

function ld.debugof(units, globals, opt, drop, tlslo)
	local full = {}

	for _, un in ipairs(ld.keepdebug(units, opt)) do
		local h = header(un.path, false, un.at0)

		h.addrs, h.glob = {}, {}
		for name, d in pairs(h.syms) do
			if d.global then h.glob[name] = true end
			for i, x in ipairs(h.order) do
				if x == d.sec and un.order[i].addr then
					h.addrs[name] =
						un.order[i].addr + d.off
				end
			end
		end
		local keep = {}

		for _, e in ipairs(h.debug) do
			if not (drop and drop(e.name)) then
				keep[#keep + 1] = e
			end
		end
		h.debug = keep
		full[#full + 1] = h
	end
	return ld.debug(full, function(h, name)
		if h.glob[name] and globals[name] then
			return globals[name]
		end
		return h.addrs[name] or globals[name]
	end, tlslo)
end

-- One place, filled in.  The shared-object linker uses this too: the
-- arithmetic is the machine's, not the output shape's.
ld.fill = fill

function ld.patch(s, bytes, relocs, lookup, absolute, weak)
	if #relocs == 0 then return bytes end
	table.sort(relocs, function(x, y) return x.off < y.off end)
	bytes = relax(bytes, relocs)
	-- The pieces go into a plain list joined once at the end: a
	-- section can hold thousands of relocations.
	local out, at, hi = {}, 0, {}
	for _, r in ipairs(relocs) do
		-- A lookup that gives a table slot says how to fill the
		-- place as well: the distance to the slot.
		local target, kind = lookup(r.sym, r)
		if not target and weak and weak[r.sym] then target = 0 end
		if not target then
			error("undefined symbol " .. r.sym)
		end
		local text, n, abs = fill(bytes,
			kind and {kind = kind, off = r.off} or r,
			target + r.addend,
			s.addr + r.off, hi)
		out[#out + 1] = bytes:sub(at + 1, r.off)
		out[#out + 1] = text
		at = r.off + n
		if abs and absolute then
			absolute[#absolute + 1] = {s.addr + r.off, n,
						   target + r.addend}
		end
	end
	out[#out + 1] = bytes:sub(at + 1)
	return table.concat(out)
end

-- Fill in every place that needed an address.  The list of absolute ones
-- comes back, because a loader that moves the program has to add its base
-- to each.
function ld.relocate(secs, globals)
	local absolute = {}
	for _, s in ipairs(secs) do
		local own = s.unit and s.unit.addrs or {}
		local syms = s.unit and s.unit.syms or {}

		s.bytes = ld.patch(s, s.bytes, s.relocs, function(n)
			-- A name another unit may also define goes to the
			-- definition that won, not to this unit's own: a
			-- weak one here loses to a strong one there.
			local d = syms[n]

			if d and d.global and globals[n] then
				return globals[n]
			end
			return own[n] or globals[n]
		end, absolute, s.unit and s.unit.weak)
	end
	return absolute
end

-- ELF ------------------------------------------------------------------

local EM = {riscv64 = 243, riscv32 = 243, amd64 = 62, xtensa = 94,
	    arm64 = 183, i386 = 3}

-- The targets whose files are ELFCLASS32.
local NARROW = {riscv32 = true, xtensa = true, i386 = true}

local function u(v, n)
	local b = {}
	for i = 0, n - 1 do b[i + 1] = string.char(v >> (8 * i) & 255) end
	return table.concat(b)
end

-- What follows the loaded bytes of an image: its debug sections, a symbol
-- table of the globals unless `nosyms`, and the section headers, which name
-- the loaded sections too.  `at` is where the file ends so far.
function ld.sectail(secs, segs, at, bits, debug, globals, nosyms)
	local W = bits == 64 and 8 or 4
	local out, off = {}, at
	local names, nameat = {"\0"}, {}
	local nlen = 1

	local function name(s)
		if not nameat[s] then
			nameat[s] = nlen
			names[#names + 1] = s .. "\0"
			nlen = nlen + #s + 1
		end
		return nameat[s]
	end
	local function put(bytes, a)
		local pad = (-off) % a

		out[#out + 1] = string.rep("\0", pad) .. bytes
		off = off + pad
		local here = off

		off = off + #bytes
		return here
	end
	-- The loaded sections, one header for each name.
	local hdrs, byname = {}, {}

	for _, s in ipairs(secs) do
		if s.addr and (s.size > 0 or s.bss) then
			local h = byname[s.name]

			if not h then
				h = {name = s.name, addr = s.addr, hi = s.addr,
				     bss = true, align = 1, perm = 0,
				     tls = s.name:match("^%.t[bd]") ~= nil}
				byname[s.name] = h
				hdrs[#hdrs + 1] = h
			end
			if s.addr < h.addr then h.addr = s.addr end
			if s.addr + s.size > h.hi then h.hi = s.addr + s.size end
			if not s.bss then h.bss = false end
			if (s.align or 1) > h.align then h.align = s.align end
			h.perm = h.perm | ld.perm(s.name, s)
		end
	end
	table.sort(hdrs, function(x, y) return x.addr < y.addr end)
	for _, h in ipairs(hdrs) do
		h.off = 0
		for _, g in ipairs(segs) do
			if h.addr >= g.addr and h.addr < g["end"] then
				h.off = g.offset + (h.addr - g.addr)
			end
		end
	end
	for _, d in ipairs(debug) do d.off = put(d.bytes, d.align) end
	local tlslo = ld.tlslo(secs)
	-- The globals, each in the section it falls in.
	local gnames = {}

	for nm in pairs(globals or {}) do gnames[#gnames + 1] = nm end
	table.sort(gnames)
	local syms, str, slen = {string.rep("\0", bits == 64 and 24 or 16)},
		{"\0"}, 1

	for _, nm in ipairs(gnames) do
		local v, ndx, info = globals[nm], 0xfff1, 16

		-- STB_GLOBAL, and STT_FUNC or STT_OBJECT by the section.  A
		-- thread-local one is STT_TLS, its value an offset in the
		-- block.
		for i, h in ipairs(hdrs) do
			if v >= h.addr and v < h.hi and ndx == 0xfff1 then
				ndx = i
				info = h.tls and 22 or
					h.perm & 1 ~= 0 and 18 or 17
			end
		end
		if info == 22 then v = v - tlslo end
		if bits == 64 then
			syms[#syms + 1] = u(slen, 4) .. u(info, 1) .. "\0" ..
				u(ndx, 2) .. u(v, 8) .. u(0, 8)
		else
			syms[#syms + 1] = u(slen, 4) .. u(v, 4) .. u(0, 4) ..
				u(info, 1) .. "\0" .. u(ndx, 2)
		end
		str[#str + 1] = nm .. "\0"
		slen = slen + #nm + 1
	end
	local symoff = not nosyms and put(table.concat(syms), W)
	local stroff = not nosyms and put(table.concat(str), 1)
	local nhdr = #hdrs + #debug + (nosyms and 2 or 4)
	local symidx = #hdrs + #debug + 1

	for _, h in ipairs(hdrs) do name(h.name) end
	for _, d in ipairs(debug) do name(d.name) end
	if not nosyms then name(".symtab"); name(".strtab") end
	name(".shstrtab")
	local shstroff = put(table.concat(names), 1)
	local sh = {string.rep("\0", bits == 64 and 64 or 40)}

	local function shdr(nm, ty, flags, addr, o, size, link, info, a, ent)
		sh[#sh + 1] = u(nameat[nm], 4) .. u(ty, 4) .. u(flags, W) ..
			u(addr, W) .. u(o, W) .. u(size, W) .. u(link, 4) ..
			u(info, 4) .. u(a, W) .. u(ent, W)
	end
	for _, h in ipairs(hdrs) do
		local fl = 2

		if h.perm & 2 ~= 0 then fl = fl | 1 end
		if h.perm & 1 ~= 0 then fl = fl | 4 end
		if h.tls then fl = fl | 0x400 end
		local ty = h.bss and 8 or h.name:match("^%.note") and 7 or 1

		shdr(h.name, ty, fl, h.addr, h.off,
			h.hi - h.addr, 0, 0, h.align, 0)
	end
	for _, d in ipairs(debug) do
		shdr(d.name, 1, d.strings and 0x30 or 0, 0, d.off, #d.bytes,
			0, 0, d.align, d.strings and 1 or 0)
	end
	if not nosyms then
		shdr(".symtab", 2, 0, 0, symoff, #table.concat(syms),
			symidx + 1, 1, W, bits == 64 and 24 or 16)
		shdr(".strtab", 3, 0, 0, stroff, slen, 0, 0, 1, 0)
	end
	shdr(".shstrtab", 3, 0, 0, shstroff, nlen, 0, 0, 1, 0)
	local shoff = put(table.concat(sh), W)

	return {at = at, shoff = shoff, shnum = nhdr, shstrndx = nhdr - 1,
		bytes = table.concat(out)}
end

-- Sections that sit near one another share a segment; a gap wider than a
-- page starts a new one, because filling it would put the whole hole in the
-- file.
function ld.segments(secs, base, detached, slack)
	local live = {}
	for _, s in ipairs(secs) do
		if s.size > 0 then live[#live + 1] = s end
	end
	table.sort(live, function(x, y) return x.addr < y.addr end)
	local segs = {}
	local cur
	for _, s in ipairs(live) do
		local p = ld.perm(s.name, s)

		if cur and p == cur.perm and s.addr >= cur.addr and
		   s.addr - cur["end"] <= 0x1000 then
			cur[#cur + 1] = s
			-- .tbss overlaps what follows it, so the end is the
			-- furthest one yet, not the last one's.
			cur["end"] = math.max(cur["end"], s.addr + s.size)
		else
			cur = {s, addr = s.addr, perm = p,
			       ["end"] = s.addr + s.size}
			segs[#segs + 1] = cur
		end
	end
	-- A note has a program header of its own, which a kernel reads to
	-- learn what system the program is for.  OpenBSD's kernel reads
	-- only the note that header covers, so its own goes before the
	-- GNU property note a system object may also carry.
	for _, s in ipairs(live) do
		if s.name == ".note.openbsd.ident" then
			segs.note = s
			break
		end
		if s.name:sub(1, 6) == ".note." and not segs.note then
			segs.note = s
		end
	end
	-- OpenBSD's kernel fills PT_OPENBSD_RANDOMIZE with random bytes,
	-- and leaves PT_OPENBSD_MUTABLE writable when it makes the rest of
	-- a static program immutable.
	segs.extra = {}
	for _, k in ipairs({{"^%.openbsd%.randomdata", 0x65a3dbe6, 8},
			    {"^%.openbsd%.mutable", 0x65a3dbe5, 0x1000}}) do
		local lo, hi

		for _, s in ipairs(live) do
			if s.name:match(k[1]) then
				lo = math.min(lo or s.addr, s.addr)
				hi = math.max(hi or 0, s.addr + s.size)
			end
		end
		if lo then
			if k[3] == 0x1000 then hi = align(hi, 0x1000) end
			segs.extra[#segs.extra + 1] = {typ = k[2], addr = lo,
				size = hi - lo, align = k[3]}
		end
	end
	-- The thread-local block: .tdata in the file, then .tbss.  Its
	-- end is where the thread pointer points in each copy.
	local tlo, thi, tfile, talign
	for _, s in ipairs(live) do
		local f = family(s.name)

		if f == ".tdata" or f == ".tbss" then
			tlo = math.min(tlo or s.addr, s.addr)
			thi = math.max(thi or 0, s.addr + s.size)
			talign = math.max(talign or 1, s.align or 1)
			if f == ".tdata" then
				tfile = math.max(tfile or 0, s.addr + s.size)
			end
		end
	end
	if tlo then
		segs.extra[#segs.extra + 1] = {typ = 7, addr = tlo,
			size = thi - tlo, filesz = (tfile or tlo) - tlo,
			align = talign}
		segs.tls = {lo = tlo, size = thi - tlo, align = talign}
	end
	-- The headers go in front of whichever segment holds the base, and
	-- that segment goes first in the file so that its offset is zero.
	-- A machine that starts at the base address instead wants them out
	-- of the way, in the part of the file no segment covers.
	--
	-- `slack` is the room the headers themselves take.  A page was
	-- assumed here once, which is right only while there are few
	-- enough of them to fit in one: past that the test failed, no
	-- segment was marked, and the headers sat in the file outside
	-- every load.  A program that reads its own headers through
	-- AT_PHDR then faults on the first one.
	slack = slack or 0x1000
	for i, g in ipairs(segs) do
		if detached then break end
		if base >= g.addr - slack and base <= g["end"] then
			g.addr = base
			g.headers = true
			table.remove(segs, i)
			table.insert(segs, 1, g)
			break
		end
	end
	return segs
end

-- A static executable.  The loader reads only the program headers; the
-- section headers and symbol table after the image are for debuggers and
-- tools, and `nosyms` leaves the symbols out.  `bytes` hands over one
-- section at a time, so that a link does not have to hold the whole image.
function ld.elf(w, secs, entry, base, endaddr, target, segs, detached, bytes,
		syscalls, debug, globals, nosyms)
	local bits = NARROW[target] and 32 or 64
	local ehsize = bits == 64 and 64 or 52
	local phsize = bits == 64 and 56 or 32
	segs = segs or ld.segments(secs, base, detached)
	-- A program that reads its own headers looks for PT_PHDR to work
	-- out where it was loaded, and the kernel reads PT_GNU_STACK to
	-- learn that the stack need not be executable.  Both only make
	-- sense when the headers are in the image.
	local first = segs[1]
	local withphdr = first and first.headers and not detached

	local nph = #segs + (segs.note and 1 or 0) + #segs.extra +
		(syscalls and 1 or 0) + (withphdr and 2 or 1)
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

	-- Where each system call instruction stands, which OpenBSD asks
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
		segs.systab = table.concat(t)
		segs.sysoff = sysoff
		at = at + #segs.systab
	end
	-- The section headers go last of all.
	local tail = ld.sectail(secs, segs, at, bits, debug or {}, globals,
		nosyms)

	w:write("\127ELF")
	w:write(string.char(bits == 64 and 2 or 1, 1, 1, 0))
	w:write(string.rep("\0", 8))
	w:write(u(2, 2))			-- ET_EXEC
	w:write(u(EM[target] or 243, 2))
	w:write(u(1, 4))
	if bits == 64 then
		w:write(u(entry, 8))
		w:write(u(ehsize, 8))		-- phoff
		w:write(u(tail.shoff, 8))
	else
		w:write(u(entry, 4))
		w:write(u(ehsize, 4))
		w:write(u(tail.shoff, 4))
	end
	w:write(u(target == "riscv64" and 4 or 0, 4))	-- e_flags
	w:write(u(ehsize, 2))
	w:write(u(phsize, 2))
	w:write(u(nph, 2))
	w:write(u(bits == 64 and 64 or 40, 2))
	w:write(u(tail.shnum, 2))
	w:write(u(tail.shstrndx, 2))

	local function phdr(kind, perm, off, addr, fsz, msz, align)
		if bits == 64 then
			w:write(u(kind, 4))
			w:write(u(perm, 4))
			w:write(u(off, 8))
			w:write(u(addr, 8))
			w:write(u(addr, 8))
			w:write(u(fsz, 8))
			w:write(u(msz, 8))
			w:write(u(align, 8))
		else
			w:write(u(kind, 4))
			w:write(u(off, 4))
			w:write(u(addr, 4))
			w:write(u(addr, 4))
			w:write(u(fsz, 4))
			w:write(u(msz, 4))
			w:write(u(perm, 4))
			w:write(u(align, 4))
		end
	end

	if withphdr then
		local sz = nph * phsize

		phdr(6, 4, ehsize, first.addr + ehsize, sz, sz, 8)
	end
	-- The stack, which nothing loads: its permission is the whole
	-- message, and a program with no such header may be given one
	-- that can be run from.
	phdr(0x6474e551, 6, 0, 0, 0, 0, 16)
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
	if syscalls then
		local t = segs.systab

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
	for _, x in ipairs(segs.extra) do
		local off, filesz = 0, 0

		for _, g in ipairs(segs) do
			if x.addr >= g.addr and x.addr < g["end"] then
				off = g.offset + (x.addr - g.addr) +
					(g.headers and start or 0)
				filesz = x.filesz or math.max(0,
					math.min(x.size,
					g.addr + g.filesz - x.addr))
			end
		end
		if bits == 64 then
			w:write(u(x.typ, 4) .. u(6, 4) .. u(off, 8) ..
				u(x.addr, 8) .. u(x.addr, 8) ..
				u(filesz, 8) .. u(x.size, 8) .. u(x.align, 8))
		else
			w:write(u(x.typ, 4) .. u(off, 4) .. u(x.addr, 4) ..
				u(x.addr, 4) .. u(filesz, 4) .. u(x.size, 4) ..
				u(6, 4) .. u(x.align, 4))
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
	if segs.systab then wrote = segs.sysoff + #segs.systab end
	if wrote > tail.at then error("the section table is misplaced") end
	w:write(string.rep("\0", tail.at - wrote))
	w:write(tail.bytes)
end

-- Link one or more assembled units into a static executable.
function ld.link(units, opt)
	opt = opt or {}
	local base = opt.base or 0x10000
	local target = opt.target or "riscv64"
	local bits = NARROW[target] and 32 or 64
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
		-- The count only grows, for the reason in ld.linkfiles.
		local want = #segs + (segs.note and 1 or 0) + #segs.extra
		local again = want > n
		if again then n = want end
	until not again
	for k, v in pairs(opt.symbols or {}) do
		if not globals[k] then globals[k] = v end
	end
	local absolute = ld.relocate(secs, globals)
	local entry = globals[opt.entry or "_start"]
	if not entry then error("no entry symbol") end
	local w = buf.new()
	ld.elf(w, secs, entry, base, endaddr, target, segs, detached,
		function(s) return s.bytes end, nil, nil, globals, opt.nosyms)
	return w:text(), globals, absolute
end

-- What a set of named files really contributes.  An object contributes
-- itself; an archive contributes only the members that something still
-- needs, and taking one member may make another needed, so the pass
-- repeats until nothing more is pulled in.
function ld.inputs(paths, whole)
	local ins, arcs = {}, {}
	local defined, wanted = {}, {}

	-- `--trace` names every input the link takes, a member as
	-- archive(member); crunchgen builds its trimmed libc from that.
	local function take(path, at0, label)
		local h = header(path, false, at0)

		if ld.trace then ld.trace(label or path) end
		ins[#ins + 1] = {path = path, at0 = at0,
				 member = label ~= nil or nil}
		for name, d in pairs(h.syms) do
			if d.global then defined[name] = true end
		end
		-- A weak reference takes nothing out of an archive, as
		-- GNU ld does: it stands for zero when nothing else asks.
		for _, name in ipairs(h.symnames) do
			if not h.syms[name] and not (h.weak and h.weak[name])
			then
				wanted[name] = wanted[name] or label or path
			end
		end
	end

	for _, p in ipairs(paths) do
		local ms, index = ar.members(p)

		if ms and whole and whole[p] then
			-- --whole-archive: every member, asked for or not
			for _, m in ipairs(ms) do
				take(m.file, m.off, p .. "(" .. m.name .. ")")
			end
		elseif ms then
			arcs[#arcs + 1] = {path = p, members = ms, index = index}
		else
			take(p, 0)
		end
	end
	-- One archive is searched until it has nothing more to give before
	-- the next is, as GNU ld does: install media put their own sscanf
	-- and vfscanf in libstubs ahead of libc, and the vfscanf that
	-- sscanf asks for has to come from there too.  Past the last
	-- archive the search starts over, the way --start-group does.
	local function search(a)
		local took = false

		-- With an index only the members that define a name still
		-- wanted are read, in the order they sit.
		if a.index then
			local pick = {}

			for name, by in pairs(wanted) do
				local m = a.index[name]

				if m and not m.taken and not defined[name]
				   and not pick[m] then
					pick[m] = {by, name}
				end
			end
			for _, m in ipairs(a.members) do
				if pick[m] and not m.taken then
					local label = a.path .. "(" .. m.name .. ")"

					m.taken = true
					if ld.why then
						ld.why(pick[m][1], label, pick[m][2])
					end
					take(m.file, m.off, label)
					took = true
				end
			end
			return took
		end
		for _, m in ipairs(a.members) do
			if m.taken then goto next end
			local h = header(m.file, false, m.off)

			for name, d in pairs(h.syms) do
				if d.global and wanted[name] and
				   not defined[name] then
					local label = a.path .. "(" .. m.name .. ")"

					m.taken = true
					if ld.why then
						ld.why(wanted[name], label, name)
					end
					take(m.file, m.off, label)
					took = true
					break
				end
			end
			::next::
		end
		return took
	end
	local again = true

	while again do
		again = false
		for _, a in ipairs(arcs) do
			while search(a) do again = true end
		end
	end
	return ins
end

-- Link object files straight to an output file.  Only the headers are held
-- -- section sizes and the global symbols -- and one section at a time is
-- read, relocated and written, so what this needs does not grow with the
-- size of the program.
-- The segments a linker script asked for, in the shape ld.elf writes.
local PTYPE = {PT_LOAD = 1, PT_DYNAMIC = 2, PT_INTERP = 3, PT_NOTE = 4,
	       PT_PHDR = 6, PT_TLS = 7,
	       PT_GNU_EH_FRAME = 0x6474e550, PT_GNU_STACK = 0x6474e551,
	       PT_GNU_RELRO = 0x6474e552,
	       PT_OPENBSD_MUTABLE = 0x65a3dbe5,
	       PT_OPENBSD_RANDOMIZE = 0x65a3dbe6,
	       PT_OPENBSD_WXNEEDED = 0x65a3dbe7,
	       PT_OPENBSD_BOOTDATA = 0x65a41be6,
	       PT_OPENBSD_SYSCALLS = 0x65a3dbe9}

-- Lay a program out the way its own script says, and link it.  A
-- kernel needs this: the addresses it runs at are not the ones it is
-- loaded at, and it finds its own tables by the symbols the script
-- defines around them.
-- Write the image a script described.  Unlike the ordinary one this
-- keeps the addresses it was given and only works out where in the
-- file each segment's bytes go.
function ld.scriptelf(w, secs, entry, segs, bits, ehsize, phsize, nph,
		      target, spans, bytes, units, globals, shared, types,
		      debug)
	debug = debug or {}
	local start = ehsize + nph * phsize
	local at = start

	for i, g in ipairs(segs) do
		if g.empty then
			g.offset, g.filesz, g.memsz = 0, 0, 0
		elseif g.type and g.type ~= "PT_LOAD" then
			-- A segment that only names part of a loaded one,
			-- PT_OPENBSD_RANDOMIZE say, takes no room of its
			-- own in the file: it is given the bytes of the
			-- loaded one it lies in, below.
			g.within = true
		-- The headers can only be inside the first segment when
		-- the script left room for them: a segment must start at
		-- a file offset that agrees with its address to the page,
		-- and back-dating the address by the header size only
		-- keeps that when the script reserved exactly that much.
		elseif g.filehdr and (g.addr - start) % 0x1000 == 0 then
			g.offset, g.addr = 0, g.addr - start
			g.paddr = g.paddr - start
			at = math.max(at, g["end"] - g.addr)
		else
			-- it does not carry them after all, and what
			-- writes the bytes reads this too
			g.filehdr = nil
			at = at + ((g.addr - at) % 0x1000)
			g.offset = at
			at = at + (g["end"] - g.addr)
		end
		if not g.empty and not g.within then
			-- room at the end that holds nothing is in the
			-- segment but not in the file
			local last = g.addr

			for _, s2 in ipairs(secs) do
				if not s2.bss and s2.size > 0 and
				   s2.addr >= g.addr and
				   s2.addr < g["end"] and
				   s2.addr + s2.size > last then
					last = s2.addr + s2.size
				end
			end
			g.memsz = g["end"] - g.addr
			g.filesz = last - g.addr
		end
	end
	-- A section that no segment covers is not in the file.
	local function segof(s)
		for _, g in ipairs(segs) do
			if not g.empty and not g.within and
			   s.addr >= g.addr and s.addr < g["end"] then
				return g
			end
		end
	end
	for _, g in ipairs(segs) do
		if g.within then
			local l = segof({addr = g.addr})

			g.offset = l and l.offset + (g.addr - l.addr) or 0
			g.paddr = l and l.paddr + (g.addr - l.addr) or g.paddr
			g.memsz = g["end"] - g.addr
			g.filesz = l and math.max(0, math.min(g.memsz,
				l.filesz - (g.addr - l.addr))) or 0
		end
	end

	-- The output sections, grouped from the input ones the script
	-- placed, so the file carries a section header table.  objcopy
	-- reads one, and without it there is nothing for it to copy.
	local outs, order = {}, {}

	-- The script's own sections first, in its order: one may be
	-- empty of input and still ask for room with `. = ALIGN(n)`.
	for _, sp in ipairs(spans or {}) do
		if not outs[sp.name] then
			local o = {name = sp.name, addr = sp.start,
				   hi = sp["end"], bss = true, align = 1,
				   perm = 0, empty = true}

			outs[sp.name] = o
			order[#order + 1] = o
		end
	end
	for _, s2 in ipairs(secs) do
		local nm = s2.outname or s2.name
		local o = outs[nm]

		if not o then
			o = {name = nm, addr = s2.addr, hi = s2.addr,
			     bss = true, align = 1, perm = 0}
			outs[nm] = o
			order[#order + 1] = o
		end
		-- The first real part decides where the section is; the
		-- span only says so for one that holds nothing.
		if o.empty then
			o.addr, o.empty = s2.addr, nil
		elseif s2.addr < o.addr then
			o.addr = s2.addr
		end
		if s2.addr + s2.size > o.hi then
			o.hi = s2.addr + s2.size
		end
		if not s2.bss then o.bss = false end
		if (s2.align or 1) > o.align then o.align = s2.align end
		o.perm = o.perm | ld.perm(s2.name, s2)
	end
	local dataend = ehsize + nph * phsize

	for _, o in ipairs(order) do
		local g = segof({addr = o.addr})

		o.size = o.hi - o.addr
		o.off = g and (g.offset + (o.addr - g.addr)) or 0
		if not o.bss and g and o.off + o.size > dataend then
			dataend = o.off + o.size
		end
	end
	-- A section's room is in the file where its segment's bytes are,
	-- the padding a script asked for included.
	for _, o in ipairs(order) do
		local g = not o.bss and segof({addr = o.addr})

		if g and o.addr + o.size - g.addr > g.filesz then
			g.filesz = o.addr + o.size - g.addr
			if g.memsz < g.filesz then g.memsz = g.filesz end
		end
	end
	-- the names, and then the table, both past everything loadable
	local strs, stroff = "\0", {}

	for _, o in ipairs(order) do
		stroff[o.name] = #strs
		strs = strs .. o.name .. "\0"
	end
	stroff[".shstrtab"] = #strs
	strs = strs .. ".shstrtab\0"
	stroff[".symtab"] = #strs
	strs = strs .. ".symtab\0"
	stroff[".strtab"] = #strs
	strs = strs .. ".strtab\0"
	for _, d in ipairs(debug) do
		stroff[d.name] = #strs
		strs = strs .. d.name .. "\0"
	end
	-- The names the link answered for, so that what comes out can be
	-- read from outside: nm on an image with no symbol table says
	-- nothing at all, and an image laid out by a script is the one
	-- most in need of reading.
	local syms, symstr = {}, "\0"
	do
		local names = {}

		for name in pairs(globals or {}) do
			names[#names + 1] = name
		end
		table.sort(names)
		for _, name in ipairs(names) do
			local v = globals[name]
			local ndx = 0xfff1			-- SHN_ABS

			-- Which section a name belongs to, the way ld
			-- decides it: the one it falls in, and for one
			-- standing at the end -- `__rela_end = .` after
			-- the input rules -- the last one it is past.
			-- An absolute symbol does not move with the
			-- image, and an image that moves itself reads
			-- these to find out how much to move.
			for i, o in ipairs(order) do
				if v >= o.addr and v <= o.addr + o.size then
					ndx = i
					break
				end
				if v > o.addr then ndx = i end
			end
			syms[#syms + 1] = {name = name, value = v,
					   ndx = ndx, at = #symstr}
			symstr = symstr .. name .. "\0"
		end
	end
	local symsz = bits == 64 and 24 or 16
	-- The debug sections go after the names, and nothing maps them.
	local dbgat = dataend + #strs

	for _, d in ipairs(debug) do
		d.off = align(dbgat, d.align)
		dbgat = d.off + #d.bytes
	end
	local symoff = (dbgat + 7) // 8 * 8
	local stroff2 = symoff + (#syms + 1) * symsz
	local shoff = (stroff2 + #symstr + 7) // 8 * 8
	local shnum = #order + 4 + #debug
	local shsize = bits == 64 and 64 or 40

	w:write("\127ELF")
	w:write(string.char(bits == 64 and 2 or 1, 1, 1, 0))
	w:write(string.rep("\0", 8))
	w:write(u(shared and 3 or 2, 2))		-- ET_DYN or ET_EXEC
	w:write(u(EM[target] or 62, 2))
	w:write(u(1, 4))
	if bits == 64 then
		w:write(u(entry, 8))
		w:write(u(ehsize, 8))
		w:write(u(shoff, 8))
	else
		w:write(u(entry, 4))
		w:write(u(ehsize, 4))
		w:write(u(shoff, 4))
	end
	w:write(u(target == "riscv64" and 4 or 0, 4))
	w:write(u(ehsize, 2))
	w:write(u(phsize, 2))
	w:write(u(nph, 2))
	w:write(u(shsize, 2))
	w:write(u(shnum, 2))
	w:write(u(#order + 1, 2))		-- where .shstrtab sits

	for _, g in ipairs(segs) do
		local ty = g.empty and 0 or (PTYPE[g.type] or 1)

		if bits == 64 then
			w:write(u(ty, 4))
			w:write(u(g.perm or 7, 4))
			w:write(u(g.offset, 8))
			w:write(u(g.addr, 8))
			w:write(u(g.paddr, 8))
			w:write(u(g.filesz, 8))
			w:write(u(g.memsz, 8))
			w:write(u(0x1000, 8))
		else
			w:write(u(ty, 4))
			w:write(u(g.offset, 4))
			w:write(u(g.addr, 4))
			w:write(u(g.paddr, 4))
			w:write(u(g.filesz, 4))
			w:write(u(g.memsz, 4))
			w:write(u(g.perm or 7, 4))
			w:write(u(0x1000, 4))
		end
	end
	-- the bytes, segment by segment, in file order
	local wrote = start
	local later = {}

	table.sort(segs, function(x, y) return x.offset < y.offset end)
	for _, g in ipairs(segs) do
		-- A segment with nothing in the file, bss or one that
		-- only names part of another, writes no bytes, and no
		-- padding up to where it would start either.
		if g.empty or g.within or g.filesz == 0 then goto next end
		local here = g.addr + (g.filehdr and start or 0)

		if g.offset + (g.filehdr and start or 0) > wrote then
			w:write(string.rep("\0",
				g.offset + (g.filehdr and start or 0) - wrote))
			wrote = g.offset + (g.filehdr and start or 0)
		end
		for _, s in ipairs(secs) do
			if segof(s) == g and not s.bss and s.size > 0 then
				if s.addr < here then
					error("sections overlap at " ..
						s.name)
				end
				w:write(string.rep("\0", s.addr - here))
				-- A section read from an object is only
				-- placed now and written later, with the rest
				-- of its object: see the end of this function.
				if s.unit and not s.synth and not s.rela then
					later[#later + 1] = {s, w:seek()}
					w:seek("cur", s.size)
				else
					w:write(bytes(s))
				end
				wrote = wrote + (s.addr - here) + s.size
				here = s.addr + s.size
			end
		end
		-- A section that asked for room past what went in it
		-- gets the bytes, so nothing reading its size runs off
		-- the end of the file.
		local padto = here

		for _, o in ipairs(order) do
			if not o.bss and segof({addr = o.addr}) == g and
			   o.addr + o.size > padto then
				padto = o.addr + o.size
			end
		end
		if padto > here then
			w:write(string.rep("\0", padto - here))
			wrote = wrote + (padto - here)
		end
		::next::
	end
	-- The names, and then one header for each output section, with
	-- the null entry first and the name table last.
	if wrote < dataend then
		w:write(string.rep("\0", dataend - wrote))
		wrote = dataend
	end
	w:write(strs)
	wrote = wrote + #strs
	for _, d in ipairs(debug) do
		w:write(string.rep("\0", d.off - wrote))
		w:write(d.bytes)
		wrote = d.off + #d.bytes
	end
	if wrote < symoff then
		w:write(string.rep("\0", symoff - wrote))
		wrote = symoff
	end
	-- Global, with the kind and size the object gave the name, which
	-- a tool like OpenBSD's installboot reads back through nlist.
	local function sym(name, value, ndx, info, size)
		if bits == 64 then
			w:write(u(name, 4))
			w:write(string.char(info, 0))
			w:write(u(ndx, 2))
			w:write(u(value, 8))
			w:write(u(size, 8))
		else
			w:write(u(name, 4))
			w:write(u(value, 4))
			w:write(u(size, 4))
			w:write(string.char(info, 0))
			w:write(u(ndx, 2))
		end
	end

	sym(0, 0, 0, 0, 0)
	for _, d in ipairs(syms) do
		local t = types and types[d.name]

		sym(d.at, d.value, d.ndx, 0x10 | (t and t.styp or 0),
			t and t.size or 0)
	end
	wrote = wrote + (#syms + 1) * symsz
	w:write(symstr)
	wrote = wrote + #symstr
	if wrote < shoff then
		w:write(string.rep("\0", shoff - wrote))
	end
	local function shdr(name, ty, flags, addr, off, size, align,
			    link, info, ent)
		local n = bits == 64 and 8 or 4

		w:write(u(name, 4))
		w:write(u(ty, 4))
		w:write(u(flags, n))
		w:write(u(addr, n))
		w:write(u(off, n))
		w:write(u(size, n))
		w:write(u(link or 0, 4))
		w:write(u(info or 0, 4))
		w:write(u(align, n))
		w:write(u(ent or 0, n))
	end

	shdr(0, 0, 0, 0, 0, 0, 0)
	-- The tables a loader reads say what they are, and which table
	-- holds their names: readelf finds the relocations that way.
	local idx = {}

	for i, o in ipairs(order) do idx[o.name] = i end
	local SHT = {[".dynsym"] = {11, ".dynstr", 1, 24},
		     [".dynstr"] = {3}, [".hash"] = {5, ".dynsym", 0, 4},
		     [".rela.dyn"] = {4, ".dynsym", 0, 24},
		     [".dynamic"] = {6, ".dynstr", 0, 16},
		     [".note"] = {7}}
	for _, o in ipairs(order) do
		-- alloc, and write or execute as the permission says
		local fl = 2
		local t = not o.bss and SHT[o.name] or {}

		if o.perm & 2 ~= 0 then fl = fl | 1 end
		if o.perm & 1 ~= 0 then fl = fl | 4 end
		if o.name:match("^%.note") and not o.bss then t = {7} end
		shdr(stroff[o.name], o.bss and 8 or t[1] or 1, fl, o.addr,
			o.off, o.size, o.align, t[2] and idx[t[2]] or 0,
			t[3] or 0, t[4] or 0)
	end
	shdr(stroff[".shstrtab"], 3, 0, 0, dataend, #strs, 1)
	shdr(stroff[".symtab"], 2, 0, 0, symoff, (#syms + 1) * symsz, 8,
		#order + 3, 1, symsz)
	shdr(stroff[".strtab"], 3, 0, 0, stroff2, #symstr, 1)
	for _, d in ipairs(debug) do
		shdr(stroff[d.name], 1, d.strings and 0x30 or 0, 0, d.off,
			#d.bytes, d.align, 0, 0, d.strings and 1 or 0)
	end
	-- The placed sections, one object at a time: the file order went
	-- through every object once for each output section, and this
	-- reads each object's sections together.
	local rank = {}

	for i, un in ipairs(units or {}) do rank[un] = i end
	table.sort(later, function(x, y)
		local p, q = rank[x[1].unit] or 0, rank[y[1].unit] or 0

		if p ~= q then return p < q end
		return x[2] < y[2]
	end)
	for _, p in ipairs(later) do
		local b = bytes(p[1])

		if #b ~= p[1].size then
			error(("%s: %s is %d bytes, placed as %d"):format(
				p[1].unit.path, p[1].name, #b, p[1].size))
		end
		w:seek("set", p[2])
		w:write(b)
	end
end

-- What each machine calls "add the load address to what is written
-- here", which is the only dynamic relocation a self-relocating image
-- needs.
local RELATIVE = {amd64 = 8, arm64 = 1027, riscv64 = 3, riscv32 = 3,
		  xtensa = 2}

-- Does the script ask for the relocations?  A self-relocating image
-- collects them into a section of its own and walks them at startup;
-- one linked for a fixed address wants nothing of the sort, and must
-- not pay for the extra passes that making them costs.
local function wantsrela(script)
	if not script.sections then return false end
	for _, st in ipairs(script.sections) do
		for _, it in ipairs(st.body or {}) do
			for _, p in ipairs(it.pats or {}) do
				if p:sub(1, 5) == ".rela" then
					return true
				end
			end
		end
	end
	return false
end

-- The entries, in the shape a loader reads: where the word is, what to
-- do with it, and what to add the load address to.
local function relabytes(list, target, bits)
	local b = buf.new()
	local kind = RELATIVE[target] or 8

	table.sort(list, function(x, y) return x[1] < y[1] end)
	for _, e in ipairs(list) do
		-- A word narrower than an address cannot be moved: the
		-- loader has nowhere to put the answer.  Saying which
		-- one beats writing an image that goes quiet.
		if bits == 64 and e[2] ~= 8 then
			error(("a %d byte absolute at %#x cannot be " ..
				"relocated: build it with -fpic")
				:format(e[2], e[1]), 0)
		end
		if bits == 64 then
			b:add(u(e[1], 8))
			b:add(u(kind, 8))
			b:add(u(e[3], 8))
		else
			b:add(u(e[1], 4))
			b:add(u(kind, 4))
			b:add(u(e[3], 4))
		end
	end
	return b:text()
end

-- The hash the dynamic loader looks names up by.
local function elfhash(name)
	local h = 0

	for i = 1, #name do
		h = ((h << 4) + name:byte(i)) & 0xffffffff
		local g = h & 0xf0000000

		if g ~= 0 then h = h ~ (g >> 24) end
		h = h & ~g & 0xffffffff
	end
	return h
end

-- The names a version script lets a shared object offer: those under
-- `global:`, and everything when it says nothing or has no `local: *`.
local function versionscript(path)
	if not path then return nil end
	local f = assert(io.open(path), "cannot open " .. path)
	local text = f:read("a"):gsub("/%*.-%*/", ""):gsub("#[^\n]*", "")

	f:close()
	local ldscript = require "mcc.ldscript"
	local keep, hide, into = {}, {}, nil

	for w in text:gmatch("[^%s;{}]+") do
		if w == "global:" then
			into = keep
		elseif w == "local:" then
			into = hide
		elseif into then
			into[#into + 1] = w
		end
	end
	return function(name)
		for _, p in ipairs(keep) do
			if ldscript.match(p, name) then return true end
		end
		for _, p in ipairs(hide) do
			if ldscript.match(p, name) then return false end
		end
		return true
	end
end

ld.versionscript = versionscript

-- What a script link needs to write a shared object: the table of
-- offered names, its strings and hash, the dynamic table, a word for
-- each name reached through GOTPCREL, and OpenBSD's table of system
-- calls.  Everything here is -Bsymbolic: each reference is bound at
-- link time and the loader only adds the load address.
local function sharedparts(units, opt)
	local offer = versionscript(opt.versionscript)
	local defs, hidden = {}, {}
	local got, gotn, gotlocal = {}, 0, {}
	local nsys = 0

	for i, u in ipairs(units) do
		local h = header(u.path, false, u.at0)

		for name, d in pairs(h.syms) do
			if d.global and d.sec and not d.abs and
			   (not defs[name] or (defs[name].weak and
			    not d.weak)) then
				defs[name] = d
			end
			if d.vis == 1 or d.vis == 2 then hidden[name] = true end
		end
		for _, k in ipairs(u.elf and elf.gotrefs(u) or {}) do
			local nm = elf.wrapped(h.symnames[k])
			local d = h.syms[nm]
			local key = nm

			if d and not d.global then
				key = i .. ":" .. nm
				gotlocal[i] = gotlocal[i] or {}
				gotlocal[i][nm] = key
			end
			if not got[key] then
				gotn = gotn + 1
				got[key] = gotn
			end
		end
		for _, x in ipairs(u.order) do
			nsys = nsys + #syscallsof(u, x)
		end
	end
	local names = {}

	for name in pairs(defs) do
		if not hidden[name] and (not offer or offer(name)) then
			names[#names + 1] = name
		end
	end
	table.sort(names)
	local str, stroff = {"\0"}, {}
	local len = 1

	for _, nm in ipairs(names) do
		stroff[nm] = len
		str[#str + 1] = nm .. "\0"
		len = len + #nm + 1
	end
	local nsym = #names + 1
	local nb = 1

	while nb * 4 < nsym do nb = nb * 2 end
	local function sec(name, size, perm)
		return {name = name, size = size, align = 8, perm = perm,
			relocs = {}, nrel = 0, synth = true}
	end
	local p = {names = names, defs = defs, stroff = stroff,
		   dynstr = table.concat(str), nsym = nsym, nb = nb,
		   got = got, gotn = gotn, gotlocal = gotlocal,
		   symbolic = opt.symbolic}
	p.secs = {
		dynsym = sec(".dynsym", nsym * 24, 4),
		dynstr = sec(".dynstr", len, 4),
		hash = sec(".hash", 4 * (2 + nb + nsym), 4),
		-- HASH STRTAB SYMTAB STRSZ SYMENT RELA RELASZ RELAENT
		-- RELACOUNT FLAGS NULL
		dynamic = sec(".dynamic", 11 * 16, 6),
	}
	if gotn > 0 then p.secs.got = sec(".got", gotn * 8, 6) end
	if nsys > 0 then
		p.secs.sys = sec(".openbsd.syscalls", nsys * 8, 4)
		p.secs.sys.align = 4
	end
	p.unit = {order = {}, syms = {}, addrs = {}, symnames = {},
		  synthetic = true}
	for _, k in ipairs{"hash", "dynsym", "dynstr", "dynamic", "got",
			   "sys"} do
		if p.secs[k] then
			p.unit.order[#p.unit.order + 1] = p.secs[k]
		end
	end
	return p
end

-- The bytes of the made-up sections, once everything has an address.
local function sharedfill(p, units, globals, spans, rela)
	local S = p.secs
	local function ndx(v)
		for i, sp in ipairs(spans) do
			if v >= sp.start and v < sp["end"] then return i end
		end
		return 0xfff1
	end
	do
		local b = buf.new()

		b:add(string.rep("\0", 24))
		for _, nm in ipairs(p.names) do
			local d = p.defs[nm]
			local bind = d.weak and 2 or 1
			local v = globals[nm] or 0

			b:add(u(p.stroff[nm], 4))
			b:add(string.char(bind << 4 | (d.styp or 0), 0))
			b:add(u(ndx(v), 2))
			b:add(u(v, 8))
			b:add(u(d.size or 0, 8))
		end
		S.dynsym.bytes = b:text()
	end
	S.dynstr.bytes = p.dynstr
	do
		local bucket, chain = {}, {}

		for i = 0, p.nb - 1 do bucket[i] = 0 end
		for i = 0, p.nsym - 1 do chain[i] = 0 end
		for i = p.nsym - 1, 1, -1 do
			local k = elfhash(p.names[i]) % p.nb

			chain[i] = bucket[k]
			bucket[k] = i
		end
		local b = buf.new()

		b:add(u(p.nb, 4))
		b:add(u(p.nsym, 4))
		for i = 0, p.nb - 1 do b:add(u(bucket[i], 4)) end
		for i = 0, p.nsym - 1 do b:add(u(chain[i], 4)) end
		S.hash.bytes = b:text()
	end
	if S.sys then
		local t = {}

		for _, un in ipairs(units) do
			if not un.synthetic then
				for _, x in ipairs(un.order) do
					for _, c in ipairs(syscallsof(un, x)) do
						t[#t + 1] = {x.addr + c.off,
							     c.sysno}
					end
				end
			end
		end
		table.sort(t, function(a, b) return a[1] < b[1] end)
		for i, c in ipairs(t) do t[i] = u(c[1], 4) .. u(c[2], 4) end
		S.sys.bytes = table.concat(t)
	end
	local b = buf.new()
	local function ent(tag, val) b:add(u(tag, 8) .. u(val, 8)) end

	ent(4, S.hash.addr)				-- DT_HASH
	ent(5, S.dynstr.addr)				-- DT_STRTAB
	ent(6, S.dynsym.addr)				-- DT_SYMTAB
	ent(10, #p.dynstr)				-- DT_STRSZ
	ent(11, 24)					-- DT_SYMENT
	if rela and rela.sec then
		ent(7, rela.sec.addr)			-- DT_RELA
		ent(8, rela.sec.size)			-- DT_RELASZ
		ent(9, 24)				-- DT_RELAENT
		ent(0x6ffffff9, rela.sec.size // 24)	-- DT_RELACOUNT
	end
	if p.symbolic then ent(30, 2) end		-- DT_FLAGS: SYMBOLIC
	ent(0, 0)
	S.dynamic.bytes = b:text() ..
		string.rep("\0", S.dynamic.size - #b:text())
end

function ld.scriptlink(paths, w, opt)
	local ldscript = require "mcc.ldscript"
	local f = assert(io.open(opt.script), "cannot open " .. opt.script)
	local script = ldscript.parse(f:read("a"))

	f:close()
	-- A debug section goes out unless the script throws it away.
	opt.dropdebug = function(name)
		for _, st in ipairs(script.sections) do
			for _, it in ipairs(st.name == "/DISCARD/" and
					    st.body or {}) do
				for _, pat in ipairs(it.pats or {}) do
					if ldscript.match(pat, name) then
						return true
					end
				end
			end
		end
		return false
	end
	local bits = NARROW[opt.target] and 32 or 64
	local ehsize, phsize = bits == 64 and 64 or 52, bits == 64 and 56 or 32
	local ins = ld.inputs(paths, opt.whole)
	local units = {}

	for i, x in ipairs(ins) do
		units[i] = header(x.path, true, x.at0)
		units[i].path, units[i].at0 = x.path, x.at0
		units[i].index, units[i].member = i, x.member
	end
	-- A script that collects the relocations wants them made.  How
	-- many there are decides how big the section is, and that
	-- decides where everything after it goes, so they are counted
	-- before anything is placed.
	local rela = (wantsrela(script) or opt.shared) and {} or nil
	local shared

	if opt.shared then
		shared = sharedparts(units, opt)
		units[#units + 1] = shared.unit
	end

	local nph = script.phdrs and #script.phdrs or 1

	if rela then
		-- Only the sections the script keeps are counted: one it
		-- drops, and a script drops every debug section, has
		-- relocations that go nowhere.  The placement decides
		-- which, so it is done once to find out and again with
		-- the section in it.
		local kept = ldscript.layout(script, units,
			ehsize + nph * phsize)
		local n, read = 0, {}

		for _, x in ipairs(kept) do
			local u = x.unit

			if u and not u.synthetic and not read[u] then
				read[u] = header(u.path, false, u.at0)
			end
			local h = read[u]

			if h then
				local _, rs = section(u, x, h.symnames)

				for _, r in ipairs(rs) do
					if r.kind == "abs64" then
						n = n + 1
					end
				end
			end
		end
		-- every table word holds an address the loader moves
		n = n + (shared and shared.gotn or 0)
		rela.n, rela.ent = n, bits == 64 and 24 or 12
		if n > 0 then
			local sec = {name = ".rela.dyn", size = n * rela.ent,
				     align = 8, relocs = {}, rela = true,
				     synth = true, perm = 4}

			rela.sec = sec
			units[#units + 1] = {order = {sec}, syms = {},
					     addrs = {}, symnames = {},
					     rela = true, synthetic = true}
		end
	end
	local secs, sym, byphdr, spans = ldscript.layout(script, units,
		ehsize + nph * phsize)

	-- Everything the units answer for, including the made-up one.
	if rela and rela.sec then rela.sec.rela = true end

	-- What each unit's own labels came to, and then the globals.
	local globals, weakdef = {}, {}

	for i, u in ipairs(units) do
		-- the made-up ones have no file and no names of their own
		if not u.synthetic then
			local h = header(ins[i].path, false, ins[i].at0)

			for k, d in ipairs(h.order) do
				d.addr = u.order[k].addr
			end
			ld.symbols({h}, secs, 0, globals, false, weakdef)
			opt.symtypes = opt.symtypes or {}
			for name, d in pairs(h.syms) do
				if d.global and d.sec and not d.weak or
				   d.global and not opt.symtypes[name] then
					opt.symtypes[name] = {styp = d.styp,
						size = d.size}
				end
			end
		end
	end
	for k, v in pairs(sym) do globals[k] = v end
	for k, v in pairs(opt.symbols or {}) do
		if not globals[k] then globals[k] = v end
	end
	if shared then
		globals._DYNAMIC = shared.secs.dynamic.addr
		if shared.secs.got then
			globals._GLOBAL_OFFSET_TABLE_ = shared.secs.got.addr
		end
		opt.sharedparts = shared
	end
	local entry = globals[opt.entry or script.entry or "_start"]

	if not entry then error("no entry symbol") end

	-- The segments, in the order the script named them.  A segment
	-- covers the output sections that said they belong to it.
	local segs = {}

	-- A script with no PHDRS block says nothing about segments, so
	-- they are made the ordinary way: one per run of sections that
	-- agree on what may be done with them.
	if not script.phdrs then
		local cur

		for _, s in ipairs(secs) do
			if s.size > 0 then
				local pm = ld.perm(s.outname or s.name, s)

				if cur and pm == cur.perm and
				   s.addr - cur["end"] <= 0x1000 then
					cur["end"] = s.addr + s.size
				else
					cur = {addr = s.addr, perm = pm,
					       paddr = s.at or s.addr,
					       type = "PT_LOAD",
					       ["end"] = s.addr + s.size}
					segs[#segs + 1] = cur
				end
			end
		end
		if segs[1] then segs[1].filehdr = true end
		nph = #segs
		return ld.scriptdone(w, secs, entry, segs, bits, ehsize,
			phsize, nph, opt, units, globals, spans, rela)
	end
	-- One header for each the script declared, in its order, even
	-- when nothing landed in it: the script counted them when it
	-- worked out where the headers end.
	for _, g in ipairs(script.phdrs) do
		local parts = byphdr[g.name]
		local lo, hi, at, perm = nil, nil, nil, 0

		for _, st in ipairs(parts or {}) do
			if st["end"] > st.start then
				if not lo or st.start < lo then
					lo, at = st.start, st.at
				end
				if not hi or st["end"] > hi then
					hi = st["end"]
				end
				for _, x in ipairs(secs) do
					if x.outname == st.name then
						perm = perm |
							ld.perm(x.name, x)
					end
				end
			end
		end
		segs[#segs + 1] = {addr = lo or 0, ["end"] = hi or 0,
			paddr = at or lo or 0, type = lo and g.type or nil,
			perm = g.flags or perm, filehdr = g.filehdr,
			empty = lo == nil}
	end
	return ld.scriptdone(w, secs, entry, segs, bits, ehsize, phsize,
		nph, opt, units, globals, spans, rela)
end

-- The second half of a script link, once the segments are known.
function ld.scriptdone(w, secs, entry, segs, bits, ehsize, phsize, nph,
		       opt, units, globals, spans, rela)
	-- One section at a time, relocated as it goes, so a link does not
	-- have to hold the whole image.
	local at, own, names, glob = nil, nil, nil, nil
	local shared = opt.sharedparts
	local gotaddr = shared and shared.secs.got and shared.secs.got.addr
	-- Resolving a section answers with its bytes, and says which of
	-- its words hold an address a loader would have to move.
	-- Each unit's names, read once: output order visits a unit once
	-- for every section it has, and its header is not small.
	local maps = {}
	local function resolve(s, absolute)
		local u = s.unit

		if at ~= u then
			local m = maps[u]

			if not m then
				local h = header(u.path, false, u.at0)
				local idx = {}

				for i, x in ipairs(h.order) do idx[x] = i end
				m = {own = {}, glob = {}, weak = h.weak,
				     names = h.symnames}
				for name, d in pairs(h.syms) do
					if d.global then m.glob[name] = true end
					local i = idx[d.sec]

					if i then
						m.own[name] = u.order[i].addr +
							d.off
					end
				end
				maps[u] = m
			end
			own, glob, weaks, names, at = m.own, m.glob, m.weak,
				m.names, u
		end
		local b, relocs = section(u, s, names)

		return ld.patch(s, b, relocs, function(name, r)
			if r and r.kind == "gotpcrel" and gotaddr then
				local n = shared.got[(shared.gotlocal[u.index]
					or {})[name] or name]

				return gotaddr + 8 * (n - 1), "pc32"
			end
			-- A name another unit may define too goes to the
			-- definition that won, not to this unit's own.
			if glob[name] and globals[name] then
				return globals[name]
			end
			return own[name] or globals[name]
		end, absolute, weaks)
	end

	-- The relocations have to be known before the section holding
	-- them is written, and it may come first in the file, so every
	-- other section is resolved once over before anything goes out.
	local list

	if rela and rela.sec then
		list = {}
		for _, s in ipairs(secs) do
			if not s.synth and not s.bss and s.size > 0 then
				resolve(s, list)
			end
		end
		at = nil
	end
	if shared then
		-- Each table word holds the address of what it names,
		-- which the loader moves like any other.
		if gotaddr then
			local b, vals = buf.new(), {}

			for i, un in ipairs(units) do
				if shared.gotlocal[i] then
					local h = header(un.path, false, un.at0)

					for nm, key in pairs(shared.gotlocal[i]) do
						local d = h.syms[nm]
						local k = 0

						for j, x in ipairs(h.order) do
							if x == d.sec then k = j end
						end
						vals[key] = un.order[k].addr + d.off
					end
				end
			end
			local order = {}

			for key, n in pairs(shared.got) do order[n] = key end
			for n, key in ipairs(order) do
				local v = vals[key] or globals[key]

				if not v then
					error("undefined symbol " .. key)
				end
				b:add(u(v, 8))
				list[#list + 1] = {gotaddr + 8 * (n - 1), 8, v}
			end
			shared.secs.got.bytes = b:text()
		end
		sharedfill(shared, units, globals, spans, rela)
	end

	local debug = ld.debugof(units, globals, opt, opt.dropdebug,
		ld.tlslo(secs))

	ld.scriptelf(w, secs, entry, segs, bits, ehsize, phsize, nph,
		opt.target, spans, function(s)
			if s.rela then
				return relabytes(list or {}, opt.target,
					bits)
			end
			if s.synth then return s.bytes end
			return resolve(s, nil)
		end, units, globals, opt.shared, opt.symtypes, debug)
	return globals
end

function ld.linkfiles(paths, w, opt)
	opt = opt or {}
	local base = opt.base or 0x10000
	local target = opt.target or "riscv64"
	local bits = NARROW[target] and 32 or 64
	local ehsize, phsize = bits == 64 and 64 or 52, bits == 64 and 56 or 32
	local detached = opt.detached

	local ins = ld.inputs(paths, opt.whole)
	-- The sizes alone decide where everything goes, so the first look at
	-- each object skips its symbols.
	local units = {}
	for i, f in ipairs(ins) do
		units[i] = header(f.path, true, f.at0)
	end

	-- A plain GOTPCREL may sit in any instruction that reads memory,
	-- so it cannot become an lea.  Each name it reaches gets a word in
	-- a table of its own.  A name local to its unit is keyed by the
	-- unit too, because another file may use the same one.
	local got, gotn, gotlocal, gotweak = {}, 0, {}, {}
	-- A GOTTPOFF reads a thread-pointer offset out of the table.  Its
	-- word is keyed apart from an address of the same name.
	local tplocal = {}
	-- A GNU indirect function is called through a slot that the C
	-- library fills at startup: it runs the resolver the symbol names,
	-- which picks the version for this processor.  `ifunc` holds each
	-- one, global by name and local by unit.
	local ifunc, ifn, ifuncs = {}, 0, {}
	-- Each unit's symbols, read once here and again for nothing.
	local full = {}
	for i, u in ipairs(units) do
		local refs, tprefs = {}, {}

		if u.elf then refs, tprefs = elf.gotrefs(u) end
		local h = header(ins[i].path, false, ins[i].at0)

		full[i] = h
		for _, k in ipairs(refs) do
			local nm = elf.wrapped(h.symnames[k])
			local d = h.syms[nm]
			local key = nm

			if h.weak[nm] then gotweak[nm] = true end
			if d and not d.global then
				key = i .. ":" .. nm
				gotlocal[i] = gotlocal[i] or {}
				gotlocal[i][nm] = key
			end
			if not got[key] then
				gotn = gotn + 1
				got[key] = gotn
			end
		end
		for _, k in ipairs(tprefs) do
			local nm = elf.wrapped(h.symnames[k])
			local d = h.syms[nm]
			local key = "tp:" .. nm

			if h.weak[nm] then gotweak[key] = true end
			if d and not d.global then
				key = "tp:" .. i .. ":" .. nm
				tplocal[i] = tplocal[i] or {}
				tplocal[i][nm] = key
			end
			if not got[key] then
				gotn = gotn + 1
				got[key] = gotn
			end
		end
		for nm, d in pairs(h and h.syms or {}) do
			if d.styp == 10 and d.sec then
				local key = d.global and nm or (i .. ":" .. nm)

				if not ifunc[key] then
					ifn = ifn + 1
					ifunc[key] = ifn
					ifuncs[ifn] = key
				end
			end
		end
	end
	-- The stubs go with the text, the slots with the table, and the
	-- list of what to fill in with the read-only data, between
	-- __rela_iplt_start and __rela_iplt_end.
	local iunit = {order = {
		{name = ".text.iplt", size = 16 * ifn, align = 16, perm = 5,
		 relocs = {}, nrel = 0},
		{name = ".data.igot", size = 8 * ifn, align = 8, perm = 6,
		 relocs = {}, nrel = 0},
		{name = ".rodata.rela.iplt", size = 24 * ifn, align = 8,
		 perm = 4, relocs = {}, nrel = 0}}}
	local gotunit
	if gotn > 0 then
		gotunit = {order = {{name = ".data.got", size = 8 * gotn,
				     align = 8, perm = 6, relocs = {},
				     nrel = 0}}}
	end
	local placed = {table.unpack(units)}
	if gotunit then placed[#placed + 1] = gotunit end
	placed[#placed + 1] = iunit

	local extra = opt.pinsyscalls and 1 or 0
	local secs, endaddr, segs
	local n = 1
	repeat
		local start = ehsize + n * phsize
		secs, endaddr = ld.place(placed,
			detached and base or (base + start), opt.place)
		segs = ld.segments(secs, base, detached, start)
		-- PT_GNU_STACK always, and PT_PHDR where the headers are
		-- in the image, which is what ld.elf writes.
		local want = #segs + (segs.note and 1 or 0) + extra + 1 +
			#segs.extra +
			((segs[1] and segs[1].headers and not detached)
			 and 1 or 0)
		-- The count only grows.  More room for headers can push
		-- the first section past the page the headers share, and
		-- then one fewer is wanted, which gives the room back and
		-- pulls it in again: that swings for ever.  Room for one
		-- that goes unwritten costs a few bytes and settles.
		local again = want > n
		if again then n = want end
	until not again

	-- Then the global symbols, one object at a time: what a unit says
	-- about its own labels is read again when its bytes go out.
	local globals, weakdef, gotvalue = {}, {}, {}
	-- Where each indirect function's resolver is, by the same key.
	local resolver = {}
	local localtp = {}
	for i, u in ipairs(units) do
		local h = full[i]
		for k, d in ipairs(h.order) do d.addr = u.order[k].addr end
		ld.symbols({h}, secs, base, globals, false, weakdef)
		for nm, key in pairs(gotlocal[i] or {}) do
			local d = h.syms[nm]

			gotvalue[key] = d.sec.addr + d.off
		end
		for nm, key in pairs(tplocal[i] or {}) do
			local d = h.syms[nm]

			localtp[key] = d.sec.addr + d.off
		end
		for nm, d in pairs(h.syms) do
			if d.styp == 10 and d.sec and d.sec.addr then
				local key = d.global and nm or (i .. ":" .. nm)

				if ifunc[key] and not resolver[key] then
					resolver[key] = d.sec.addr + d.off
				end
			end
		end
	end
	local itext, igot, irela = iunit.order[1].addr, iunit.order[2].addr,
		iunit.order[3].addr
	-- A reference to an indirect function reaches its stub: a call
	-- jumps through the slot, and an address taken is the stub's, the
	-- same everywhere in the program.
	local function stub(key) return itext + 16 * (ifunc[key] - 1) end
	for key, n in pairs(ifunc) do
		if not key:find(":", 1, true) and globals[key] then
			globals[key] = stub(key)
		end
		if gotvalue[key] then gotvalue[key] = stub(key) end
	end
	if not globals.__rela_iplt_start then
		globals.__rela_iplt_start = irela
	end
	if not globals.__rela_iplt_end then
		globals.__rela_iplt_end = irela + 24 * ifn
	end
	-- The thread pointer points just past the block, rounded up to its
	-- alignment, so everything in it is at a negative offset.
	local tls = segs.tls
	local tlsend = tls and tls.lo + align(tls.size, tls.align)
	local function tpoff(v)
		if not tlsend then error("no thread-local block") end
		return v - tlsend
	end
	for k, v in pairs(opt.symbols or {}) do
		if not globals[k] then globals[k] = v end
	end
	ld.arraybounds(secs, globals, endaddr)
	ld.marks(secs, globals, base, endaddr,
		segs[1] and segs[1].headers and not detached)
	local entry = globals[opt.entry or "_start"]
	if not entry then error("no entry symbol") end

	-- The list of absolute words is for a loader that moves the program;
	-- a static executable has no use for it and it is as long as the
	-- relocations are.
	-- What a unit knows about its own labels is only needed while its
	-- bytes are going out, so drop it and read it back a unit at a time.
	for i, u in ipairs(units) do
		u.path, u.at0, u.index = ins[i].path, ins[i].at0, i
		u.member = ins[i].member
	end
	local gotaddr = gotunit and gotunit.order[1].addr
	local debug = ld.debugof(units, globals, opt, nil, ld.tlslo(secs))

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
			local h = header(u.path, true, u.at0)

			for k, x in ipairs(h.order) do
				for _, c in ipairs(syscallsof(h, x)) do
					syscalls[#syscalls + 1] = {
						addr = u.order[k].addr + c.off,
						sysno = c.sysno}
				end
			end
		end
	end
	local at, own, names, glob, weaks = nil, nil, nil, nil, nil
	ld.elf(w, secs, entry, base, endaddr, target, segs, detached,
		function(s)
			local u = s.unit
			if u == iunit then
				local out = {}

				for n, key in ipairs(ifuncs) do
					local slot = igot + 8 * (n - 1)
					local at = itext + 16 * (n - 1)

					if s == u.order[1] then
						-- jmp *slot(%rip), then int3
						out[n] = "\255\37" ..
							bin(slot - (at + 6), 4) ..
							("\204"):rep(10)
					elseif s == u.order[2] then
						out[n] = bin(resolver[key], 8)
					else
						out[n] = bin(slot, 8) ..
							bin(37, 8) ..
							bin(resolver[key], 8)
					end
				end
				return table.concat(out)
			end
			if u == gotunit then
				local out = {}

				for key, n in pairs(got) do
					local v = gotvalue[key] or globals[key]

					if key:sub(1, 3) == "tp:" then
						local nm = key:sub(4)
						local a = localtp[key] or
							globals[nm]

						-- A weak one nothing
						-- defined is never read:
						-- glibc tests a marker
						-- before it touches
						-- _nl_current_LC_COLLATE.
						if not a and
						   not gotweak[key] then
							error("undefined " ..
								"symbol " .. nm)
						end
						v = a and tpoff(a) or 0
					end

					if not v and not gotweak[key] then
						error("undefined symbol " .. key)
					end
					v = v or 0
					out[n] = bin(v, 8)
					if absolute and v ~= 0 then
						absolute[#absolute + 1] = {
						    gotaddr + 8 * (n - 1), 8, v}
					end
				end
				return table.concat(out)
			end
			if at ~= u then
				local h = full[u.index] or
					header(u.path, false, u.at0)

				full[u.index] = nil
				own, glob, weaks = {}, {}, h.weak
				for name, d in pairs(h.syms) do
					if d.global then glob[name] = true end
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
			local bytes, relocs = section(u, s, names)
			return ld.patch(s, bytes, relocs, function(name, r)
				if r and r.kind == "gotpcrel" then
					local n = got[(gotlocal[u.index] or
						{})[name] or name]

					return gotaddr + 8 * (n - 1), "pc32"
				end
				if r and r.kind == "gottpoff" then
					local n = got[(tplocal[u.index] or
						{})[name] or ("tp:" .. name)]

					return gotaddr + 8 * (n - 1), "pc32"
				end
				local lk = u.index .. ":" .. name

				if ifunc[lk] and own[name] then
					return stub(lk)
				end
				if r and (r.kind == "tpoff32" or
				    r.kind == "tpoff64") then
					local v = own[name] and not glob[name]
						and own[name] or globals[name]

					return v and tpoff(v)
				end
				if r and (r.kind == "dtpoff32" or
				    r.kind == "dtpoff64") then
					local v = own[name] and not glob[name]
						and own[name] or globals[name]

					return v and v - tls.lo
				end
				-- A name another unit may define too goes
				-- to the definition that won, not to this
				-- unit's own.
				if glob[name] and globals[name] then
					return globals[name]
				end
				return own[name] or globals[name]
			end, absolute, weaks)
		end, syscalls, debug, globals, opt.nosyms)
	return globals, absolute
end

-- `ld -r`: several objects made into one object, which a later link
-- reads like any other.  OpenBSD's library rules build every object that
-- way.  Each input section goes onto the end of the output section of the
-- same name, and its symbols and relocations move with it.  A local name
-- two inputs both use is given the input's number so the two stay apart;
-- a global defined twice is an error unless one of the two is weak.
function ld.relocatable(paths, out, target, scriptpath, whole)
	local ldmatch = require("mcc.ldscript").match
	local a = {order = {}, syms = {}}
	local bysec = {}

	local function outsec(e)
		local d = bysec[e.name]

		if not d then
			d = {name = e.name, size = 0, align = 1,
			     perm = e.perm, bss = e.bss, parts = {},
			     relocs = {}}
			bysec[e.name] = d
			a.order[#a.order + 1] = d
		end
		return d
	end

	-- A file that is not an object is a linker script, as ld takes
	-- one: OpenBSD's makegap links `ld -r gap.link gapdummy.o`.
	local objs, script = {}, nil
	local arcs = {}

	if scriptpath then paths[#paths + 1] = scriptpath end
	for _, path in ipairs(paths) do
		local ms = ar.members(path)

		if ms then
			-- An archive: all of it under --whole-archive,
			-- otherwise the members something asks for.
			if whole and whole[path] then
				for _, m in ipairs(ms) do
					objs[#objs + 1] = {path = m.file,
						at0 = m.off, name = m.name}
				end
			else
				arcs[#arcs + 1] = ms
			end
		elseif elf.is(path) then
			objs[#objs + 1] = {path = path, at0 = 0}
		else
			local f = io.open(path, "rb")
			local text = f and f:read("a") or ""

			if f then f:close() end
			local ok, s = pcall(require("mcc.ldscript").parse, text)

			if not ok or script then
				error(path .. ": ld -r takes objects and " ..
					"one linker script")
			end
			script = s
		end
	end
	local units, where = {}, {}

	for i, o in ipairs(objs) do
		units[i] = header(o.path, false, o.at0)
		-- what the file is called, which a script's pattern and
		-- an error name; path stays where the bytes are read
		units[i].label = o.name or o.path
	end
	-- The members of the other archives that define a name something
	-- already taken asks for, until nothing more is found.
	local function need()
		local have, want = {}, {}

		for _, u in ipairs(units) do
			for nm, sy in pairs(u.syms) do
				if sy.global then have[nm] = true end
			end
		end
		for _, u in ipairs(units) do
			for _, nm in ipairs(u.symnames) do
				if not u.syms[nm] and not have[nm] then
					want[nm] = true
				end
			end
		end
		return have, want
	end
	local again = #arcs > 0

	while again do
		again = false
		local have, want = need()

		for _, ms in ipairs(arcs) do
			for _, m in ipairs(ms) do
				if not m.taken then
					local h = header(m.file, false, m.off)

					for nm, sy in pairs(h.syms) do
						if sy.global and want[nm] and
						   not have[nm] then
							m.taken = true
							h.label = m.name
							units[#units + 1] = h
							objs[#objs + 1] = m
							again = true
							break
						end
					end
				end
			end
		end
	end

	-- Put one input section at the end of an output section.
	local function place(d, u, e)
		local al = e.align or 1
		local off = (d.size + al - 1) // al * al
		local bytes, relocs = section(u, e)

		if al > d.align then d.align = al end
		if d.bss and not e.bss then
			error(e.name .. ": data where the script said bss")
		end
		if not d.bss then
			d.parts[#d.parts + 1] = ("\0"):rep(off - d.size)
			d.parts[#d.parts + 1] = bytes
		end
		d.size = off + e.size
		where[e] = {d = d, off = off, relocs = relocs}
	end

	-- The script's sections first: each starts at nothing, and its
	-- body says what goes in and what room lies between.
	local made = {}

	for _, st in ipairs(script and script.sections or {}) do
		if st.name and st.name ~= "/DISCARD/" and st.body then
			local d = outsec({name = st.name,
				bss = st.name:match("^%.bss") ~= nil,
				perm = st.name:match("^%.text") and 5 or
					(st.name:match("^%.rodata") and 4 or 6)})
			local env = {dot = 0, sym = {}, secaddr = {},
				     headers = 0}
			local fill = st.fill and
				string.pack(">I4", st.fill(env) & 0xffffffff)
				or "\0\0\0\0"

			if st.secalign then
				d.align = math.max(d.align, st.secalign(env))
			end
			-- Room up to `to`, filled with the pattern.
			local function pad(to)
				if to < d.size then
					error(st.name .. ": the location " ..
						"counter moves backward")
				end
				if not d.bss then
					local n = to - d.size
					local k = d.size % 4
					local run = fill:sub(k + 1) ..
						fill:rep(n // 4 + 2)

					d.parts[#d.parts + 1] = run:sub(1, n)
				end
				d.size = to
			end
			for _, it in ipairs(st.body) do
				env.dot = d.size
				if it.data then
					local v = it.e(env)

					if d.bss then
						error(st.name .. ": data in bss")
					end
					d.parts[#d.parts + 1] = string.pack(
						"<i" .. it.data,
						v >= 1 << (it.data * 8 - 1) and
						v - (1 << (it.data * 8)) or v)
					d.size = d.size + it.data
				elseif it.dot then
					pad(it.dot(env))
				elseif it.set then
					made[#made + 1] = {name = it.set,
						d = d, off = it.e(env),
						weak = it.weak}
				elseif it.pats then
					for _, u in ipairs(units) do
						local file = (u.label or
							u.path):gsub(".*/", "")

						for _, e in ipairs(u.order) do
							local hit = false

							for _, pat in ipairs(
							    it.pats) do
								if ldmatch(pat,
								   e.name) then
									hit = true
								end
							end
							if not where[e] and hit and
							   (it.from == "*" or
							    it.from == file) then
								place(d, u, e)
							end
						end
					end
				end
			end
		end
	end

	for i in ipairs(units) do
		local u = units[i]
		local path = u.label or u.path

		-- The bytes, each input section at its own alignment,
		-- where the script did not already put it.  The system
		-- call sites go through as this linker's own list, below.
		for _, e in ipairs(u.order) do
			if not where[e] and e.name ~= ".openbsd.syscalls" and
			   not e.common then
				place(outsec(e), u, e)
			end
		end
		local at = where

		-- Where each system call instruction went.  OpenBSD's
		-- libc build runs every stub through ld -r, and a static
		-- program without the list has every call refused.
		for _, e in ipairs(u.order) do
			local w = at[e]

			for _, c in ipairs(w and syscallsof(u, e) or {}) do
				w.d.syscalls = w.d.syscalls or {}
				w.d.syscalls[#w.d.syscalls + 1] = {
					off = w.off + c.off, sysno = c.sysno}
			end
		end

		-- The names, and what each is called from here on.
		local rename = {}

		for nm, sy in pairs(u.syms) do
			local where = at[sy.sec]
			local new = nm

			-- A common symbol stays common, the largest of
			-- several, unless something here defines it.
			if sy.common then
				local have = a.syms[nm]

				rename[nm] = nm
				if have and have.common then
					have.common.size = math.max(
						have.common.size, sy.size)
					have.common.align = math.max(
						have.common.align, sy.sec.align)
				elseif not have or not (have.sec or have.abs) then
					a.syms[nm] = {common = {size = sy.size,
						align = sy.sec.align},
						styp = sy.styp, vis = sy.vis,
						global = true}
				end
				goto nextsym
			end
			if not sy.global then
				if a.syms[nm] then new = nm .. "." .. i end
			else
				local have = a.syms[nm]

				if have and have.common then have = nil end
				if have and have.sec then
					if have.weak and not sy.weak then
						have = nil
					elseif not sy.weak then
						error(("%s: %s is defined " ..
							"twice"):format(path,
							nm))
					end
				end
				if have and have.sec then goto nextsym end
			end
			rename[nm] = new
			if sy.abs then
				-- an absolute name stays absolute
				a.syms[new] = {abs = sy.off, size = sy.size,
					       styp = sy.styp, vis = sy.vis,
					       weak = sy.weak or nil,
					       global = sy.global or nil}
				goto nextsym
			end
			a.syms[new] = {sec = where.d,
				       off = where.off + (sy.off or 0),
				       size = sy.size, styp = sy.styp,
				       weak = sy.weak or nil, vis = sy.vis,
				       global = sy.global or nil}
			::nextsym::
		end
		for nm in pairs(u.weak) do
			if not a.syms[nm] then a.syms[nm] = {weak = true} end
		end
		-- A name used here and defined elsewhere keeps what the
		-- reference said about it: hidden stays hidden.
		for nm, v in pairs(u.undefvis or {}) do
			local d = a.syms[nm]

			if not d then
				a.syms[nm] = {vis = v}
			elseif not d.sec and not d.vis then
				d.vis = v
			end
		end

		-- The relocations, moved with their section.
		for _, e in ipairs(u.order) do
			local w = at[e]

			for _, r in ipairs(w and w.relocs or {}) do
				w.d.relocs[#w.d.relocs + 1] = {
					off = w.off + r.off, kind = r.kind,
					sym = rename[r.sym] or r.sym,
					addend = r.addend}
			end
		end
	end
	-- The names the script gave a value, as global symbols of the
	-- object.  PROVIDE only gives one no object defines.
	for _, m in ipairs(made) do
		local have = a.syms[m.name]

		if not (m.weak and have and have.sec) then
			a.syms[m.name] = {sec = m.d, off = m.off, global = true}
		end
	end
	for _, d in ipairs(a.order) do
		d.bytes = table.concat(d.parts)
		d.parts = nil
	end
	-- The stack is not to be run, as every input said.
	a.order[#a.order + 1] = {name = ".note.GNU-stack", size = 0,
				 align = 1, perm = 0, relocs = {}}

	local f = assert(io.open(out, "wb"))

	f:write(elf.relocatable(a, target))
	f:close()
end

return ld
