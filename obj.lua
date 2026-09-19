-- The object file the assembler writes and the linker reads.
--
-- It exists so that the linker does not have to hold every unit at once.
-- The header is small -- section sizes and symbols -- and says where each
-- section's bytes and relocations sit, so a pass that only needs addresses
-- reads the header alone, and a pass that writes bytes reads one section
-- at a time.
--
--	"CO1\0" arch "\0" u32 headerlen header body

local obj = {}

local MAGIC = "CO1\0"

-- Relocations name their kind by number, which keeps the table small.
local KIND = {"abs64", "abs32", "branch", "jal", "pcrel_hi20",
	      "pcrel_lo12_i", "pcrel_lo12_jalr", "xt_call",
	      "pc32", "plt32", "gotpcrel",
	      "a64_adrp", "a64_add_lo12", "a64_ldst8_lo12",
	      "a64_ldst16_lo12", "a64_ldst32_lo12", "a64_ldst64_lo12",
	      "a64_call26", "a64_jump26", "a64_condbr19"}
local KINDNO = {}
for i, k in ipairs(KIND) do KINDNO[k] = i end

local function packrelocs(rs, symno)
	local out = {}
	for i, r in ipairs(rs) do
		out[i] = string.pack("<I4I1I4i4I4", r.off,
			KINDNO[r.kind] or error("no kind " .. r.kind),
			symno[r.sym], r.addend or 0,
			r.pair and r.pair + 1 or 0)
	end
	return table.concat(out)
end

