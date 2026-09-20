-- SPDX-License-Identifier: ISC
-- Reading an ELF file and answering questions about it.
--
-- elf.lua reads only what the linker wants from an ET_REL.  This reads
-- what nm, objdump and readelf print, from an executable as well, and
-- `at` answers which symbol holds an address.  Little endian only.

local elfread = {}

local EI_CLASS, EI_DATA = 5, 6

local ET = {[0] = "none", "rel", "exec", "dyn", "core"}

-- e_machine, by the name this compiler calls the target.  riscv32 and
-- riscv64 share a number and are told apart by the class.
local MACH = {[3] = "i386", [62] = "amd64", [183] = "arm64",
	      [243] = "riscv", [94] = "xtensa", [40] = "arm",
	      [20] = "ppc", [21] = "ppc64", [8] = "mips"}

local SHT = {[0] = "null", "progbits", "symtab", "strtab", "rela", "hash",
	     "dynamic", "note", "nobits", "rel", "shlib", "dynsym"}
SHT[14] = "init_array"
SHT[15] = "fini_array"
SHT[16] = "preinit_array"
SHT[17] = "group"
SHT[18] = "symtab_shndx"
SHT[0x6ffffff6] = "gnu_hash"
SHT[0x6ffffffd] = "verdef"
SHT[0x6ffffffe] = "verneed"
SHT[0x6fffffff] = "versym"

local STB = {[0] = "local", "global", "weak"}
local STT = {[0] = "notype", "object", "func", "section", "file",
	     "common", "tls"}
STT[10] = "ifunc"
local STV = {[0] = "default", "internal", "hidden", "protected"}

local PT = {[0] = "null", "load", "dynamic", "interp", "note", "shlib",
	    "phdr", "tls"}
PT[0x6474e550] = "gnu_eh_frame"
PT[0x6474e551] = "gnu_stack"
PT[0x6474e552] = "gnu_relro"
PT[0x6474e553] = "gnu_property"
PT[0x60000000] = "pvh"			-- what a kernel is entered by

local SHF = {write = 1, alloc = 2, exec = 4, merge = 0x10, strings = 0x20,
	     info_link = 0x40, link_order = 0x80, group = 0x200,
	     tls = 0x400}

-- Section numbers that name something other than a section.
local SHN_ABS, SHN_COMMON, SHN_XINDEX = 0xfff1, 0xfff2, 0xffff

elfread.SHF = SHF

