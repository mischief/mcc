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

return elf
