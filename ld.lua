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
	local addr, pinned = base, {}
	for _, s in ipairs(secs) do
		local at = place[s.name]
		if at then
			s.addr = align(pinned[s.name] or at,
				math.max(s.align, 1))
			pinned[s.name] = s.addr + s.size
		else
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

local EM = {riscv64 = 243, riscv32 = 243, amd64 = 62, xtensa = 94}

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
		if cur and s.addr >= cur.addr and
		   s.addr - cur["end"] <= 0x1000 then
			cur[#cur + 1] = s
			cur["end"] = s.addr + s.size
		else
			cur = {s, addr = s.addr, ["end"] = s.addr + s.size}
			segs[#segs + 1] = cur
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
function ld.elf(w, secs, entry, base, endaddr, target, segs, detached, bytes)
	local bits = (target == "riscv32" or target == "xtensa") and 32 or 64
	local ehsize = bits == 64 and 64 or 52
	local phsize = bits == 64 and 56 or 32
	segs = segs or ld.segments(secs, base, detached)
	local start = ehsize + #segs * phsize

	-- where each segment's bytes go, which the sizes alone decide
	local at = start
	for _, g in ipairs(segs) do
		local hdr = g.headers and start or 0
		local last = g.addr + hdr
		for _, s in ipairs(g) do
			if not s.bss then last = s.addr + s.size end
		end
		g.offset = g.headers and 0 or at
		g.filesz = last - g.addr
		g.memsz = g["end"] - g.addr
		if g.headers then
			g.memsz = math.max(g.memsz, endaddr - g.addr)
		end
		at = at + (last - g.addr - hdr)
	end

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
	w:write(u(#segs, 2))
	w:write(u(bits == 64 and 64 or 40, 2))
	w:write(u(0, 2))
	w:write(u(0, 2))

	for _, g in ipairs(segs) do
		if bits == 64 then
			w:write(u(1, 4))	-- PT_LOAD
			w:write(u(7, 4))	-- rwx
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
			w:write(u(7, 4))
			w:write(u(0x1000, 4))
		end
	end

	for _, g in ipairs(segs) do
		local here = g.addr + (g.headers and start or 0)
		for _, s in ipairs(g) do
			if not s.bss then
				if s.addr < here then
					error("sections overlap")
				end
				w:write(string.rep("\0", s.addr - here))
				w:write(bytes(s))
				here = s.addr + s.size
			end
		end
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
		local again = #segs ~= n
		n = #segs
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

	-- The sizes alone decide where everything goes, so the first look at
	-- each object skips its symbols.
	local units = {}
	for i, p in ipairs(paths) do units[i] = obj.header(p, true) end

	local secs, endaddr, segs
	local n = 1
	repeat
		local start = ehsize + n * phsize
		secs, endaddr = ld.place(units,
			detached and base or (base + start), opt.place)
		segs = ld.segments(secs, base, detached)
		local again = #segs ~= n
		n = #segs
	until not again

	-- Then the global symbols, one object at a time: what a unit says
	-- about its own labels is read again when its bytes go out.
	local globals = {}
	for i, u in ipairs(units) do
		local h = obj.header(paths[i])
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
	for i, u in ipairs(units) do u.path = paths[i] end

	-- The list of absolute words is for a loader that moves the program;
	-- a static executable has no use for it and it is as long as the
	-- relocations are.
	local absolute = opt.absolute and {} or nil
	local at, own, names = nil, nil, nil
	ld.elf(w, secs, entry, base, endaddr, target, segs, detached,
		function(s)
			local u = s.unit
			if at ~= u then
				local h = obj.header(u.path)
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
		end)
	return globals, absolute
end

return ld
