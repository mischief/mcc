-- SPDX-License-Identifier: ISC
-- A relocatable ELF object, which is the only shape this compiler
-- writes or reads.  Every tool a build system runs over an object --
-- GNU ld, objdump, nm, readelf -- wants this one, so writing anything
-- else would only hide the backend from them.

local elf = {}

-- e_machine
local EM = {amd64 = 62, i386 = 3, arm64 = 183, riscv64 = 243,
	    riscv32 = 243, xtensa = 94}

-- What each of the compiler's relocation kinds is called in ELF.  A kind
-- missing from a machine's table is one this writer cannot spell, and
-- saying so beats writing a number that means something else.
local RELOC = {
	amd64 = {abs64 = 1, abs32 = 10, abs32s = 11, pc32 = 2, pc64 = 24,
		 plt32 = 4, gotpcrel = 9, gotpcrelx = 41, rexgotpcrelx = 42,
		 abs16 = 12, pc16 = 13, pc8 = 15, tpoff32 = 23},
	-- 32-bit x86, which on this compiler is not a target of its own:
	-- it is the amd64 code tables writing a narrow object, for the
	-- one place a kernel needs one.  Nothing here has an addend in
	-- the entry, so the linker reads it out of the field.
	i386 = {abs32 = 1, pc32 = 2, plt32 = 4, abs16 = 20, pc16 = 21,
		abs8 = 22, pc8 = 23},
	arm64 = {abs64 = 257, abs32 = 258, pc32 = 261, a64_adrp = 275,
		 a64_add_lo12 = 277, a64_ldst8_lo12 = 278,
		 a64_ldst16_lo12 = 284, a64_ldst32_lo12 = 285,
		 a64_ldst64_lo12 = 286, a64_call26 = 283,
		 a64_jump26 = 282, a64_condbr19 = 280,
		 a64_got_page = 311, a64_got_lo12 = 312},
	-- A jalr takes its low half the same way any other I-type
	-- instruction does, so the two share a number.
	-- A difference of two labels the assembler could not work out,
	-- which a header made of offsets is written with.
	riscv64 = {abs64 = 2, abs32 = 1, pc32 = 57, branch = 16, jal = 17,
		   got_hi20 = 20,
		   pcrel_hi20 = 23, pcrel_lo12_i = 24,
		   pcrel_lo12_jalr = 24, pcrel_lo12_s = 25,
		   hi20 = 26, lo12_i = 27, lo12_s = 28},
	riscv32 = {abs32 = 1, pc32 = 57, branch = 16, jal = 17,
		   got_hi20 = 20,
		   pcrel_hi20 = 23, pcrel_lo12_i = 24,
		   pcrel_lo12_jalr = 24, pcrel_lo12_s = 25,
		   hi20 = 26, lo12_i = 27, lo12_s = 28},
	-- Xtensa names the whole instruction and lets the linker work
	-- out which field it is patching, because the encoding says.
	xtensa = {abs32 = 1, xt_call = 20},
}

-- `--wrap=name` sends every reference to that name to __wrap_name, and
-- every reference to __real_name to the name itself.  A definition
-- keeps its own spelling, which is what makes the substitution work.
local wrap = {}

function elf.wrap(names)
	wrap = {}
	for _, n in ipairs(names or {}) do wrap[n] = true end
end

function elf.wrapped(name)
	if not name or next(wrap) == nil then return name end
	if wrap[name] then return "__wrap_" .. name end
	local real = name:match("^__real_(.+)$")

	if real and wrap[real] then return real end
	return name
end

local SHT_PROGBITS, SHT_SYMTAB, SHT_STRTAB = 1, 2, 3
local SHF_TLS = 0x400
local SHT_RELA, SHT_NOBITS = 4, 8
-- A section the linker has no use for: the tables that describe the
-- others.  Anything else the loader maps goes in.
local SKIP = {[2] = true, [3] = true, [4] = true, [9] = true,
	      [11] = true, [17] = true}
