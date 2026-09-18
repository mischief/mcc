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
local obj = require "obj"
local elf = require "elf"

-- Either object format goes in; which one a file is is a question
-- about its first four bytes.
local function header(path, light, at0)
	local r = elf.is(path, at0) and elf or obj

	return r.header(path, light, at0)
end

local function section(u, s, names)
	return (u.elf and elf or obj).section(u, s, names)
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

function Dyn:symbol(name, info, shndx, value)
	if self.index[name] then return self.index[name] end
	local i = #self.syms
	self.syms[i + 1] = {name = name, info = info, shndx = shndx,
			    value = value or 0}
	self.index[name] = i
	return i
end

-- linking ---------------------------------------------------------------

-- Which symbols need a slot in the table, and which need a stub.  A call
-- to something this object has goes straight there; everything else is a
-- name the loader has to find.
local function survey(units, globals)
	local got, gotn, plt, pltn = {}, 0, {}, 0
	for _, u0 in ipairs(units) do
		local h = header(u0.path)
		for k, s in ipairs(h.order) do
			local _, relocs = section(h, s, h.symnames)
			for _, r in ipairs(relocs) do
				if r.kind == "gotpcrel" and not got[r.sym] then
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
				end
			end
		end
	end
	return got, gotn, plt, pltn
end

-- `jmp *slot(%rip)`, six bytes, one for every function this object calls
-- and does not have.
local function stub(slot, here)
	return "\xff\x25" .. u((slot - (here + 6)) & 0xffffffff, 4)
end