-- The names the rest of the world prints for a relocation.  A number
-- with no name here is printed as a number, which still says which
-- relocation two tools disagree about.
local RTYPE = {
	amd64 = {[0] = "R_X86_64_NONE", "R_X86_64_64", "R_X86_64_PC32",
		 "R_X86_64_GOT32", "R_X86_64_PLT32", "R_X86_64_COPY",
		 "R_X86_64_GLOB_DAT", "R_X86_64_JUMP_SLOT",
		 "R_X86_64_RELATIVE", "R_X86_64_GOTPCREL",
		 "R_X86_64_32", "R_X86_64_32S", "R_X86_64_16",
		 "R_X86_64_PC16", "R_X86_64_8", "R_X86_64_PC8",
		 "R_X86_64_DTPMOD64", "R_X86_64_DTPOFF64",
		 "R_X86_64_TPOFF64", "R_X86_64_TLSGD", "R_X86_64_TLSLD",
		 "R_X86_64_DTPOFF32", "R_X86_64_GOTTPOFF",
		 "R_X86_64_TPOFF32", "R_X86_64_PC64",
		 "R_X86_64_GOTOFF64", "R_X86_64_GOTPC32"},
	i386 = {[0] = "R_386_NONE", "R_386_32", "R_386_PC32", "R_386_GOT32",
		"R_386_PLT32", "R_386_COPY", "R_386_GLOB_DAT",
		"R_386_JUMP_SLOT", "R_386_RELATIVE", "R_386_GOTOFF",
		"R_386_GOTPC"},
	arm64 = {[0] = "R_AARCH64_NONE"},
	riscv = {[0] = "R_RISCV_NONE", "R_RISCV_32", "R_RISCV_64",
		 "R_RISCV_RELATIVE"},
	xtensa = {[0] = "R_XTENSA_NONE", "R_XTENSA_32"},
}
RTYPE.amd64[41] = "R_X86_64_GOTPCRELX"
RTYPE.amd64[42] = "R_X86_64_REX_GOTPCRELX"
RTYPE.arm64[257] = "R_AARCH64_ABS64"
RTYPE.arm64[258] = "R_AARCH64_ABS32"
RTYPE.arm64[261] = "R_AARCH64_PREL32"
RTYPE.arm64[275] = "R_AARCH64_ADR_PREL_PG_HI21"
RTYPE.arm64[277] = "R_AARCH64_ADD_ABS_LO12_NC"
RTYPE.arm64[278] = "R_AARCH64_LDST8_ABS_LO12_NC"
RTYPE.arm64[280] = "R_AARCH64_CONDBR19"
RTYPE.arm64[282] = "R_AARCH64_JUMP26"
RTYPE.arm64[283] = "R_AARCH64_CALL26"
RTYPE.arm64[284] = "R_AARCH64_LDST16_ABS_LO12_NC"
RTYPE.arm64[285] = "R_AARCH64_LDST32_ABS_LO12_NC"
RTYPE.arm64[286] = "R_AARCH64_LDST64_ABS_LO12_NC"
RTYPE.arm64[311] = "R_AARCH64_ADR_GOT_PAGE"
RTYPE.arm64[312] = "R_AARCH64_LD64_GOT_LO12_NC"
for n, s in pairs{[16] = "R_RISCV_BRANCH", [17] = "R_RISCV_JAL",
		  [18] = "R_RISCV_CALL", [19] = "R_RISCV_CALL_PLT",
		  [20] = "R_RISCV_GOT_HI20", [23] = "R_RISCV_PCREL_HI20",
		  [24] = "R_RISCV_PCREL_LO12_I",
		  [25] = "R_RISCV_PCREL_LO12_S", [26] = "R_RISCV_HI20",
		  [27] = "R_RISCV_LO12_I", [28] = "R_RISCV_LO12_S",
		  [51] = "R_RISCV_RELAX", [57] = "R_RISCV_32_PCREL"} do
	RTYPE.riscv[n] = s
end