local SHF_WRITE, SHF_ALLOC, SHF_EXEC = 1, 2, 4
local SHF_MERGE, SHF_INFO_LINK = 0x10, 0x40

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
		-- A name the source said is a function or an object is
		-- kept whether or not anything refers to it: a validator
		-- that walks the code needs the boundary, and a static
		-- function has no other way to say where it ends.
		if d.global or d.styp then want[name] = true end
	end
	for _, s in ipairs(a.order) do
		for _, r in ipairs(s.relocs) do
			local d = a.syms[r.sym]

			-- A name of the assembler's own is not written
			-- down: what the relocation means is a place in
			-- a section, and the section says it. gas does
			-- the same, and a validator that walks the code
			-- reads a `.L` in the table as a function of its
			-- own and misreads a jump between two of them.
			if not (d and d.sec and not d.global and
			    r.sym:sub(1, 2) == ".L") then
				want[r.sym] = true
			end
		end
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
-- The targets whose objects are ELFCLASS32.  Everything an object says
-- about a place is half as wide there, and so are the symbol and
-- relocation entries.
local NARROW = {riscv32 = true, xtensa = true, i386 = true}

function elf.relocatable(a, target)
	local mach = EM[target] or error("no ELF machine for " .. target)
	local kinds = RELOC[target] or
		error("no ELF relocations for " .. target)
	local wide = not NARROW[target]
	local W = wide and 8 or 4		-- a place, as this file says it
	local SYMSZ = wide and 24 or 16
	local RELSZ = wide and 24 or 12
	local EHSZ = wide and 64 or 52
	local SHSZ = wide and 64 or 40
	local secs, index = sections(a)
	local shstr, str = strtab(), strtab()

	-- The symbol table: a null entry, then the locals, then the
	-- globals.  sh_info says where the globals start, which is what a
	-- linker reads to know which it may replace.
	local syments, symno = {u(0, SYMSZ)}, {}
	local function addsym(name, bind)
		local d = a.syms[name]
		local shndx = (d and d.sec) and index[d.sec] or 0
		local value = (d and d.sec) and d.off or 0

		if d and d.abs and not d.sec then
			shndx, value = 0xfff1, d.abs	-- SHN_ABS
		end
		-- A thread-local object has to say so: the linker works
		-- out its place in the thread's own block, not in the
		-- section it happens to sit in.
		local styp = (d and d.styp) or 0

		if d and d.sec and (d.sec.name == ".tdata" or
		    d.sec.name == ".tbss") then
			styp = 6			-- STT_TLS
		end
		local ssize = (d and d.size) or 0
		symno[name] = #syments
		if wide then
			syments[#syments + 1] = table.concat{
				u(str.add(name), 4),
				string.char(bind << 4 | styp),
				string.char((d and d.vis) or 0),
				u(shndx, 2), u(value, 8), u(ssize, 8)}
		else
			-- Elf32_Sym puts the value and the size before
			-- the info rather than after it.
			syments[#syments + 1] = table.concat{
				u(str.add(name), 4), u(value, 4), u(ssize, 4),
				string.char(bind << 4 | styp),
				string.char((d and d.vis) or 0),
				u(shndx, 2)}
		end
	end

	-- A name this unit does not define has to be global whatever it
	-- was written as: another unit is expected to answer for it.
	local function isglobal(name)
		local d = a.syms[name]

		return d == nil or d.global or (not d.sec and not d.abs)
	end
	local names = wanted(a)
	-- One symbol for each section a relocation has to point at,
	-- because the place it means has no name of its own.
	local secsym, need = {}, {}

	for _, sec in ipairs(secs) do
		for _, r in ipairs(sec.relocs) do
			local d = a.syms[r.sym]

			if d and d.sec and not symno[r.sym] and
			   not d.global then
				need[d.sec] = true
			end
		end
	end
	for _, sec in ipairs(secs) do
		if need[sec] then
			secsym[sec] = #syments
			syments[#syments + 1] = wide and table.concat{
				u(str.add(""), 4), string.char(3),
				string.char(0), u(index[sec], 2),
				u(0, 8), u(0, 8)}
				or table.concat{
				u(str.add(""), 4), u(0, 4), u(0, 4),
				string.char(3), string.char(0),
				u(index[sec], 2)}
		end
	end
	for _, name in ipairs(names) do
		if not isglobal(name) then addsym(name, 0) end
	end
	local firstglobal = #syments

	for _, name in ipairs(names) do
		if isglobal(name) then
			local d = a.syms[name]

			addsym(name, (d and d.weak) and 2 or 1)
		end
	end

	-- The section headers, in the order the file lays them out: null,
	-- the unit's own sections, a .rela beside each one that needs it,
	-- then the two string tables and the symbol table.
	local shdrs = {{name = "", typ = 0, flags = 0, size = 0, align = 0,
			data = "", link = 0, info = 0, entsize = 0}}
	local shnum = {}

	for i, s in ipairs(secs) do
		local perm = s.perm or 6
		local flags = perm & 4 ~= 0 and SHF_ALLOC or 0

		if perm & 2 ~= 0 then flags = flags | SHF_WRITE end
		if perm & 1 ~= 0 then flags = flags | SHF_EXEC end
		-- Entries of one size that the linker may fold together
		-- when two of them hold the same bytes.
		if s.merge then flags = flags | SHF_MERGE end
		-- Each thread gets its own copy of these, which the
		-- loader has to be told rather than guess from the name.
		if s.name == ".tdata" or s.name == ".tbss" then
			flags = flags | SHF_TLS
		end
		shdrs[#shdrs + 1] = {
			name = s.name,
			typ = s.bss and SHT_NOBITS or SHT_PROGBITS,
			flags = flags, size = s.size, align = s.align or 1,
			data = s.bss and "" or (s.bytes or ""),
			link = 0, info = 0, entsize = s.entsize or 0}
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
				local sy, extra = symno[r.sym], 0

				if not sy then
					local d = a.syms[r.sym]

					sy = d and d.sec and secsym[d.sec]
					extra = (d and d.off) or 0
				end
				if not sy then
					error("no symbol " .. r.sym)
				end

				-- The symbol index and the kind share one
				-- field, eight bits of kind in the narrow
				-- form and thirty-two in the wide one.
				if wide then
					ents[j] = u(r.off, 8) ..
						u(k | sy << 32, 8) ..
						u((r.addend or 0) + extra, 8)
				else
					ents[j] = u(r.off, 4) ..
						u(k | sy << 8, 4) ..
						u((r.addend or 0) + extra, 4)
				end
			end
			relafor[#relafor + 1] = {
				name = ".rela" .. s.name,
				-- The `info` field names a section rather
				-- than being a plain number, which the
				-- flag is what says.
				typ = SHT_RELA, flags = SHF_INFO_LINK,
				size = #ents * RELSZ, align = W,
				data = table.concat(ents),
				link = 0, info = shnum[i], entsize = RELSZ}
		end
	end
	for _, r in ipairs(relafor) do shdrs[#shdrs + 1] = r end

	-- Where each system call instruction stands, which a kernel that
	-- pins them down asks for.  No other tool wants it, so it is a
	-- section of its own that nothing maps.
	local sys = {}

	for i, sec in ipairs(secs) do
		for _, c in ipairs(sec.syscalls or {}) do
			sys[#sys + 1] = u(shnum[i], 4) .. u(c.off, 4) ..
				u(c.sysno, 4)
		end
	end
	if #sys > 0 then
		sys = table.concat(sys)
		shdrs[#shdrs + 1] = {name = ".mcc.syscalls",
				     typ = SHT_PROGBITS, flags = 0,
				     size = #sys, align = 4, data = sys,
				     link = 0, info = 0, entsize = 12}
	end
	shdrs[#shdrs + 1] = {name = ".symtab", typ = SHT_SYMTAB, flags = 0,
			     size = #syments * SYMSZ, align = W,
			     data = table.concat(syments),
			     link = 0, info = firstglobal, entsize = SYMSZ}
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
	local parts, at = {}, EHSZ

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
	local pad = (-at) % W

	if pad > 0 then parts[#parts + 1] = string.rep("\0", pad) end
	at = at + pad
	local shoff = at

	local head = {"\127ELF", string.char(wide and 2 or 1, 1, 1, 0),
		      string.rep("\0", 8),
		      u(1, 2),			-- ET_REL
		      u(mach, 2), u(1, 4),
		      u(0, W),			-- e_entry
		      u(0, W),			-- e_phoff
		      u(shoff, W),
		      u(target == "riscv64" and 4 or 0, 4),
		      u(EHSZ, 2), u(0, 2), u(0, 2),
		      u(SHSZ, 2), u(#shdrs, 2), u(shstridx - 1, 2)}
	local tail = {}

	for _, h in ipairs(shdrs) do
		tail[#tail + 1] = table.concat{
			u(h.nameoff or 0, 4), u(h.typ, 4), u(h.flags, W),
			u(0, W),		-- sh_addr
			u(h.offset or 0, W),
			u(h.typ == SHT_NOBITS and h.size or #h.data, W),
			u(h.link, 4), u(h.info, 4),
			u(h.align, W), u(h.entsize, W)}
	end
	return table.concat(head) .. table.concat(parts) ..
		table.concat(tail)
end


-- reading ---------------------------------------------------------------

-- The other direction: an ET_REL this compiler did not necessarily
-- write.  The shape that comes back is what the linker wants, so it
-- does not care who wrote the object.

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
-- two relaxable forms of GOTPCREL say the reference may be turned into
-- one that needs no table, and 32S is the signed reading of the same
-- four bytes.
UNRELOC.amd64[11] = "abs32"
UNRELOC.amd64[41] = "gotpcrelx"
UNRELOC.amd64[42] = "gotpcrelx"

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
	-- Everything that names a place is half as wide in an ELFCLASS32
	-- object, which moves every field after the identification.
	local wide = eh:byte(5) == 2
	local uw = wide and u64 or u32
	local SYMSZ = wide and 24 or 16
	local RELSZ = wide and 24 or 12
	local mach = u16(eh, 19)
	local shoff = uw(eh, wide and 41 or 33)
	local base = wide and 59 or 47
	local shentsize, shnum, shstrndx = u16(eh, base), u16(eh, base + 2),
		u16(eh, base + 4)

	f:seek("set", at0 + shoff)
	local raw = f:read(shentsize * shnum) or ""
	local sh = {}

	for i = 0, shnum - 1 do
		local at = i * shentsize + 1

		local W = wide and 8 or 4

		sh[i] = {name = u32(raw, at), typ = u32(raw, at + 4),
			 flags = uw(raw, at + 8),
			 off = uw(raw, at + 8 + W * 2),
			 size = uw(raw, at + 8 + W * 3),
			 link = u32(raw, at + 8 + W * 4),
			 info = u32(raw, at + 12 + W * 4),
			 align = uw(raw, at + 16 + W * 4),
			 entsize = uw(raw, at + 16 + W * 5)}
	end
	local function contents(i)
		if not sh[i] or sh[i].typ == SHT_NOBITS then return "" end
		f:seek("set", at0 + sh[i].off)
		return f:read(sh[i].size) or ""
	end
	local shstr = contents(shstrndx)
	local u = {path = path, at0 = at0, elf = true, wide = wide,
		   arch = MACHNAME[mach] or "amd64",
		   order = {}, syms = {}, symnames = {}, weak = {}}
	local bynum = {}

	for i = 0, shnum - 1 do
		local s = sh[i]

		-- Anything the loader maps: bytes, space, the arrays of
		-- pointers run before and after main, a note, the
		-- unwind tables a machine gives a type of its own.
		local nm = cstr(shstr, s.name)

		if nm == ".mcc.syscalls" then
			u.sysoff, u.syssize = s.off, s.size
		end
		if s.flags & SHF_ALLOC ~= 0 and not SKIP[s.typ] then
			local perm = 4

			if s.flags & SHF_WRITE ~= 0 then perm = perm | 2 end
			if s.flags & SHF_EXEC ~= 0 then perm = perm | 1 end
			local e = {name = nm, size = s.size, shndx = i,
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

			e.reloff, e.nrel = s.off, s.size // RELSZ
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

		for k = 0, #raw2 // SYMSZ - 1 do
			local at = k * SYMSZ + 1
			local nm = cstr(str, u32(raw2, at))
			-- Elf32_Sym puts the value and the size before
			-- the info rather than after it.
			local info = raw2:byte(at + (wide and 4 or 12))
			local shndx = u16(raw2, at + (wide and 6 or 14))
			local value = wide and u64(raw2, at + 8)
				or u32(raw2, at + 4)

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
				-- A weak definition loses to a strong one
				-- of the same name, and the kind says
				-- whether it names code or data.
				u.syms[nm] = {sec = bynum[shndx],
					      off = value,
					      weak = info >> 4 == 2,
					      styp = info & 0xf,
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

-- The version each name in a shared object answers to by default.
--
-- glibc keeps more than one definition of a few names: `realpath` is
-- both the one a program wants and a compat stub that fails on an
-- argument the old one did not take.  A reference that asks for no
-- version may be bound to either, so a program that does not say which
-- it wants gets whichever the loader reaches first.  This reads the
-- library's own version table so the caller can ask for the default.
--
-- Answers a table of name -> version string, and the soname.
function elf.defversions(path)
	local f = io.open(path, "rb")

	if not f then return nil end
	if f:read(4) ~= "\127ELF" then
		f:close()
		return nil
	end
	f:seek("set", 0)
	local eh = f:read(64) or ""
	local shoff = u64(eh, 41)
	local shentsize, shnum = u16(eh, 59), u16(eh, 61)

	if shnum == 0 then
		f:close()
		return nil
	end
	f:seek("set", shoff)
	local raw = f:read(shentsize * shnum) or ""
	local sec = {}

	for i = 0, shnum - 1 do
		local b = i * shentsize + 1

		sec[i] = {typ = u32(raw, b + 4), off = u64(raw, b + 24),
			  size = u64(raw, b + 32), link = u32(raw, b + 40),
			  info = u32(raw, b + 44), ent = u64(raw, b + 56)}
	end
	local dynsym, versym, verdef
	for i = 0, shnum - 1 do
		local t = sec[i].typ

		if t == 11 then dynsym = sec[i]		-- SHT_DYNSYM
		elseif t == 0x6fffffff then versym = sec[i]
		elseif t == 0x6ffffffd then verdef = sec[i]
		end
	end
	if not (dynsym and versym and verdef) then
		f:close()
		return nil
	end
	local str = sec[dynsym.link]
	local function slurp(x)
		f:seek("set", x.off)
		return f:read(x.size) or ""
	end
	local symtxt, vertxt, deftxt = slurp(dynsym), slurp(versym),
		slurp(verdef)
	local strtxt = slurp(str)
	local function cname(at)
		return strtxt:sub(at + 1):match("^[^%z]*")
	end

	-- The definitions: each Verdef says which index it is and names
	-- itself in the first Verdaux.  The one with VER_FLG_BASE is the
	-- library's own soname, not a version a symbol may carry.
	local byindex, soname = {}, nil
	local at = 0

	for _ = 1, verdef.info do
		local flags = u16(deftxt, at + 3)
		local ndx = u16(deftxt, at + 5)
		local aux = u32(deftxt, at + 13)
		local nxt = u32(deftxt, at + 17)
		local nm = cname(u32(deftxt, at + aux + 1))

		if flags & 1 ~= 0 then soname = nm else byindex[ndx] = nm end
		if nxt == 0 then break end
		at = at + nxt
	end
	-- And the symbols: the top bit of the index says the definition
	-- is hidden, which is what a compat one is.
	local out = {}
	local n = dynsym.size // 24

	for k = 0, n - 1 do
		local nm = cname(u32(symtxt, k * 24 + 1))
		local vs = u16(vertxt, k * 2 + 1)
		local shndx = u16(symtxt, k * 24 + 7)

		if nm ~= "" and shndx ~= 0 and vs & 0x8000 == 0 and
		   byindex[vs] then
			out[nm] = byindex[vs]
		end
	end
	f:close()
	return out, soname
end

function elf.section(u, s, names)
	local f = assert(io.open(u.path, "rb"))

	f:seek("set", u.at0 + s.off)
	local bytes = s.bss and "" or (f:read(s.size) or "")
	local rel = ""

	-- A narrow object says all three fields of a relocation in four
	-- bytes each, with eight bits of kind rather than thirty-two.
	local wide = u.wide ~= false
	local RELSZ = wide and 24 or 12

	if s.nrel > 0 then
		f:seek("set", u.at0 + s.reloff)
		rel = f:read(s.nrel * RELSZ) or ""
	end
	f:close()
	local kinds = UNRELOC[u.arch] or UNRELOC.amd64
	local relocs = {}

	for k = 1, s.nrel do
		local at = (k - 1) * RELSZ + 1
		local off = wide and u64(rel, at) or u32(rel, at)
		local info = wide and u64(rel, at + 8) or u32(rel, at + 4)
		local addend = wide and
			(string.unpack("<i8", rel, at + 16)) or
			(string.unpack("<i4", rel, at + 8))
		local no = wide and (info & 0xffffffff) or (info & 0xff)
		local kind = kinds[no]

		if not kind then
			error(("%s: relocation %d is one this linker does " ..
				"not know"):format(u.path, no))
		end
		relocs[k] = {off = off, kind = kind,
			     sym = elf.wrapped((names or
				u.symnames)[(wide and info >> 32
					or info >> 8) + 1]),
			     addend = addend}
	end
	return bytes, relocs
end

-- Where each system call instruction of a section stands.
function elf.syscalls(u, s)
	if not u.sysoff or not s.shndx then return {} end
	local f = assert(io.open(u.path, "rb"))

	f:seek("set", u.at0 + u.sysoff)
	local raw = f:read(u.syssize) or ""

	f:close()
	local out = {}

	for k = 0, #raw // 12 - 1 do
		local at = k * 12 + 1

		if u32(raw, at) == s.shndx then
			out[#out + 1] = {off = u32(raw, at + 4),
					 sysno = u32(raw, at + 8)}
		end
	end
	return out
end

return elf