function so.link(paths, w, opt)
	opt = opt or {}
	local units, secs = {}, {}
	local globals, local_ = {}, {}

	for i, p in ipairs(paths) do
		local h = header(p)
		h.path = p
		units[i] = h
		for _, s in ipairs(h.order) do
			s.unit = h
			secs[#secs + 1] = s
		end
	end

	-- where every section goes: one loadable stretch, because a module
	-- is small and a second one would only buy a page of protection
	local ORDER = {[".text"] = 1, [".rodata"] = 2, [".data"] = 3,
		       [".bss"] = 5}
	table.sort(secs, function(x, y)
		return (ORDER[x.name] or 4) < (ORDER[y.name] or 4)
	end)

	local d = dynnew()
	if opt.soname then d:string(opt.soname) end

	-- pass one only needs the sizes, so the layout can be worked out
	-- before anything is written
	local got, gotn, plt, pltn
	do
		local seen = {}
		for _, h in ipairs(units) do
			for name, sym in pairs(h.syms) do
				if sym.global and sym.sec then
					if seen[name] then
						error("two definitions of " ..
							name)
					end
					seen[name] = true
				end
			end
		end
		globals = seen
		got, gotn, plt, pltn = survey(units, globals)
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
	local nph = interp and 5 or 3
	local hdrs = 64 + nph * 56
	at = hdrs
	local interpat

	if interp then
		interpat = at
		at = align(at + #interp + 1, 8)
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

	-- symbols: everything this object wants, and everything it offers
	local wants = {}
	for name in pairs(plt) do wants[#wants + 1] = name end
	for name in pairs(got) do
		if not globals[name] then wants[#wants + 1] = name end
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
	local offers = {}
	for name in pairs(globals) do offers[#offers + 1] = name end
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

	reserve(".hash", hashsz, 8)
	reserve(".dynsym", nsym * SYMSZ, 8)
	local strplace = at			-- .dynstr, sized later
	at = at + 4096				-- room for the names
	reserve(".rela.dyn", nrela * 24, 8)
	reserve(".plt", pltn * 6, 16)
	for _, s in ipairs(secs) do
		if not s.bss then
			at = align(at, math.max(s.align, 1))
			s.addr = at
			at = at + s.size
		end
	end
	reserve(".got", gotn * 8, 8)
	reserve(".dynamic", 16 * 16, 8)
	local filesz = at
	for _, s in ipairs(secs) do
		if s.bss then
			at = align(at, math.max(s.align, 1))
			s.addr = at
			at = at + s.size
		end
	end
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
			if h.syms[name].global then value[name] = a end
		end
	end
	for _, name in ipairs(offers) do
		d:symbol(name, 0x12, 1, value[name])	-- global, function
	end

	local gotat = place[".got"]
	local pltat = place[".plt"]
	local function gotslot(sym) return gotat + (got[sym] - 1) * 8 end
	local function pltslot(sym) return pltat + (plt[sym] - 1) * 6 end

	-- the fixups the loader has to make
	local rela = buf.new()
	local nemit = 0
	local function reloc(off, sym, kind, addend)
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
			reloc(slot, 0, 8, value[name])		-- RELATIVE
		else
			gotbytes[i] = 0
			reloc(slot, d.index[name], 6, 0)	-- GLOB_DAT
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

			table.sort(relocs,
				function(x, y) return x.off < y.off end)
			for _, r in ipairs(relocs) do
				local here = s.addr + r.off
				local n, text = 4
				local target = h.addrs[r.sym] or value[r.sym]
				if r.kind == "pc32" then
					if not target then
						error("undefined " .. r.sym)
					end
					text = u((target + r.addend - here) &
						0xffffffff, 4)
				elseif r.kind == "plt32" then
					local to = globals[r.sym] and target or
						pltslot(r.sym)
					text = u((to + r.addend - here) &
						0xffffffff, 4)
				elseif r.kind == "gotpcrel" then
					text = u((gotslot(r.sym) + r.addend -
						here) & 0xffffffff, 4)
				elseif r.kind == "abs64" then
					n = 8
					if target then
						reloc(here, 0, 8,
							target + r.addend)
						text = u(target + r.addend, 8)
					else
						reloc(here, d.index[r.sym], 1,
							r.addend)
						text = u(0, 8)
					end
				elseif r.kind == "abs32" then
					if not target then
						error("undefined " .. r.sym)
					end
					text = u((target + r.addend) &
						0xffffffff, 4)
				else
					error("no relocation " .. r.kind)
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
			b:add(u(0, 8))
		end
		out[#out + 1] = {addr = place[".dynsym"], text = b:text(), name = ".dynsym"}
		-- The names of the libraries wanted go in the same table.
		for _, nm in ipairs(opt.needed or {}) do d:string(nm) end
		strtab = table.concat(d.str)
		if #strtab > 4096 then error("too many names") end
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

	out[#out + 1] = {addr = place[".rela.dyn"], text = rela:text(), name = ".rela.dyn"}

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
		ent(4, place[".hash"])			-- DT_HASH
		ent(5, strplace)			-- DT_STRTAB
		ent(6, place[".dynsym"])		-- DT_SYMTAB
		ent(10, #strtab)			-- DT_STRSZ
		ent(11, SYMSZ)				-- DT_SYMENT
		ent(7, place[".rela.dyn"])		-- DT_RELA
		ent(8, nemit * 24)			-- DT_RELASZ
		ent(9, 24)				-- DT_RELAENT
		ent(30, 8)				-- DT_FLAGS: BIND_NOW
		ent(0x6ffffffb, 1)			-- DT_FLAGS_1: NOW
		ent(0, 0)				-- DT_NULL
		out[#out + 1] = {addr = place[".dynamic"], text = b:text(),
			name = ".dynamic"}
		dynsz = #b:text()
	end

	-- the file
	local img = buf.new()
	img:add("\127ELF")
	img:add(string.char(2, 1, 1, 0))
	img:add(string.rep("\0", 8))
	img:add(u(3, 2))				-- ET_DYN
	img:add(u(62, 2))				-- x86-64
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
	phdr(1, 7, 0, 0, filesz, memsz, PAGE)		-- PT_LOAD, rwx
	phdr(2, 6, place[".dynamic"], place[".dynamic"], dynsz, dynsz, 8)
	phdr(0x6474e551, 6, 0, 0, 0, 0, 16)		-- PT_GNU_STACK

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
	w:write(img:text())
end

return so
