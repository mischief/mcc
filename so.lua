-- SPDX-License-Identifier: ISC
-- Write a shared object.
--
-- What makes one different from the static image `ld.lua` writes is that
-- nothing in it may name an address until it is loaded.  Two devices carry
-- that: a table of addresses the loader fills in, which the code reaches
-- through a pc-relative load, and a stub for every function this object
-- calls but does not have, which jumps through that table.  Everything else
-- -- the symbols this object offers, the ones it wants, the list of places
-- to fix up -- goes in the dynamic section for the loader to read.
--
-- Nothing here is lazy: every address is bound before the object runs, so
-- there is no resolver to call back into and the stubs are one jump each.

local buf = require "buf"
local elf = require "elf"
local ld = require "ld"

local function header(path, light, at0)
	return elf.header(path, light, at0)
end

local function section(u, s, names)
	return elf.section(u, s, names)
end

local so = {}

local PAGE = 0x1000
local SYMSZ, RELSZ = 24, 16

local function u(v, n)
	local b = {}
	for i = 0, n - 1 do b[i + 1] = string.char(v >> (8 * i) & 255) end
	return table.concat(b)
end

local function align(v, a) return ((v + a - 1) // a) * a end

-- the hash the dynamic loader looks names up by
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

-- the pieces the loader reads ------------------------------------------

local Dyn = {}
Dyn.__index = Dyn

local function dynnew()
	return setmetatable({str = {"\0"}, strat = {[""] = 0}, len = 1,
			     syms = {{name = "", value = 0, info = 0,
				      shndx = 0}},
			     index = {}}, Dyn)
end

function Dyn:string(s)
	if self.strat[s] then return self.strat[s] end
	self.strat[s] = self.len
	self.str[#self.str + 1] = s .. "\0"
	self.len = self.len + #s + 1
	return self.strat[s]
end

function Dyn:symbol(name, info, shndx, value, size)
	if self.index[name] then return self.index[name] end
	local i = #self.syms
	self.syms[i + 1] = {name = name, info = info, shndx = shndx,
			    value = value or 0, size = size or 0}
	self.index[name] = i
	return i
end

-- linking ---------------------------------------------------------------

-- Which symbols need a slot in the table, and which need a stub.  A call
-- to something this object has goes straight there; everything else is a
-- name the loader has to find.
-- Every name any unit defines, global or not.  A name defined here is
-- never one to ask the loader for, and a section symbol another
-- compiler left behind is one of those.
local function definedhere(units)
	local out = {}

	for _, h in ipairs(units) do
		for name, sym in pairs(h.syms) do
			if sym.sec then out[name] = true end
		end
	end
	return out
end

-- Which names the loader has to look up: the ones a table entry stands
-- for, and the ones a word of data is meant to hold.  The second kind is
-- a pointer in an initializer, which needs a dynamic symbol of its own
-- even though no table entry is made for it.
local function survey(units, globals)
	local got, gotn, plt, pltn = {}, 0, {}, 0
	local absref = {}
	for _, u0 in ipairs(units) do
		local h = header(u0.path, false, u0.at0)
		for k, s in ipairs(h.order) do
			local _, relocs = section(h, s, h.symnames)
			for _, r in ipairs(relocs) do
				-- The relaxable spelling only says the
				-- linker may avoid the table.  Here it
				-- does not: a name another object may
				-- define has to stay a lookup.
				if (r.kind == "gotpcrel" or
				    r.kind == "gotpcrelx" or
				    r.kind == "rexgotpcrelx") and
				   not got[r.sym] then
					gotn = gotn + 1
					got[r.sym] = gotn
				elseif r.kind == "plt32" and
				       not globals[r.sym] and not plt[r.sym]
				then
					pltn = pltn + 1
					plt[r.sym] = pltn
					if not got[r.sym] then
						gotn = gotn + 1
						got[r.sym] = gotn
					end
				elseif r.kind == "abs64" and
				       not globals[r.sym] then
					absref[r.sym] = true
				end
			end
		end
	end
	return got, gotn, plt, pltn, absref
end

-- `jmp *slot(%rip)`, six bytes, one for every function this object calls
-- and does not have.
local function stub(slot, here)
	return "\xff\x25" .. u((slot - (here + 6)) & 0xffffffff, 4)
end

-- What each machine calls the dynamic relocations this writes, and
-- which ELF machine it is.  RELATIVE says "add the load address to
-- what is already there", which is the only one a self-contained
-- image needs.
-- The name a read object answers to, which for riscv is the machine
-- rather than the width.
local MACH = {amd64 = 62, arm64 = 183, riscv = 243, riscv64 = 243,
	      riscv32 = 243, xtensa = 94}
local DYN = {
	amd64 = {relative = 8, abs = 1, globdat = 6, jump = 7},
	arm64 = {relative = 1027, abs = 257, globdat = 1025, jump = 1026},
	riscv = {relative = 3, abs = 2, globdat = 5, jump = 5},
	riscv64 = {relative = 3, abs = 2, globdat = 5, jump = 5},
	xtensa = {relative = 2, abs = 1, globdat = 3, jump = 4},
}

function so.link(paths, w, opt)
	opt = opt or {}
	local units, secs = {}, {}
	local globals, local_, absref = {}, {}, {}
	local arch

	-- A path, or a member of an archive the caller picked out.
	for i, given in ipairs(paths) do
		local p, at0 = given, 0

		if type(given) == "table" then
			p, at0 = given.path, given.at0
		end
		local h = header(p, false, at0)

		h.path, h.at0 = p, at0
		units[i] = h
		arch = arch or h.arch
		for _, s in ipairs(h.order) do
			s.unit = h
			secs[#secs + 1] = s
			s.seq = #secs
		end
	end

	-- where every section goes: one loadable stretch, because a module
	-- is small and a second one would only buy a page of protection
	local ORDER = {[".text"] = 1, [".rodata"] = 2, [".data"] = 3,
		       [".bss"] = 5}
	-- Sections of the same name go together, in the order the files
	-- were given: .ctors and .init_array are walked from one end to
	-- the other, and the file that starts the list and the file that
	-- ends it are not the same file.
	local key = ld.arraykey

	table.sort(secs, function(x, y)
		local a, b = ORDER[x.name] or 4, ORDER[y.name] or 4

		if a ~= b then return a < b end
		if x.name ~= y.name then
			local xb, xn = key(x.name)
			local yb, yn = key(y.name)

			if xb ~= yb then return xb < yb end
			if xn ~= yn then return xn < yn end
			return x.name < y.name
		end
		return x.seq < y.seq
	end)

	local d = dynnew()
	if opt.soname then d:string(opt.soname) end
	if opt.rpath then d:string(opt.rpath) end

	-- pass one only needs the sizes, so the layout can be worked out
	-- before anything is written
	local got, gotn, plt, pltn
	do
		local seen = {}
		for _, h in ipairs(units) do
			for name, sym in pairs(h.syms) do
				if sym.global and sym.sec then
					local had = seen[name]

					-- A weak definition stands only
					-- where no strong one does, and
					-- two strong ones are a mistake.
					if had and not had.weak and
					   not sym.weak then
						error("two definitions of " ..
							name)
					end
					if not had or (had.weak and
					   not sym.weak) then
						seen[name] = sym
					end
				end
			end
		end
		globals = seen
		got, gotn, plt, pltn, absref =
			survey(units, definedhere(units))
	end

	-- addresses
	local at = 0
	-- An executable says which loader is to run it and which
	-- libraries it wants, and so needs a program header for the
	-- name of the loader.  It is position independent either way,
	-- so nothing else about the image changes.
	-- A program also carries a header naming the headers: the
	-- loader finds the rest of them through it.
	local interp = opt.interp
	-- A note tells a kernel whose program this is.  OpenBSD will not
	-- run one without it, and nothing else in the image carries it,
	-- so it is written here.
	local osnote
	if opt.osnote == "openbsd" then
		osnote = u(8, 4) .. u(4, 4) .. u(1, 4) .. "OpenBSD\0" ..
			u(0, 4)
	end
	-- three loadable groups, the dynamic table, the stack note, and
	-- for a program the two headers the loader looks for first
	local hastls, hasrand = false, false
	for _, s in ipairs(secs) do
		if s.name == ".tdata" or s.name == ".tbss" then
			hastls = true
		elseif s.name:match("^%.openbsd%.randomdata") then
			hasrand = true
		end
	end
	local nph = (interp and 7 or 5) + (osnote and 1 or 0) +
		(hastls and 1 or 0) + (hasrand and 1 or 0)
	local hdrs = 64 + nph * 56
	at = hdrs
	local interpat

	if interp then
		interpat = at
		at = align(at + #interp + 1, 8)
	end
	local noteat

	if osnote then
		noteat = at
		at = align(at + #osnote, 8)
	end

	local hashn = 0			-- filled in once the symbols are known
	local place = {}

	-- the tables the loader reads come first, then the code
	local function reserve(name, size, alg)
		at = align(at, alg or 8)
		place[name] = at
		at = at + size
		return place[name]
	end

	-- Names the linker itself provides.  A program has its own
	-- linker script, which defines these too and hides them; ld
	-- hands one it finds in a library to the code that hides a
	-- symbol, and that code is not ready for one that came from a
	-- library.  They are worked out here, so they need no entry in
	-- the table either way.
	local own = {_DYNAMIC = true, _GLOBAL_OFFSET_TABLE_ = true,
		     __ehdr_start = true}

	for _, base in ipairs{"init_array", "fini_array",
			      "preinit_array"} do
		own["__" .. base .. "_start"] = true
		own["__" .. base .. "_end"] = true
	end
	-- symbols: everything this object wants, and everything it offers
	local defined = definedhere(units)
	local wants = {}
	for name in pairs(plt) do
		if not own[name] then wants[#wants + 1] = name end
	end
	for name in pairs(got) do
		if not defined[name] and not own[name] then
			wants[#wants + 1] = name
		end
	end
	-- A pointer in an initializer names the loader's own lookup too.
	for name in pairs(absref) do
		if not defined[name] and not plt[name] and not got[name] and
		   not own[name] then
			wants[#wants + 1] = name
		end
	end
	table.sort(wants)
	local weak = {}
	for _, h in ipairs(units) do
		for nm in pairs(h.weak or {}) do weak[nm] = true end
	end
	for _, name in ipairs(wants) do
		-- A weak name stands for nothing when the loader cannot
		-- find it, rather than stopping the program.
		d:symbol(name, weak[name] and 0x20 or 0x10, 0)
	end
	-- Which version of each name a library offers by default.  glibc
	-- keeps more than one definition of a few names: `realpath` is
	-- the one a program wants and also a compat stub that fails on
	-- an argument the old one did not take.  A reference that asks
	-- for no version may be bound to either, so this says which.
	local verneed, nverfile = {}, 0
	do
		local libs = {}

		for _, path in ipairs(opt.libpaths or {}) do
			local vs, nm = elf.defversions(path)

			if vs then
				libs[#libs + 1] = {ver = vs,
					name = nm or path:gsub(".*/", "")}
			end
		end
		local seen, nextidx = {}, 2

		for _, sym in ipairs(d.syms) do
			if sym.name ~= "" and sym.shndx == 0 then
				for _, lib in ipairs(libs) do
					local v = lib.ver[sym.name]

					if v then
						local key = lib.name .. v
						local e = seen[key]

						if not e then
							e = {file = lib.name,
							     ver = v,
							     idx = nextidx}
							nextidx = nextidx + 1
							seen[key] = e
							verneed[#verneed + 1]
								= e
						end
						sym.vernum = e.idx
						break
					end
				end
			end
		end
		-- The names go in the same table the symbols use, and the
		-- entries are grouped by the file they come from.
		local byfile, order = {}, {}

		for _, e in ipairs(verneed) do
			d:string(e.file)
			d:string(e.ver)
			if not byfile[e.file] then
				byfile[e.file] = {}
				order[#order + 1] = e.file
			end
			local g = byfile[e.file]

			g[#g + 1] = e
		end
		verneed = {}
		for _, f in ipairs(order) do
			nverfile = nverfile + 1
			verneed[#verneed + 1] = {file = f, aux = byfile[f]}
		end
	end
	local offers = {}
	for name in pairs(globals) do
		if not own[name] then offers[#offers + 1] = name end
	end
	table.sort(offers)

	-- sizes that do not depend on addresses
	local nsym = #d.syms + #offers
	hashn = nsym
	local hashsz = 4 * (2 + hashn + nsym)
	local nrela = gotn			-- one per table slot
	for _, h in ipairs(units) do
		for _, s in ipairs(h.order) do
			local _, relocs = section(h, s, h.symnames)
			for _, r in ipairs(relocs) do
				if r.kind == "abs64" then
					nrela = nrela + 1
				end
			end
		end
	end

	-- Three groups, by what may be done with them: read, read and
	-- run, read and write.  A system that will not map a page both
	-- writable and executable needs them apart, and a page is the
	-- smallest thing it can tell apart.  The address equals the file
	-- offset here, so a page boundary in one is a page boundary in
	-- the other.
	local segs = {{perm = 4}, {perm = 5}, {perm = 6}}

	local function startseg(g)
		at = align(at, PAGE)
		g.addr = at
	end

	local function endseg(g)
		g.filesz = at - g.addr
		g.memsz = g.filesz
	end

	startseg(segs[1])
	segs[1].addr = 0		-- the headers are read only too
	reserve(".hash", hashsz, 8)
	reserve(".dynsym", nsym * SYMSZ, 8)
	-- .dynstr holds every name the table below will hold, so its size
	-- is known here even though its bytes are not.
	local strsz = d.len
	for _, sym in ipairs(d.syms) do
		if not d.strat[sym.name] then strsz = strsz + #sym.name + 1 end
	end
	for _, name in ipairs(offers) do strsz = strsz + #name + 1 end
	for _, nm in ipairs(opt.needed or {}) do strsz = strsz + #nm + 1 end
	local strplace = at
	at = align(at + strsz, 8)
	if nverfile > 0 then
		local sz = 0

		for _, v in ipairs(verneed) do
			sz = sz + 16 + 16 * #v.aux
		end
		reserve(".gnu.version", nsym * 2, 2)
		reserve(".gnu.version_r", sz, 8)
	end
	reserve(".rela.dyn", nrela * 24, 8)
	for _, s in ipairs(secs) do
		if not s.bss and (s.perm or 6) == 4 then
			at = align(at, math.max(s.align, 1))
			s.addr = at
			at = at + s.size
		end
	end
	endseg(segs[1])

	startseg(segs[2])
	reserve(".plt", pltn * 6, 16)
	-- .init and .fini each come in pieces, one from crtbeginS.o and
	-- one from crtendS.o, that make one function between them, so each
	-- is laid out whole before the rest of the code.
	for _, nm in ipairs{".init", ".fini", false} do
		for _, s in ipairs(secs) do
			if not s.bss and (s.perm or 6) & 1 ~= 0 and
			   s.addr == nil and (not nm or s.name == nm) then
				at = align(at, math.max(s.align, 1))
				s.addr = at
				at = at + s.size
			end
		end
	end
	endseg(segs[2])

	startseg(segs[3])
	-- A thread's own block goes first and in one piece: the loader
	-- copies it whole for each thread, and the offsets the code
	-- carries are measured from its end.  Here an address is a file
	-- offset, so the zero-filled half takes room in the file too.
	local tlsat, tlssz, tlsalign, tlsfile = nil, 0, 1, 0
	for _, s in ipairs(secs) do
		if s.name == ".tdata" or s.name == ".tbss" then
			tlsalign = math.max(tlsalign, s.align or 1)
		end
	end
	for _, nm in ipairs{".tdata", ".tbss"} do
		for _, s in ipairs(secs) do
			if s.name == nm then
				at = align(at, math.max(s.align, 1))
				if not tlsat then
					at = align(at, tlsalign)
					tlsat = at
				end
				s.addr = at
				s.bss = false
				at = at + s.size
				if nm == ".tdata" then
					tlsfile = at - tlsat
				end
			end
		end
	end
	if tlsat then tlssz = at - tlsat end
	-- OpenBSD's loader fills this range with random bytes: the stack
	-- protector's guard and the retguard cookies.  It has to be one
	-- piece, so it is placed before the rest of the data.
	local randat, randsz
	for _, s in ipairs(secs) do
		if s.name:match("^%.openbsd%.randomdata") and s.addr == nil then
			at = align(at, math.max(s.align, 1))
			randat = randat or at
			s.addr = at
			s.bss = false
			at = at + s.size
		end
	end
	if randat then randsz = at - randat end
	for _, s in ipairs(secs) do
		if not s.bss and s.addr == nil then
			at = align(at, math.max(s.align, 1))
			s.addr = at
			at = at + s.size
		end
	end
	reserve(".got", gotn * 8, 8)
	-- One entry per library wanted, one for the name, the fixed ones
	-- below, and the three pairs that say where the constructor and
	-- destructor arrays are.
	local dynmax = #(opt.needed or {}) + 24

	reserve(".dynamic", dynmax * 16, 8)
	local filesz = at
	segs[3].filesz = at - segs[3].addr
	for _, s in ipairs(secs) do
		if s.bss then
			at = align(at, math.max(s.align, 1))
			s.addr = at
			at = at + s.size
		end
	end
	segs[3].memsz = at - segs[3].addr
	local memsz = at

	-- now the symbols have addresses
	for _, h in ipairs(units) do
		h.addrs = {}
		for name, sym in pairs(h.syms) do
			if sym.sec then
				h.addrs[name] = sym.sec.addr + sym.off
			end
		end
	end
	local value = {}
	for _, h in ipairs(units) do
		for name, a in pairs(h.addrs) do
			local sym = h.syms[name]

			-- The definition that wins is the one the survey
			-- above settled on, so a weak one does not take
			-- the address a strong one has.
			if sym.global and (globals[name] == nil or
			   globals[name] == sym) then
				value[name] = a
			end
		end
	end
	-- A local name is known here too, so long as only one unit has
	-- it; the relocation loop reaches its own unit's first anyway.
	for _, h in ipairs(units) do
		for name, a in pairs(h.addrs) do
			if value[name] == nil then value[name] = a end
		end
	end
	-- The names the linker itself answers for: the ends of the
	-- arrays of pointers run before and after main, and the ends of
	-- the image.  A startup file expects them and no object has them.
	do
		local span = {}

		for _, sec in ipairs(secs) do
			local base = sec.name:match("^(%.%a+_array)")

			if base then
				local e = span[base] or
					{lo = sec.addr, hi = sec.addr}

				span[base] = e
				if sec.addr < e.lo then e.lo = sec.addr end
				if sec.addr + sec.size > e.hi then
					e.hi = sec.addr + sec.size
				end
			end
		end
		for _, base in ipairs{".init_array", ".fini_array",
				      ".preinit_array"} do
			local e = span[base] or {lo = at, hi = at}
			local nm = "__" .. base:sub(2)

			value[nm .. "_start"] = e.lo
			value[nm .. "_end"] = e.hi
		end
		-- Where the loader's own table is, which a startup file
		-- reads to find what it was loaded at before anything
		-- else has run.  musl's does; glibc's does not.
		value._DYNAMIC = place[".dynamic"]
		value._GLOBAL_OFFSET_TABLE_ = place[".got"]
		value.__ehdr_start = 0
	end
	for _, name in ipairs(offers) do
		local def = globals[name]
		local bind = (def and def.weak) and 2 or 1
		local styp = (def and def.styp) or 2	-- STT_FUNC

		d:symbol(name, bind << 4 | styp, 1, value[name],
			def and def.size)
	end

	-- A program has to have every name it reaches, either here or in
	-- a library it says it needs.  Without this the name goes out as
	-- one for the loader to find, the link says nothing, and the
	-- program dies at start-up instead.  A shared object is another
	-- matter: it may leave a name to whatever loads it.
	if not opt.soname then
		local offered = {}

		for _, path in ipairs(opt.libpaths or {}) do
			for nm in pairs(elf.defines(path) or {}) do
				offered[nm] = true
			end
		end
		local missing, said = {}, {}

		for _, name in ipairs(wants) do
			if not weak[name] and not offered[name] and
			   value[name] == nil and not said[name] then
				said[name] = true
				missing[#missing + 1] = name
			end
		end
		if #missing > 0 then
			error("undefined symbol " ..
				table.concat(missing, ", "), 0)
		end
	end

	local gotat = place[".got"]
	local pltat = place[".plt"]
	local function gotslot(sym) return gotat + (got[sym] - 1) * 8 end
	local function pltslot(sym) return pltat + (plt[sym] - 1) * 6 end

	-- the fixups the loader has to make
	local rela = buf.new()
	local nemit = 0
	local dyn = DYN[arch] or DYN.amd64
	local function reloc(off, sym, kind, addend)
		if not sym then
			error("no dynamic symbol for a relocation", 0)
		end
		rela:add(u(off, 8))
		rela:add(u((sym << 32) | kind, 8))
		rela:add(u(addend or 0, 8))
		nemit = nemit + 1
	end
	local gotbytes = {}
	for name, i in pairs(got) do
		local slot = gotat + (i - 1) * 8
		if value[name] then
			gotbytes[i] = value[name]
			reloc(slot, 0, dyn.relative, value[name])
		else
			gotbytes[i] = 0
			reloc(slot, d.index[name], dyn.globdat, 0)
		end
	end

	-- the code, with every reference filled in
	local out = {}
	for _, s in ipairs(secs) do
		if s.bss then goto next end
		do
			local h = s.unit
			local bytes, relocs = section(h, s, h.symnames)
			local pieces, from = buf.new(), 0
			-- Where each auipc stood, which the low half of
			-- a pc-relative pair is measured from.
			local hi = {}

			table.sort(relocs,
				function(x, y) return x.off < y.off end)
			for _, r in ipairs(relocs) do
				local here = s.addr + r.off
				local n, text = 4
				-- A name another unit may also define is
				-- resolved to the definition that won, not
				-- to this unit's own: a weak one here
				-- loses to a strong one there.
				local own = h.syms[r.sym]
				local target = (own and own.global and
					value[r.sym]) or h.addrs[r.sym] or
					value[r.sym]
				if r.kind == "pc32" then
					if not target then
						-- Either nothing defines
						-- it, or it was reached
						-- pc-relative from an object
						-- built for a fixed address,
						-- which no loader can fix up.
						error("undefined " .. r.sym ..
							": define it, or " ..
							"build with -fpic to " ..
							"reach it through " ..
							"the table", 0)
					end
					text = u((target + r.addend - here) &
						0xffffffff, 4)
				elseif r.kind == "plt32" then
					local to = defined[r.sym] and target or
						pltslot(r.sym)
					text = u((to + r.addend - here) &
						0xffffffff, 4)
				elseif r.kind == "gotpcrel" or
				    r.kind == "gotpcrelx" or
				    r.kind == "rexgotpcrelx" then
					text = u((gotslot(r.sym) + r.addend -
						here) & 0xffffffff, 4)
				elseif r.kind == "abs64" then
					n = 8
					if target then
						reloc(here, 0,
							dyn.relative,
							target + r.addend)
						text = u(target + r.addend, 8)
					else
						if not d.index[r.sym] then
							error("undefined " ..
								r.sym, 0)
						end
						reloc(here,
							d.index[r.sym],
							dyn.abs, r.addend)
						text = u(0, 8)
					end
				elseif r.kind == "abs32" then
					if not target then
						error("undefined " .. r.sym ..
							": define it, or " ..
							"build with -fpic to " ..
							"reach it through " ..
							"the table", 0)
					end
					text = u((target + r.addend) &
						0xffffffff, 4)
				elseif r.kind == "tpoff32" then
					-- The thread pointer sits past the
					-- end of the block, so an object in
					-- it is at a negative offset.
					if not target or not tlsat then
						error("undefined " .. r.sym)
					end
					local end_ = tlsat +
						align(tlssz, tlsalign)

					text = u((target - end_ + r.addend) &
						0xffffffff, 4)
				else
					-- Everything the machine's own
					-- linker knows how to fill in.
					-- Nothing here is interposed --
					-- a shared object this compiler
					-- writes is one image -- so the
					-- answer is worked out and, when
					-- it is an address, written down
					-- for the loader to move.
					if not target then
						error("undefined " .. r.sym)
					end
					local abs

					text, n, abs = ld.fill(bytes, r,
						target + r.addend, here, hi)
					if abs then
						reloc(here, 0, dyn.relative,
							target + r.addend)
					end
				end
				pieces:add(bytes:sub(from + 1, r.off))
				pieces:add(text)
				from = r.off + n
			end
			pieces:add(bytes:sub(from + 1))
			out[#out + 1] = {addr = s.addr, text = pieces:text(), name = s.name .. "/" .. (s.unit.path:gsub(".*/", ""))}
		end
		::next::
	end

	-- the stubs
	do
		local b = buf.new()
		local names = {}
		for name, i in pairs(plt) do names[i] = name end
		for i = 1, pltn do
			b:add(stub(gotslot(names[i]), pltat + (i - 1) * 6))
		end
		out[#out + 1] = {addr = pltat, text = b:text(), name = ".plt"}
	end

	-- the table itself
	do
		local b = buf.new()
		for i = 1, gotn do b:add(u(gotbytes[i] or 0, 8)) end
		out[#out + 1] = {addr = gotat, text = b:text(), name = ".got"}
	end

	-- the symbol table and its hash
	local strtab
	do
		local b = buf.new()
		for _, sym in ipairs(d.syms) do
			b:add(u(d:string(sym.name), 4))
			b:add(string.char(sym.info, 0))
			b:add(u(sym.shndx, 2))
			b:add(u(sym.value, 8))
			b:add(u(sym.size or 0, 8))
		end
		out[#out + 1] = {addr = place[".dynsym"], text = b:text(), name = ".dynsym"}
		-- The names of the libraries wanted go in the same table.
		for _, nm in ipairs(opt.needed or {}) do d:string(nm) end
		strtab = table.concat(d.str)
		if #strtab > strsz then
			error("the name table grew past what was reserved")
		end
		out[#out + 1] = {addr = strplace, text = strtab, name = ".dynstr"}

		local nb = 1
		while nb * 4 < nsym do nb = nb * 2 end
		local bucket, chain = {}, {}
		for i = 0, nb - 1 do bucket[i] = 0 end
		for i = 1, nsym - 1 do chain[i] = 0 end
		for i = nsym - 1, 1, -1 do
			local k = elfhash(d.syms[i + 1].name) % nb
			chain[i] = bucket[k]
			bucket[k] = i
		end
		local h = buf.new()
		h:add(u(nb, 4))
		h:add(u(nsym, 4))
		for i = 0, nb - 1 do h:add(u(bucket[i], 4)) end
		h:add(u(0, 4))
		for i = 1, nsym - 1 do h:add(u(chain[i], 4)) end
		out[#out + 1] = {addr = place[".hash"], text = h:text(), name = ".hash"}
	end

	-- Which version each name in the table above asks for, and where
	-- each of those versions comes from.
	if nverfile > 0 then
		local v = buf.new()

		for i, sym in ipairs(d.syms) do
			-- 0 names the null entry, 1 is the object's own
			v:add(u(i == 1 and 0 or (sym.vernum or 1), 2))
		end
		out[#out + 1] = {addr = place[".gnu.version"],
				 text = v:text(), name = ".gnu.version"}

		local r = buf.new()

		for i, need in ipairs(verneed) do
			local last = i == #verneed

			r:add(u(1, 2))			-- vn_version
			r:add(u(#need.aux, 2))		-- vn_cnt
			r:add(u(d.strat[need.file], 4))	-- vn_file
			r:add(u(16, 4))			-- vn_aux
			r:add(u(last and 0 or (16 + 16 * #need.aux), 4))
			for k, e in ipairs(need.aux) do
				r:add(u(elfhash(e.ver), 4))
				r:add(u(0, 2))		-- vna_flags
				r:add(u(e.idx, 2))	-- vna_other
				r:add(u(d.strat[e.ver], 4))
				r:add(u(k == #need.aux and 0 or 16, 4))
			end
		end
		out[#out + 1] = {addr = place[".gnu.version_r"],
				 text = r:text(), name = ".gnu.version_r"}
	end

	out[#out + 1] = {addr = place[".rela.dyn"], text = rela:text(), name = ".rela.dyn"}

	if osnote then
		out[#out + 1] = {addr = noteat, text = osnote,
				 name = ".note.openbsd.ident"}
	end
	-- the name of the loader, which the header points at
	if interp then
		out[#out + 1] = {addr = interpat, text = interp .. "\0",
				 name = ".interp"}
	end
	-- where the program starts, when it is one
	local entry
	if opt.entry then
		entry = value[opt.entry]
		if not entry then
			error("no entry symbol " .. opt.entry)
		end
	end

	-- what the loader is told
	local dynsz
	do
		local b = buf.new()
		local function ent(tag, val)
			b:add(u(tag, 8))
			b:add(u(val, 8))
		end
		for _, nm in ipairs(opt.needed or {}) do
			ent(1, d.strat[nm])		-- DT_NEEDED
		end
		if opt.soname then ent(14, d.strat[opt.soname]) end
		-- DT_RPATH when asked for the old kind, DT_RUNPATH otherwise.
		if opt.rpath then
			ent(opt.oldrpath and 15 or 29, d.strat[opt.rpath])
		end
		ent(4, place[".hash"])			-- DT_HASH
		ent(5, strplace)			-- DT_STRTAB
		ent(6, place[".dynsym"])		-- DT_SYMTAB
		ent(10, #strtab)			-- DT_STRSZ
		ent(11, SYMSZ)				-- DT_SYMENT
		ent(7, place[".rela.dyn"])		-- DT_RELA
		ent(8, nemit * 24)			-- DT_RELASZ
		ent(9, 24)				-- DT_RELAENT
		if nverfile > 0 then
			ent(0x6ffffff0, place[".gnu.version"])
			ent(0x6ffffffe, place[".gnu.version_r"])
			ent(0x6fffffff, nverfile)
		end
		-- The arrays of functions to run before main and after
		-- it.  A dynamic program's start-up code leaves them to
		-- the loader, which finds them only through these: without
		-- them no constructor runs.  preinit belongs to a program
		-- alone.
		for _, a in ipairs{{"init_array", 25, 27},
				   {"fini_array", 26, 28},
				   {"preinit_array", 32, 33}} do
			local lo = value["__" .. a[1] .. "_start"]
			local hi = value["__" .. a[1] .. "_end"]

			if lo and hi and hi > lo and
			   (a[1] ~= "preinit_array" or interp) then
				ent(a[2], lo)
				ent(a[3], hi - lo)
			end
		end
		-- A shared library's _init and _fini, from crtbeginS.o: the
		-- loader runs _fini at dlclose, and that is what runs the
		-- library's own destructors before it goes away.
		if not interp and value._init then ent(12, value._init) end
		if not interp and value._fini then ent(13, value._fini) end
		ent(30, 8)				-- DT_FLAGS: BIND_NOW
		if interp then
			-- A program says it is position independent and
			-- leaves the loader somewhere to write the list
			-- of what it loaded.
			ent(0x6ffffffb, 1 | 0x08000000)	-- NOW | PIE
			ent(21, 0)			-- DT_DEBUG
		else
			ent(0x6ffffffb, 1)		-- DT_FLAGS_1: NOW
		end
		ent(0, 0)				-- DT_NULL
		out[#out + 1] = {addr = place[".dynamic"], text = b:text(),
			name = ".dynamic"}
		dynsz = #b:text()
		if dynsz > dynmax * 16 then
			error(("the dynamic table is %d entries, room for %d")
				:format(dynsz // 16, dynmax))
		end
	end

	-- A segment must not claim more of the file than is there: space
	-- reserved and left unfilled is not in the file at all, and a
	-- kernel that reads the headers literally refuses the image.
	for _, g in ipairs(segs) do
		local last = g.addr

		for _, piece in ipairs(out) do
			local e = piece.addr + #piece.text

			if piece.addr >= g.addr and
			   piece.addr < g.addr + g.memsz and e > last then
				last = e
			end
		end
		if last - g.addr < g.filesz then
			g.filesz = last - g.addr
		end
		if g.memsz < g.filesz then g.memsz = g.filesz end
	end

	-- the file
	local img = buf.new()
	img:add("\127ELF")
	img:add(string.char(2, 1, 1, 0))
	img:add(string.rep("\0", 8))
	img:add(u(3, 2))				-- ET_DYN
	img:add(u(MACH[arch] or 62, 2))			-- the machine
	img:add(u(1, 4))
	img:add(u(entry or 0, 8))
	img:add(u(64, 8))				-- phoff
	img:add(u(0, 8))
	img:add(u(0, 4))
	img:add(u(64, 2))
	img:add(u(56, 2))
	img:add(u(nph, 2))
	img:add(u(64, 2))
	img:add(u(0, 2))
	img:add(u(0, 2))

	local function phdr(kind, flags, off, addr, fsz, msz, alg)
		img:add(u(kind, 4))
		img:add(u(flags, 4))
		img:add(u(off, 8))
		img:add(u(addr, 8))
		img:add(u(addr, 8))
		img:add(u(fsz, 8))
		img:add(u(msz, 8))
		img:add(u(alg, 8))
	end
	if interp then
		phdr(6, 4, 64, 64, nph * 56, nph * 56, 8)	-- PT_PHDR
		phdr(3, 4, interpat, interpat, #interp + 1, #interp + 1, 1)
	end
	for _, g in ipairs(segs) do
		if g.filesz > 0 or g.memsz > 0 then
			phdr(1, g.perm, g.addr, g.addr, g.filesz,
				g.memsz, PAGE)
		end
	end
	if tlsat then
		-- Only the initialized half is in the file; the loader
		-- zeroes the rest for every thread.
		phdr(7, 4, tlsat, tlsat, tlsfile, tlssz, tlsalign)
	end
	phdr(2, 6, place[".dynamic"], place[".dynamic"], dynsz, dynsz, 8)
	phdr(0x6474e551, 6, 0, 0, 0, 0, 16)		-- PT_GNU_STACK
	if osnote then
		phdr(4, 4, noteat, noteat, #osnote, #osnote, 4)
	end
	if randat then
		phdr(0x65a3dbe6, 6, randat, randat, randsz, randsz, 8)
	end

	-- an empty section has an address like any other and would sort
	-- among the pieces that are really there
	for i = #out, 1, -1 do
		if #out[i].text == 0 then table.remove(out, i) end
	end
	table.sort(out, function(x, y) return x.addr < y.addr end)
	if opt.map then
		for _, piece in ipairs(out) do
			opt.map(("%8x %8d  %s"):format(piece.addr,
				#piece.text, piece.name or "?"))
		end
	end
	local pos = hdrs
	for _, piece in ipairs(out) do
		if piece.addr < pos then
			error(("pieces overlap at %d, already at %d")
				:format(piece.addr, pos))
		end
		img:add(string.rep("\0", piece.addr - pos))
		img:add(piece.text)
		pos = piece.addr + #piece.text
	end

	-- Section headers.  Nothing that runs the image reads them; every
	-- tool that looks at one does.
	local SHT = {[".dynsym"] = 11, [".dynstr"] = 3, [".hash"] = 5,
		     [".rela.dyn"] = 4, [".dynamic"] = 6,
		     [".gnu.version"] = 0x6fffffff,
		     [".gnu.version_r"] = 0x6ffffffe,
		     [".note.openbsd.ident"] = 7, [".shstrtab"] = 3}
	local ENT = {[".dynsym"] = SYMSZ, [".rela.dyn"] = 24,
		     [".dynamic"] = 16, [".hash"] = 4,
		     [".gnu.version"] = 2}
	local shstr, shnames = {"\0"}, {[""] = 0}
	local shlen = 1

	local function shname(nm)
		if shnames[nm] then return shnames[nm] end
		shnames[nm] = shlen
		shstr[#shstr + 1] = nm .. "\0"
		shlen = shlen + #nm + 1
		return shnames[nm]
	end

	local shdr = {{name = "", typ = 0, flags = 0, addr = 0, off = 0,
		       size = 0, link = 0, info = 0, align = 0, ent = 0}}
	local shidx = {}

	for _, piece in ipairs(out) do
		-- A piece is named for the section it came from and the
		-- object it came out of.  What goes in the table is the
		-- section: a library built from a thousand objects would
		-- otherwise have a thousand headers, and a linker
		-- reading one falls over in its own string table.
		local nm = (piece.name or ".text"):gsub("/.*$", "")
		local flags = 2			-- SHF_ALLOC
		local perm = 6

		for _, g in ipairs(segs) do
			if piece.addr >= g.addr and
			   piece.addr < g.addr + g.memsz then
				perm = g.perm
			end
		end
		if perm & 2 ~= 0 then flags = flags | 1 end
		if perm & 1 ~= 0 then flags = flags | 4 end
		local last = shdr[#shdr]

		if last and last.name == nm and last.flags == flags and
		   piece.addr >= last.addr + last.size then
			last.size = piece.addr + #piece.text - last.addr
		else
			shdr[#shdr + 1] = {name = nm, typ = SHT[nm] or 1,
					   flags = flags, addr = piece.addr,
					   off = piece.addr,
					   size = #piece.text,
					   link = 0, info = 0, align = 8,
					   ent = ENT[nm] or 0}
			shidx[nm] = #shdr - 1
		end
	end
	for _, sec in ipairs(secs) do
		if sec.bss then
			shdr[#shdr + 1] = {name = sec.name, typ = 8,
					   flags = 3, addr = sec.addr,
					   off = pos, size = sec.size,
					   link = 0, info = 0, align = 8,
					   ent = 0}
		end
	end
	-- Every name this image knows, so that a debugger can say where
	-- it stopped.  The loader reads .dynsym; this is for people.
	local names = {}

	for name in pairs(value) do names[#names + 1] = name end
	table.sort(names)
	local symtxt = {u(0, 24)}
	local strtxt, strat, strlen = {"\0"}, {}, 1

	for _, name in ipairs(names) do
		strat[name] = strlen
		strtxt[#strtxt + 1] = name .. "\0"
		strlen = strlen + #name + 1
		local a = value[name]
		local where = 0

		for i = 2, #shdr do
			if shdr[i].addr <= a and
			   a < shdr[i].addr + shdr[i].size then
				where = i - 1
			end
		end
		symtxt[#symtxt + 1] = u(strat[name], 4) ..
			string.char(0x12, 0) .. u(where, 2) ..
			u(a, 8) .. u(0, 8)
	end
	symtxt = table.concat(symtxt)
	strtxt = table.concat(strtxt)
	shdr[#shdr + 1] = {name = ".symtab", typ = 2, flags = 0, addr = 0,
			   off = 0, size = #symtxt, link = 0, info = 1,
			   align = 8, ent = SYMSZ}
	local symsec = #shdr

	shdr[#shdr + 1] = {name = ".strtab", typ = 3, flags = 0, addr = 0,
			   off = 0, size = #strtxt, link = 0, info = 0,
			   align = 1, ent = 0}
	local stabsec = #shdr

	shdr[symsec].link = stabsec - 1
	shdr[#shdr + 1] = {name = ".shstrtab", typ = 3, flags = 0,
			   addr = 0, off = 0, size = 0, link = 0,
			   info = 0, align = 1, ent = 0}
	local strsec = #shdr

	for _, h in ipairs(shdr) do h.nameoff = shname(h.name) end
	shstr = table.concat(shstr)
	shdr[strsec].size = #shstr
	-- the tables that are not mapped land after everything else
	local pad0 = (-pos) % 8

	img:add(string.rep("\0", pad0))
	pos = pos + pad0
	shdr[symsec].off = pos
	img:add(symtxt)
	pos = pos + #symtxt
	shdr[stabsec].off = pos
	img:add(strtxt)
	pos = pos + #strtxt
	shdr[strsec].off = pos
	img:add(shstr)
	pos = pos + #shstr
	-- .dynsym names live in .dynstr, and the relocations name .dynsym
	if shidx[".dynsym"] then
		shdr[shidx[".dynsym"] + 1].link = shidx[".dynstr"] or 0
		shdr[shidx[".dynsym"] + 1].info = 1
	end
	if shidx[".rela.dyn"] then
		shdr[shidx[".rela.dyn"] + 1].link = shidx[".dynsym"] or 0
	end
	if shidx[".hash"] then
		shdr[shidx[".hash"] + 1].link = shidx[".dynsym"] or 0
	end
	if shidx[".dynamic"] then
		shdr[shidx[".dynamic"] + 1].link = shidx[".dynstr"] or 0
	end
	-- The version tables name the symbol table and the string table,
	-- and the count of files goes in the header rather than beside it.
	if shidx[".gnu.version"] then
		shdr[shidx[".gnu.version"] + 1].link = shidx[".dynsym"] or 0
	end
	if shidx[".gnu.version_r"] then
		local h = shdr[shidx[".gnu.version_r"] + 1]

		h.link = shidx[".dynstr"] or 0
		h.info = nverfile
	end
	local pad = (-pos) % 8

	img:add(string.rep("\0", pad))
	pos = pos + pad
	local shoff = pos

	for _, h in ipairs(shdr) do
		img:add(u(h.nameoff, 4))
		img:add(u(h.typ, 4))
		img:add(u(h.flags, 8))
		img:add(u(h.addr, 8))
		img:add(u(h.off, 8))
		img:add(u(h.size, 8))
		img:add(u(h.link, 4))
		img:add(u(h.info, 4))
		img:add(u(h.align, 8))
		img:add(u(h.ent, 8))
	end
	local text = img:text()
	-- the header said nothing about them until now
	text = text:sub(1, 40) .. u(shoff, 8) .. text:sub(49, 58) ..
		u(64, 2) .. u(#shdr, 2) .. u(strsec - 1, 2) ..
		text:sub(65)
	w:write(text)
end

return so
