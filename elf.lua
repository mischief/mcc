-- A relocatable ELF object, for the tools that read no other shape: GNU
-- ld, objdump, nm, and whatever a build system runs over what the
-- compiler wrote.  obj.lua stays the format this compiler's own linker
-- reads.  The same assembled unit goes in either way.

local elf = {}

-- e_machine
local EM = {amd64 = 62, arm64 = 183, riscv64 = 243, riscv32 = 243,
	    xtensa = 94}

-- What each of the compiler's relocation kinds is called in ELF.  A kind
-- missing from a machine's table is one this writer cannot spell, and
-- saying so beats writing a number that means something else.
local RELOC = {
	amd64 = {abs64 = 1, abs32 = 10, pc32 = 2, plt32 = 4,
		 gotpcrel = 9, pc8 = 15},
	arm64 = {abs64 = 257, abs32 = 258, a64_adrp = 275,
		 a64_add_lo12 = 277, a64_ldst8_lo12 = 278,
		 a64_ldst16_lo12 = 284, a64_ldst32_lo12 = 285,
		 a64_ldst64_lo12 = 286, a64_call26 = 283,
		 a64_jump26 = 282, a64_condbr19 = 280},
	riscv64 = {abs64 = 2, abs32 = 1, branch = 16, jal = 17,
		   pcrel_hi20 = 23, pcrel_lo12_i = 24},
	riscv32 = {abs32 = 1, branch = 16, jal = 17,
		   pcrel_hi20 = 23, pcrel_lo12_i = 24},
}

local SHT_PROGBITS, SHT_SYMTAB, SHT_STRTAB = 1, 2, 3
local SHT_RELA, SHT_NOBITS = 4, 8
-- A section the linker has no use for: the tables that describe the
-- others.  Anything else the loader maps goes in.
local SKIP = {[2] = true, [3] = true, [4] = true, [9] = true,
	      [11] = true, [17] = true}
local SHF_WRITE, SHF_ALLOC, SHF_EXEC = 1, 2, 4

local function u(v, n)
	local b = {}

	for i = 0, n - 1 do b[i + 1] = string.char(v >> (8 * i) & 255) end
	return table.concat(b)
end