local function cstr(s, at)
	local e = s:find("\0", at + 1, true)

	return s:sub(at + 1, (e or #s + 1) - 1)
end

local obj = {}
obj.__index = obj

-- The bytes of the file between two offsets, read once and kept only as
-- long as the caller holds what came out of them.  A 22 MB vmlinux is
-- not worth holding whole to print a symbol table.
function obj:read(off, size)
	if size <= 0 then return "" end
	self.f:seek("set", self.at0 + off)
	return self.f:read(size) or ""
end

-- One section's bytes.  A NOBITS section occupies no file, so it reads
-- as the zeros it stands for.
function obj:contents(s)
	if s.typ == "nobits" then return ("\0"):rep(s.size) end
	if not s.data then s.data = self:read(s.off, s.size) end
	return s.data
end

function obj:find(name)
	for _, s in ipairs(self.sections) do
		if s.name == name then return s end
	end
end

function obj:close()
	if self.f then self.f:close() end
	self.f = nil
end

-- symbols ---------------------------------------------------------------

-- One symbol table, by the name of the section that holds it: `.symtab`
-- for the one a linker reads and `.dynsym` for the one a loader does.
-- A stripped file has neither, and answers an empty list.
function obj:syms(which)
	which = which or ".symtab"
	self.symcache = self.symcache or {}
	if self.symcache[which] then return self.symcache[which] end
	local sec = self:find(which)
	local out = {}

	self.symcache[which] = out
	if not sec or sec.size == 0 then return out end
	local str = self:contents(self.byindex[sec.link] or {})
	local raw = self:contents(sec)
	local wide = self.class == 64
	local SZ = wide and 24 or 16

	for k = 0, #raw // SZ - 1 do
		local at = k * SZ + 1
		local nameoff, value, size, info, other, shndx

		if wide then
			nameoff, info, other, shndx, value, size =
				string.unpack("<I4BBI2I8I8", raw, at)
		else
			nameoff, value, size, info, other, shndx =
				string.unpack("<I4I4I4BBI2", raw, at)
		end
		out[k + 1] = {
			num = k,
			name = cstr(str, nameoff),
			value = value,
			size = size,
			bind = STB[info >> 4] or (info >> 4),
			typ = STT[info & 0xf] or (info & 0xf),
			vis = STV[other & 3],
			shndx = shndx,
			sec = self.byindex[shndx],
			abs = shndx == SHN_ABS,
			common = shndx == SHN_COMMON,
			undef = shndx == 0,
		}
	end
	-- A relocation names a symbol by its number, so the table is
	-- kept in file order and the lookups below are built beside it.
	return out
end

function obj:sym(name, which)
	local by = self.byname or {}

	self.byname = by
	which = which or ".symtab"
	if not by[which] then
		local t = {}

		by[which] = t
		for _, s in ipairs(self:syms(which)) do
			-- A global definition is the answer even when a
			-- local of the same name came first.
			if s.name ~= "" and (not t[s.name] or
			    (t[s.name].undef and not s.undef) or
			    (s.bind ~= "local" and t[s.name].bind ==
			     "local")) then
				t[s.name] = s
			end
		end
	end
	return by[which][name]
end

-- Which of two symbols at the same address a reader would rather be
-- told about: one that says what it is, and then one the whole program
-- can see.  A section symbol is last, because every section has one and
-- it says nothing a name does not say better.
local function rank(s)
	local r = 0

	if s.typ == "func" or s.typ == "object" then r = r + 4 end
	if s.bind == "global" then r = r + 2 end
	if s.bind == "weak" then r = r + 1 end
	return r
end

-- Which of two names for one address to print.
function elfread.prefer(a, b)
	if not a then return b end
	if not b then return a end
	return rank(b) > rank(a) and b or a
end

-- The version each dynamic symbol answers to, which is the only thing
-- telling two definitions of one name apart.  `.gnu.version` is one
-- index per symbol, into the definitions in `.gnu.version_d` and the
-- ones asked of other libraries in `.gnu.version_r`.
function obj:versions()
	if self.vermap then return self.vermap end
	local map = {}

	self.vermap = map
	local vd, vn, vs
	for _, s in ipairs(self.sections) do
		if s.typ == "verdef" then vd = s end
		if s.typ == "verneed" then vn = s end
		if s.typ == "versym" then vs = s end
	end
	if not vs then return map end
	local function names(sec, defs)
		if not sec then return end
		local raw = self:contents(sec)
		local str = self:contents(self.byindex[sec.link] or {})
		local at = 1

		while at <= #raw do
			local cnt, aux, nxt

			if defs then
				cnt = string.unpack("<I2", raw, at + 6)
				aux = string.unpack("<I4", raw, at + 12)
				nxt = string.unpack("<I4", raw, at + 16)
				local ndx = string.unpack("<I2", raw, at + 4)
				local nameoff = string.unpack("<I4", raw,
					at + aux)

				map[ndx] = {name = cstr(str, nameoff),
					    def = true}
			else
				cnt = string.unpack("<I2", raw, at + 2)
				aux = string.unpack("<I4", raw, at + 8)
				nxt = string.unpack("<I4", raw, at + 12)
				local a = at + aux

				for _ = 1, cnt do
					local other = string.unpack("<I2",
						raw, a + 6)
					local nameoff = string.unpack("<I4",
						raw, a + 8)

					map[other] = {name = cstr(str,
						nameoff)}
					local n = string.unpack("<I4", raw,
						a + 12)

					if n == 0 then break end
					a = a + n
				end
			end
			if nxt == 0 then break end
			at = at + nxt
		end
	end

	names(vd, true)
	names(vn, false)
	map.index = {}
	local raw = self:contents(vs)

	for k = 0, #raw // 2 - 1 do
		map.index[k + 1] = string.unpack("<I2", raw, k * 2 + 1)
	end
	return map
end

-- The name a dynamic symbol is written with, version and all.
function obj:fullname(s)
	local v = self:versions()
	local ndx = v.index and v.index[s.num + 1]

	if not ndx then return s.name end
	local e = v[ndx & 0x7fff]

	-- A version definition is itself a symbol, and does not carry
	-- its own name twice.
	if not e or (ndx & 0x7fff) < 2 or e.name == s.name then
		return s.name
	end
	-- Two at signs mark the definition a caller gets when it asks
	-- for no version in particular.
	local sep = (e.def and not s.undef and ndx & 0x8000 == 0) and "@@"
		or "@"

	return s.name .. sep .. e.name
end

-- The defined symbols with an address, sorted, for `at` to search.
-- A second list per section answers a lookup that knows which section
-- the address is in, which is the only meaningful question in an
-- object, where every section starts at zero.
function obj:sorted(sec)
	if not self.byaddr then
		local all, per = {}, {}

		for _, s in ipairs(self:syms()) do
			if s.name ~= "" and s.sec and s.typ ~= "file" and
			   s.typ ~= "section" then
				all[#all + 1] = s
				per[s.sec] = per[s.sec] or {}
				local t = per[s.sec]

				t[#t + 1] = s
			end
		end
		local function order(a, b)
			if a.value ~= b.value then
				return a.value < b.value
			end
			return rank(a) > rank(b)
		end

		table.sort(all, order)
		for _, t in pairs(per) do table.sort(t, order) end
		self.byaddr, self.persec = all, per
	end
	if sec then return self.persec[sec] or {} end
	return self.byaddr
end

-- The last symbol in a sorted list at or before an address, and the
-- first of the several that may share its address.
local function search(t, addr)
	local lo, hi, best = 1, #t, nil

	while lo <= hi do
		local mid = (lo + hi) // 2

		if t[mid].value <= addr then
			lo, best = mid + 1, mid
		else
			hi = mid - 1
		end
	end
	if not best then return nil end
	while best > 1 and t[best - 1].value == t[best].value do
		best = best - 1
	end
	return t[best]
end

-- What is at an address: the nearest symbol at or before it, and how far
-- past its start the address is.  An address in a relocatable object is
-- an offset into a section, so `sec` says which one.
--
-- A symbol whose size does not reach the address is still the answer,
-- because a stub with no `.size` has none; `within` says which it was.
function obj:at(addr, sec)
	sec = sec or (self.typ ~= "rel" and self:secat(addr)) or nil
	local sym = sec and search(self:sorted(sec), addr)
	local far = false

	if not sym then
		-- Nothing in the section the address is in, so the
		-- answer comes from outside it and is worth doubting.
		sym = search(self:sorted(), addr)
		far = sym ~= nil and sym.sec ~= sec
	end
	if not sym then return nil end
	local off = addr - sym.value
	local within = sym.size == 0 or off < sym.size

	return sym, off, within, far
end

-- Which allocated section an address falls in.  An object's sections
-- all start at zero, so only a linked file can answer this.
function obj:secat(addr)
	for _, s in ipairs(self.sections) do
		if s.flags & SHF.alloc ~= 0 and s.size > 0 and
		   addr >= s.addr and addr < s.addr + s.size then
			return s
		end
	end
end

-- How far past a symbol an answer may be before it is a guess.  A
-- function this compiler emitted is rarely larger, and a symbol table
-- with a hole in it will otherwise hand back a name from far above.
local FAR = 0x2000

-- What is at an address, with a word about how much to trust it.
--
-- A local symbol the assembler dropped leaves a hole, and the nearest
-- name before the address is then the wrong function.  Nothing here
-- tells that from a large function, so `sure` says which answers are
-- worth doubting and `why` says what raised the doubt.
function obj:locate(addr, sec)
	sec = sec or (self.typ ~= "rel" and self:secat(addr)) or nil
	local sym, off, within = self:at(addr, sec)

	if not sym then
		return {addr = addr, sec = sec, sure = false,
			why = "no symbol at or before this address"}
	end
	local r = {addr = addr, sym = sym, name = sym.name, off = off,
		   sec = sec or sym.sec, within = within, sure = true}

	if sym.size > 0 and not within then
		r.sure = false
		r.why = ("past the end of %s, which is %d bytes")
			:format(sym.name, sym.size)
	elseif sym.size == 0 and off > FAR then
		r.sure = false
		r.why = ("%#x past %s, which has no size")
			:format(off, sym.name)
	end
	return r
end

-- relocations ------------------------------------------------------------

-- A relocation says where in a section it lands, which symbol it names
-- and what the linker does with the two.
-- The entries of one relocation section, whatever it applies to.
function obj:relocsin(r)
	if r.entries then return r.entries end
	local out = {}

	r.entries = out
	if r.typ ~= "rela" and r.typ ~= "rel" then return out end
	local wide = self.class == 64
	local raw = self:contents(r)
	local rela = r.typ == "rela"
	local SZ = (rela and 3 or 2) * (wide and 8 or 4)
	local syms = self:syms((self.byindex[r.link] or {}).name)

	for k = 0, #raw // SZ - 1 do
		local at = k * SZ + 1
		local off, info, add

		if wide then
			off, info = string.unpack("<I8I8", raw, at)
			if rela then
				add = string.unpack("<i8", raw, at + 16)
			end
		else
			off, info = string.unpack("<I4I4", raw, at)
			if rela then
				add = string.unpack("<i4", raw, at + 8)
			end
		end
		-- An ELFCLASS32 entry packs the symbol and the kind into
		-- one word, and puts the kind in the low byte.
		local num = wide and info >> 32 or info >> 8
		local typ = wide and info & 0xffffffff or info & 0xff

		out[#out + 1] = {
			off = off,
			typ = typ,
			name = (RTYPE[self.arch] or {})[typ] or
				("%d"):format(typ),
			symnum = num,
			sym = syms[num + 1],
			addend = add,
			from = r,
		}
	end
	return out
end

-- The relocations that apply to a section, from whichever relocation
-- section names it.
function obj:relocs(s)
	if s.relocs then return s.relocs end
	local out = {}

	s.relocs = out
	for _, r in ipairs(self.sections) do
		if (r.typ == "rela" or r.typ == "rel") and
		   r.info == s.index then
			for _, e in ipairs(self:relocsin(r)) do
				out[#out + 1] = e
			end
		end
	end
	return out
end

-- reading -----------------------------------------------------------------

function elfread.is(path, at0)
	local f = io.open(path, "rb")

	if not f then return false end
	f:seek("set", at0 or 0)
	local m = f:read(4)

	f:close()
	return m == "\127ELF"
end

-- Open a file and read everything that describes it: the header, the
-- section table, the program headers.  The contents of a section and the
-- symbol table wait until something asks for them.
--
-- `at0` is where the file starts, which is not zero for a member of an
-- archive.
function elfread.open(path, at0)
	at0 = at0 or 0
	local f, err = io.open(path, "rb")

	if not f then return nil, err end
	f:seek("set", at0)
	local eh = f:read(64) or ""

	if eh:sub(1, 4) ~= "\127ELF" then
		f:close()
		return nil, path .. ": not an ELF file"
	end
	local class = eh:byte(EI_CLASS) == 2 and 64 or 32

	if eh:byte(EI_DATA) ~= 1 then
		f:close()
		return nil, path .. ": not little endian"
	end
	local wide = class == 64
	local o = setmetatable({path = path, at0 = at0, f = f,
				class = class}, obj)
	local mach
	local shoff, phoff, shentsize, shnum, shstrndx, phentsize, phnum

	if wide then
		o.etype, mach = string.unpack("<I2I2", eh, 17)
		o.entry, phoff, shoff, o.flags = string.unpack("<I8I8I8I4",
			eh, 25)
		phentsize, phnum, shentsize, shnum, shstrndx =
			string.unpack("<I2I2I2I2I2", eh, 55)
	else
		o.etype, mach = string.unpack("<I2I2", eh, 17)
		o.entry, phoff, shoff, o.flags = string.unpack("<I4I4I4I4",
			eh, 25)
		phentsize, phnum, shentsize, shnum, shstrndx =
			string.unpack("<I2I2I2I2I2", eh, 43)
	end
	o.typ = ET[o.etype] or ("%d"):format(o.etype)
	o.machine = mach
	o.arch = MACH[mach] or ("machine %d"):format(mach)
	if o.arch == "riscv" then o.arch = wide and "riscv64" or "riscv32" end

	-- The section headers.  A file with more than 0xff00 of them puts
	-- the count in the first one, whose own fields are otherwise
	-- zero, and the same for the name table's index.
	o.sections, o.byindex = {}, {}
	if shoff > 0 and shnum >= 0 and shentsize > 0 then
		local function hdr(raw, at)
			local s = {}

			if wide then
				s.nameoff, s.shtype, s.flags, s.addr, s.off,
				s.size, s.link, s.info, s.align, s.entsize =
					string.unpack("<I4I4I8I8I8I8I4I4I8I8",
						raw, at)
			else
				s.nameoff, s.shtype, s.flags, s.addr, s.off,
				s.size, s.link, s.info, s.align, s.entsize =
					string.unpack("<I4I4I4I4I4I4I4I4I4I4",
						raw, at)
			end
			s.typ = SHT[s.shtype] or ("%#x"):format(s.shtype)
			return s
		end

		f:seek("set", at0 + shoff)
		local first = hdr(f:read(shentsize) or "", 1)

		if shnum == 0 then shnum = first.size end
		if shstrndx == SHN_XINDEX then shstrndx = first.link end
		f:seek("set", at0 + shoff)
		local raw = f:read(shentsize * shnum) or ""

		for i = 0, shnum - 1 do
			local s = hdr(raw, i * shentsize + 1)

			s.index = i
			s.unit = o
			o.sections[i + 1] = s
			o.byindex[i] = s
		end
		local shstr = ""
		local ss = o.byindex[shstrndx]

		if ss and ss.typ ~= "nobits" then
			f:seek("set", at0 + ss.off)
			shstr = f:read(ss.size) or ""
		end
		for _, s in ipairs(o.sections) do
			s.name = cstr(shstr, s.nameoff)
		end
	end

	-- The program headers, which say what the loader maps.  An object
	-- has none.
	o.segments = {}
	if phoff > 0 and phnum > 0 then
		f:seek("set", at0 + phoff)
		local raw = f:read(phentsize * phnum) or ""

		for i = 0, phnum - 1 do
			local at = i * phentsize + 1
			local p = {}

			if wide then
				p.ptype, p.flags, p.off, p.vaddr, p.paddr,
				p.filesz, p.memsz, p.align =
					string.unpack("<I4I4I8I8I8I8I8I8",
						raw, at)
			else
				p.ptype, p.off, p.vaddr, p.paddr, p.filesz,
				p.memsz, p.flags, p.align =
					string.unpack("<I4I4I4I4I4I4I4I4",
						raw, at)
			end
			p.typ = PT[p.ptype] or ("%#x"):format(p.ptype)
			p.r = p.flags & 4 ~= 0
			p.w = p.flags & 2 ~= 0
			p.x = p.flags & 1 ~= 0
			o.segments[i + 1] = p
		end
	end
	return o
end

-- The same, for a caller that would rather have an error than a nil.
function elfread.read(path, at0)
	local o, err = elfread.open(path, at0)

	return o or error(err, 2)
end

return elfread