-- Write one assembled unit.  Symbols come first so that the reader can name
-- what a relocation points at; an undefined one is there by name only.
function obj.write(a, arch)
	local syms, symno, names = {}, {}, {}
	local function want(name)
		if symno[name] then return symno[name] end
		syms[#syms + 1] = name
		symno[name] = #syms
		return #syms
	end
	-- A label the assembler resolved on its own is of no use here, and
	-- most of a unit's labels are those.  Only what is global, or what
	-- a relocation names, is worth carrying.
	for name, d in pairs(a.syms) do
		if d.global then want(name) end
	end
	for _, s in ipairs(a.order) do
		for _, r in ipairs(s.relocs) do want(r.sym) end
	end

	local secno = {}
	for i, s in ipairs(a.order) do secno[s] = i end

	-- the body, so that the header can say where each piece landed
	local body, at, meta = {}, 0, {}
	for i, s in ipairs(a.order) do
		local bytes = s.bss and "" or (s.bytes or "")
		local rel = packrelocs(s.relocs, symno)
		local sys = {}

		for k, c in ipairs(s.syscalls or {}) do
			sys[k] = string.pack("<I4I4", c.off, c.sysno)
		end
		sys = table.concat(sys)
		meta[i] = {pos = at, len = #bytes, relpos = at + #bytes,
			   nrel = #s.relocs, nsys = #(s.syscalls or {}),
			   syspos = at + #bytes + #rel}
		body[#body + 1] = bytes
		body[#body + 1] = rel
		body[#body + 1] = sys
		at = at + #bytes + #rel + #sys
	end

	local h = {string.pack("<I4", #a.order)}
	for i, s in ipairs(a.order) do
		local m = meta[i]
		h[#h + 1] = string.pack("<zI4I4I1I4I4I4I4I4I1", s.name,
			s.size, s.align, s.bss and 1 or 0, m.pos, m.nrel,
			m.relpos, m.nsys, m.syspos, s.perm or 6)
	end
	h[#h + 1] = string.pack("<I4", #syms)
	for _, name in ipairs(syms) do
		local d = a.syms[name]
		h[#h + 1] = string.pack("<zI4I4I1", name,
			(d and d.sec) and secno[d.sec] or 0,
			(d and d.sec) and d.off or 0,
			-- 0 undefined, 1 local, 2 global, 3 weak,
			-- 4 undefined and weak, which stands for nothing
			(d and d.sec) and (d.weak and 3 or
				(d.global and 2 or 1)) or
				((d and d.weak) and 4 or 0))
	end
	h = table.concat(h)
	return MAGIC .. (arch or "riscv") .. "\0" ..
		string.pack("<I4", #h) .. h .. table.concat(body)
end

-- The header alone: what the pass that hands out addresses needs.  With
-- `light` the symbols are skipped, which is all a first look at the sizes
-- wants.
-- `at0` is where the object starts inside the file, which is not zero
-- for a member of an archive.
function obj.header(path, light, at0)
	at0 = at0 or 0
	local f = assert(io.open(path, "rb"))
	f:seek("set", at0)
	local head = f:read(4 + 64)
	if not head or head:sub(1, 4) ~= MAGIC then
		f:close()
		error(path .. " is not an object file")
	end
	local arch, at = string.unpack("<z", head, 5)
	local hlen = string.unpack("<I4", head, at)
	at = at + 4
	f:seek("set", at0 + at - 1)
	local h = f:read(hlen)
	f:close()

	local u = {path = path, arch = arch, at0 = at0,
		   base = at0 + at - 1 + hlen, order = {}, syms = {},
		   weak = {}}
	local n, i = string.unpack("<I4", h, 1)
	for k = 1, n do
		local name, size, alg, bss, pos, nrel, relpos
		local nsys, syspos, perm
		name, size, alg, bss, pos, nrel, relpos, nsys, syspos,
		perm, i = string.unpack("<zI4I4I1I4I4I4I4I4I1", h, i)
		u.order[k] = {name = name, size = size, align = alg,
			      bss = bss == 1, pos = pos, nrel = nrel,
			      relpos = relpos, nsys = nsys, syspos = syspos,
			      perm = perm, relocs = {}, unit = u}
	end
	if light then return u end
	local m
	m, i = string.unpack("<I4", h, i)
	u.symnames = {}
	for k = 1, m do
		local name, sec, off, kind
		name, sec, off, kind, i = string.unpack("<zI4I4I1", h, i)
		u.symnames[k] = name
		if kind == 4 then
			u.weak[name] = true
		elseif kind ~= 0 then
			u.syms[name] = {sec = u.order[sec], off = off,
					weak = kind == 3,
					global = kind >= 2}
		end
	end
	return u
end

-- Where each system call instruction of a section stands, and which
-- call it makes.  A kernel that pins them down asks for this.
function obj.syscalls(u, s)
	if not s.nsys or s.nsys == 0 then return {} end
	local f = assert(io.open(u.path, "rb"))

	f:seek("set", u.base + s.syspos)
	local raw = f:read(s.nsys * 8) or ""

	f:close()
	local out, i = {}, 1
	for k = 1, s.nsys do
		local off, no

		off, no, i = string.unpack("<I4I4", raw, i)
		out[k] = {off = off, sysno = no}
	end
	return out
end

-- One section's bytes and relocations, read when they are about to be
-- written out.  The relocations come back rather than being kept on the
-- section, which outlives them.
function obj.section(u, s, names)
	local f = assert(io.open(u.path, "rb"))
	f:seek("set", u.base + s.pos)
	local bytes = s.bss and "" or (f:read(s.len or s.size) or "")
	f:seek("set", u.base + s.relpos)
	local rel = s.nrel > 0 and f:read(s.nrel * 17) or ""
	f:close()
	local relocs, i = {}, 1
	for k = 1, s.nrel do
		local off, kind, sym, addend, pair
		off, kind, sym, addend, pair, i =
			string.unpack("<I4I1I4i4I4", rel, i)
		relocs[k] = {off = off, kind = KIND[kind],
			     sym = (names or u.symnames)[sym],
			     addend = addend,
			     pair = pair > 0 and pair - 1 or nil}
	end
	return bytes, relocs
end

-- The whole unit in memory, in the shape the assembler leaves behind.
function obj.read(path, at0)
	local u = obj.header(path, false, at0)
	for _, s in ipairs(u.order) do
		s.bytes, s.relocs = obj.section(u, s)
	end
	return u
end

return obj