-- A string table: every name at an offset, with the empty name at zero.
local function strtab()
	local t = {parts = {"\0"}, at = 1, seen = {[""] = 0}}

	function t.add(s)
		if t.seen[s] then return t.seen[s] end
		t.seen[s] = t.at
		t.parts[#t.parts + 1] = s .. "\0"
		t.at = t.at + #s + 1
		return t.seen[s]
	end
	function t.text() return table.concat(t.parts) end
	return t
end

-- Which sections a unit has, in the order they go in the file.  Index
-- zero is the null section every ELF starts with.
local function sections(a)
	local out, index = {}, {}

	for _, s in ipairs(a.order) do
		out[#out + 1] = s
		index[s] = #out		-- null section is 0
	end
	return out, index
end

-- Whose names the symbol table carries: everything global, everything a
-- relocation points at, and nothing else.  Most of a unit's labels the
-- assembler already resolved.
local function wanted(a)
	local want = {}

	for name, d in pairs(a.syms) do
		if d.global then want[name] = true end
	end
	for _, s in ipairs(a.order) do
		for _, r in ipairs(s.relocs) do want[r.sym] = true end
	end
	local names = {}

	for name in pairs(want) do names[#names + 1] = name end
	table.sort(names)
	return names
end

-- Whether every relocation this compiler makes for a machine has an
-- ELF name.  RISC-V pairs the halves of an address through a label of
-- its own and Xtensa has a call form of its own, and neither is
-- written here yet.
local COMPLETE = {amd64 = true, arm64 = true}

function elf.can(target) return COMPLETE[target] == true end

function elf.relocatable(a, target)
	local mach = EM[target] or error("no ELF machine for " .. target)
	local kinds = RELOC[target] or
		error("no ELF relocations for " .. target)
	local secs, index = sections(a)
	local shstr, str = strtab(), strtab()

	-- The symbol table: a null entry, then the locals, then the
	-- globals.  sh_info says where the globals start, which is what a
	-- linker reads to know which it may replace.
	local syments, symno = {u(0, 24)}, {}
	local function addsym(name, bind)
		local d = a.syms[name]
		local shndx = (d and d.sec) and index[d.sec] or 0
		local value = (d and d.sec) and d.off or 0

		if d and d.abs and not d.sec then
			shndx, value = 0xfff1, d.abs	-- SHN_ABS
		end
		symno[name] = #syments
		syments[#syments + 1] = table.concat{
			u(str.add(name), 4),
			string.char(bind << 4),		-- STT_NOTYPE
			"\0",
			u(shndx, 2), u(value, 8), u(0, 8)}
	end

	-- A name this unit does not define has to be global whatever it
	-- was written as: another unit is expected to answer for it.
	local function isglobal(name)
		local d = a.syms[name]

		return d == nil or d.global or (not d.sec and not d.abs)
	end
	local names = wanted(a)

	for _, name in ipairs(names) do
		if not isglobal(name) then addsym(name, 0) end
	end
	local firstglobal = #syments

	for _, name in ipairs(names) do
		if isglobal(name) then addsym(name, 1) end
	end

	-- The section headers, in the order the file lays them out: null,
	-- the unit's own sections, a .rela beside each one that needs it,
	-- then the two string tables and the symbol table.
	local shdrs = {{name = "", typ = 0, flags = 0, size = 0, align = 0,
			data = "", link = 0, info = 0, entsize = 0}}
	local shnum = {}

	for i, s in ipairs(secs) do
		local flags = SHF_ALLOC
		local perm = s.perm or 6

		if perm & 2 ~= 0 then flags = flags | SHF_WRITE end
		if perm & 1 ~= 0 then flags = flags | SHF_EXEC end
		shdrs[#shdrs + 1] = {
			name = s.name,
			typ = s.bss and SHT_NOBITS or SHT_PROGBITS,
			flags = flags, size = s.size, align = s.align or 1,
			data = s.bss and "" or (s.bytes or ""),
			link = 0, info = 0, entsize = 0}
		shnum[i] = #shdrs - 1		-- the null section is 0
	end
	-- Section indexes are settled now, so a relocation can name one.
	local relafor = {}

	for i, s in ipairs(secs) do
		if #s.relocs > 0 then
			local ents = {}

			for j, r in ipairs(s.relocs) do
				local k = kinds[r.kind] or
					error("no ELF relocation for " ..
						r.kind .. " on " .. target)
				local sy = symno[r.sym] or
					error("no symbol " .. r.sym)

				ents[j] = u(r.off, 8) ..
					u(k | sy << 32, 8) ..
					u(r.addend or 0, 8)
			end
			relafor[#relafor + 1] = {
				name = ".rela" .. s.name,
				typ = SHT_RELA, flags = 0,
				size = #ents * 24, align = 8,
				data = table.concat(ents),
				link = 0, info = shnum[i], entsize = 24}
		end
	end
	for _, r in ipairs(relafor) do shdrs[#shdrs + 1] = r end

	shdrs[#shdrs + 1] = {name = ".symtab", typ = SHT_SYMTAB, flags = 0,
			     size = #syments * 24, align = 8,
			     data = table.concat(syments),
			     link = 0, info = firstglobal, entsize = 24}
	local symidx = #shdrs

	shdrs[#shdrs + 1] = {name = ".strtab", typ = SHT_STRTAB, flags = 0,
			     size = 0, align = 1, data = "",
			     link = 0, info = 0, entsize = 0}
	local stridx = #shdrs

	shdrs[#shdrs + 1] = {name = ".shstrtab", typ = SHT_STRTAB, flags = 0,
			     size = 0, align = 1, data = "",
			     link = 0, info = 0, entsize = 0}
	local shstridx = #shdrs

	shdrs[symidx].link = stridx - 1
	for _, r in ipairs(relafor) do r.link = symidx - 1 end

	-- The names go in last, once every section has one.
	for _, h in ipairs(shdrs) do h.nameoff = shstr.add(h.name) end
	shdrs[stridx].data = str.text()
	shdrs[stridx].size = #shdrs[stridx].data
	shdrs[shstridx].data = shstr.text()
	shdrs[shstridx].size = #shdrs[shstridx].data

	-- Lay the file out: header, then each section's bytes aligned, then
	-- the section headers.
	local parts, at = {}, 64

	for i = 2, #shdrs do
		local h = shdrs[i]

		if h.typ == SHT_NOBITS or #h.data == 0 then
			h.offset = at
		else
			local pad = (h.align > 1) and
				(-at) % h.align or 0

			if pad > 0 then parts[#parts + 1] = string.rep("\0", pad) end
			at = at + pad
			h.offset = at
			parts[#parts + 1] = h.data
			at = at + #h.data
		end
	end
	shdrs[1].offset = 0
	local pad = (-at) % 8

	if pad > 0 then parts[#parts + 1] = string.rep("\0", pad) end
	at = at + pad
	local shoff = at

	local head = {"\127ELF", string.char(2, 1, 1, 0), string.rep("\0", 8),
		      u(1, 2),			-- ET_REL
		      u(mach, 2), u(1, 4),
		      u(0, 8),			-- e_entry
		      u(0, 8),			-- e_phoff
		      u(shoff, 8),
		      u(target == "riscv64" and 4 or 0, 4),
		      u(64, 2), u(0, 2), u(0, 2),
		      u(64, 2), u(#shdrs, 2), u(shstridx - 1, 2)}
	local tail = {}

	for _, h in ipairs(shdrs) do
		tail[#tail + 1] = table.concat{
			u(h.nameoff or 0, 4), u(h.typ, 4), u(h.flags, 8),
			u(0, 8),		-- sh_addr
			u(h.offset or 0, 8),
			u(h.typ == SHT_NOBITS and h.size or #h.data, 8),
			u(h.link, 4), u(h.info, 4),
			u(h.align, 8), u(h.entsize, 8)}
	end
	return table.concat(head) .. table.concat(parts) ..
		table.concat(tail)
end


-- reading ---------------------------------------------------------------

-- The other direction: an ET_REL this compiler did not necessarily
-- write.  The shape that comes back is the one obj.lua returns, so the
-- linker does not care which it was handed.

local MACHNAME = {[62] = "amd64", [183] = "arm64", [243] = "riscv",
		  [94] = "xtensa"}

-- ELF relocation numbers back to the names this compiler uses.
local UNRELOC = {}
for m, t in pairs(RELOC) do
	local back = {}

	for k, v in pairs(t) do back[v] = k end
	UNRELOC[m] = back
end
-- Spellings another assembler writes that this one never does.  The
-- relaxable forms of GOTPCREL behave like it when nothing relaxes them,
-- and 32S is the signed reading of the same four bytes.
UNRELOC.amd64[11] = "abs32"
UNRELOC.amd64[41] = "gotpcrel"
UNRELOC.amd64[42] = "gotpcrel"

-- One table per machine name, since riscv32 and riscv64 share an ELF
-- machine but not a relocation set.
UNRELOC.riscv = UNRELOC.riscv64

local function u16(s, at) return (string.unpack("<I2", s, at)) end
local function u32(s, at) return (string.unpack("<I4", s, at)) end
local function u64(s, at) return (string.unpack("<I8", s, at)) end

local function cstr(s, at)
	local e = s:find("\0", at + 1, true)

	return s:sub(at + 1, (e or #s + 1) - 1)
end

-- True when the file at `at0` is an ELF object.
function elf.is(path, at0)
	local f = io.open(path, "rb")

	if not f then return false end
	f:seek("set", at0 or 0)
	local m = f:read(4)

	f:close()
	return m == "\127ELF"
end

-- The section headers and the symbol table.  `light` stops after the
-- sections, which is all a pass that only hands out addresses needs.
function elf.header(path, light, at0)
	at0 = at0 or 0
	local f = assert(io.open(path, "rb"))

	f:seek("set", at0)
	local eh = f:read(64)

	if not eh or eh:sub(1, 4) ~= "\127ELF" then
		f:close()
		error(path .. " is not an object file")
	end
	local mach = u16(eh, 19)
	local shoff = u64(eh, 41)
	local shentsize, shnum, shstrndx = u16(eh, 59), u16(eh, 61),
		u16(eh, 63)

	f:seek("set", at0 + shoff)
	local raw = f:read(shentsize * shnum) or ""
	local sh = {}

	for i = 0, shnum - 1 do
		local at = i * shentsize + 1

		sh[i] = {name = u32(raw, at), typ = u32(raw, at + 4),
			 flags = u64(raw, at + 8), off = u64(raw, at + 24),
			 size = u64(raw, at + 32), link = u32(raw, at + 40),
			 info = u32(raw, at + 44), align = u64(raw, at + 48),
			 entsize = u64(raw, at + 56)}
	end
	local function contents(i)
		if not sh[i] or sh[i].typ == SHT_NOBITS then return "" end
		f:seek("set", at0 + sh[i].off)
		return f:read(sh[i].size) or ""
	end
	local shstr = contents(shstrndx)
	local u = {path = path, at0 = at0, elf = true,
		   arch = MACHNAME[mach] or "amd64",
		   order = {}, syms = {}, symnames = {}, weak = {}}
	local bynum = {}

	for i = 0, shnum - 1 do
		local s = sh[i]

		-- Anything the loader maps: bytes, space, the arrays of
		-- pointers run before and after main, a note, the
		-- unwind tables a machine gives a type of its own.
		if s.flags & SHF_ALLOC ~= 0 and not SKIP[s.typ] then
			local perm = 4

			if s.flags & SHF_WRITE ~= 0 then perm = perm | 2 end
			if s.flags & SHF_EXEC ~= 0 then perm = perm | 1 end
			local e = {name = cstr(shstr, s.name), size = s.size,
				   align = s.align > 0 and s.align or 1,
				   bss = s.typ == SHT_NOBITS,
				   perm = perm, off = s.off, nrel = 0,
				   relocs = {}, unit = u}

			u.order[#u.order + 1] = e
			bynum[i] = e
		end
	end
	-- A relocation section belongs to the one it names.
	for i = 0, shnum - 1 do
		local s = sh[i]

		if s.typ == SHT_RELA and bynum[s.info] then
			local e = bynum[s.info]

			e.reloff, e.nrel = s.off, s.size // 24
		end
	end
	if light then
		f:close()
		return u
	end
	-- The symbols, by the index a relocation names them with.  A
	-- symbol for a section has no name of its own, so it is given
	-- one: a relocation may point at a section and an offset.
	local symtab, strtab
	for i = 0, shnum - 1 do
		if sh[i].typ == SHT_SYMTAB then symtab, strtab = i, sh[i].link end
	end
	if symtab then
		local raw2 = contents(symtab)
		local str = contents(strtab)

		for k = 0, #raw2 // 24 - 1 do
			local at = k * 24 + 1
			local nm = cstr(str, u32(raw2, at))
			local info = raw2:byte(at + 4)
			local shndx = u16(raw2, at + 6)
			local value = u64(raw2, at + 8)

			if info & 0xf == 3 and nm == "" then
				nm = ".Lsec" .. shndx
			end
			u.symnames[k + 1] = nm
			-- A weak name the program does not have is not an
			-- error: it stands for nothing.
			if nm ~= "" and shndx == 0 and info >> 4 == 2 then
				u.weak[nm] = true
			end
			if nm ~= "" and bynum[shndx] then
				u.syms[nm] = {sec = bynum[shndx],
					      off = value,
					      global = info >> 4 ~= 0}
			end
		end
	end
	f:close()
	return u
end

-- The name a shared object answers to, which is what goes in the list
-- of libraries a program wants.  A file that is a linker script rather
-- than an object names the real one inside a GROUP.
function elf.soname(path)
	local f = io.open(path, "rb")

	if not f then return nil end
	local head = f:read(4)

	if head ~= "\127ELF" then
		f:seek("set", 0)
		local text = f:read(4096) or ""

		f:close()
		for w in text:gmatch("[%w%./_%-]+") do
			if w:match("%.so[%.%d]*$") and w:find("/") then
				return elf.soname(w) or w:gsub(".*/", "")
			end
		end
		return nil
	end
	f:seek("set", 0)
	local eh = f:read(64)
	local shoff = u64(eh, 41)
	local shentsize, shnum, shstrndx = u16(eh, 59), u16(eh, 61),
		u16(eh, 63)

	f:seek("set", shoff)
	local raw = f:read(shentsize * shnum) or ""
	local dynoff, dynsz, stroff
	local function at(i, k) return u32(raw, i * shentsize + k) end

	for i = 0, shnum - 1 do
		local base = i * shentsize + 1

		if u32(raw, base + 4) == 6 then		-- SHT_DYNAMIC
			dynoff = u64(raw, base + 24)
			dynsz = u64(raw, base + 32)
			local link = u32(raw, base + 40)

			stroff = u64(raw, link * shentsize + 25)
		end
	end
	if not dynoff then
		f:close()
		return nil
	end
	f:seek("set", dynoff)
	local dyn = f:read(dynsz) or ""
	local want

	for k = 0, #dyn // 16 - 1 do
		local tag = u64(dyn, k * 16 + 1)

		if tag == 14 then want = u64(dyn, k * 16 + 9) end
	end
	local name
	if want then
		f:seek("set", stroff + want)
		name = (f:read(256) or ""):match("^[^%z]*")
	end
	f:close()
	if shstrndx then end
	return name
end

function elf.section(u, s, names)
	local f = assert(io.open(u.path, "rb"))

	f:seek("set", u.at0 + s.off)
	local bytes = s.bss and "" or (f:read(s.size) or "")
	local rel = ""

	if s.nrel > 0 then
		f:seek("set", u.at0 + s.reloff)
		rel = f:read(s.nrel * 24) or ""
	end
	f:close()
	local kinds = UNRELOC[u.arch] or UNRELOC.amd64
	local relocs = {}

	for k = 1, s.nrel do
		local at = (k - 1) * 24 + 1
		local off = u64(rel, at)
		local info = u64(rel, at + 8)
		local addend = (string.unpack("<i8", rel, at + 16))
		local kind = kinds[info & 0xffffffff]

		if not kind then
			error(("%s: relocation %d is one this linker does " ..
				"not know"):format(u.path, info & 0xffffffff))
		end
		relocs[k] = {off = off, kind = kind,
			     sym = (names or u.symnames)[(info >> 32) + 1],
			     addend = addend}
	end
	return bytes, relocs
end

-- An ELF object carries no table of system call sites; only this
-- compiler's own format does.
function elf.syscalls() return {} end

return elf
