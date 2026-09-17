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

local ld = {}

-- The order sections are placed in, and what may follow them.
local ORDER = {".text", ".rodata", ".data", ".sdata", ".bss"}

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
function ld.layout(units, base)
	local secs, globals = {}, {}
	for _, a in ipairs(units) do
		for _, s in ipairs(a.order) do
			s.unit = a
			secs[#secs + 1] = s
		end
	end
	table.sort(secs, function(x, y)
		return rank(x.name) < rank(y.name)
	end)
	local addr = base
	for _, s in ipairs(secs) do
		addr = align(addr, math.max(s.align, 1))
		s.addr = addr
		addr = addr + s.size
	end
	for _, a in ipairs(units) do
		a.addrs = {}
		for name, d in pairs(a.syms) do
			if d.sec then
				a.addrs[name] = d.sec.addr + d.off
				if d.global then
					if globals[name] then
						error("two definitions of " ..
							name)
					end
					globals[name] = a.addrs[name]
				end
			end
		end
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
	return secs, globals, addr
end

local function patch(bytes, off, word)
	return bytes:sub(1, off) ..
	       string.char(word & 255, word >> 8 & 255,
			   word >> 16 & 255, word >> 24 & 255) ..
	       bytes:sub(off + 5)
end

local function put(bytes, off, v, n)
	local b = {}
	for i = 0, n - 1 do b[i + 1] = string.char(v >> (8 * i) & 255) end
	return bytes:sub(1, off) .. table.concat(b) .. bytes:sub(off + n + 1)
end

local function word(bytes, off)
	local a, b, c, d = bytes:byte(off + 1, off + 4)
	return a | b << 8 | c << 16 | d << 24
end

-- Fill in every place that needed an address.  The list of absolute ones
-- comes back, because a loader that moves the program has to add its base
-- to each.
function ld.relocate(secs, globals)
	local absolute = {}
	for _, s in ipairs(secs) do
		local bytes = s.bytes
		local hi = {}
		local own = s.unit and s.unit.addrs or {}
		for _, r in ipairs(s.relocs) do
			local target = own[r.sym] or globals[r.sym]
			if not target then
				error("undefined symbol " .. r.sym)
			end
			target = target + r.addend
			local here = s.addr + r.off
			local k = r.kind
			if k == "abs64" then
				bytes = put(bytes, r.off, target, 8)
				absolute[#absolute + 1] = {s.addr + r.off, 8}
			elseif k == "abs32" then
				bytes = put(bytes, r.off, target, 4)
				absolute[#absolute + 1] = {s.addr + r.off, 4}
			elseif k == "branch" then
				local d = target - here
				local w = word(bytes, r.off)
				w = w & 0x01fff07f
				w = w | ((d >> 12) & 1) << 31
				w = w | ((d >> 5) & 0x3f) << 25
				w = w | ((d >> 1) & 0xf) << 8
				w = w | ((d >> 11) & 1) << 7
				bytes = patch(bytes, r.off, w)
			elseif k == "jal" then
				local d = target - here
				local w = word(bytes, r.off) & 0x00000fff
				w = w | ((d >> 20) & 1) << 31
				w = w | ((d >> 1) & 0x3ff) << 21
				w = w | ((d >> 11) & 1) << 20
				w = w | ((d >> 12) & 0xff) << 12
				bytes = patch(bytes, r.off, w)
			elseif k == "pcrel_hi20" then
				local d = target - here
				hi[r.off] = d
				local w = word(bytes, r.off) & 0x00000fff
				w = w | ((((d + 0x800) // 4096) & 0xfffff) << 12)
				bytes = patch(bytes, r.off, w)
			elseif k == "pcrel_lo12_i" or k == "pcrel_lo12_jalr" then
				local d = hi[r.pair]
				if not d then
					error("a low half with no auipc")
				end
				local lo = (d + 0x800) % 4096 - 0x800
				local w = word(bytes, r.off) & 0x000fffff
				w = w | ((lo & 0xfff) << 20)
				bytes = patch(bytes, r.off, w)
			else
				error("no relocation " .. k)
			end
		end
		s.bytes = bytes
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

-- A static executable with one loadable segment.  Nothing here needs a
-- section table: the loader reads the program headers.
function ld.elf(secs, entry, base, endaddr, target)
	local bits = (target == "riscv32") and 32 or 64
	local ehsize = bits == 64 and 64 or 52
	local phsize = bits == 64 and 56 or 32
	local start = ehsize + phsize
	local out = buf.new()

	-- the file image, at the addresses layout gave them
	local filesz = 0
	local body = buf.new()
	local at = base + start
	for _, s in ipairs(secs) do
		if not s.bss then
			if s.addr < at then error("sections overlap") end
			body:add(string.rep("\0", s.addr - at))
			body:add(s.bytes)
			at = s.addr + s.size
		end
	end
	filesz = at - base
	local memsz = endaddr - base

	out:add("\127ELF")
	out:add(string.char(bits == 64 and 2 or 1, 1, 1, 0))
	out:add(string.rep("\0", 8))
	out:add(u(2, 2))			-- ET_EXEC
	out:add(u(EM[target] or 243, 2))
	out:add(u(1, 4))
	if bits == 64 then
		out:add(u(entry, 8))
		out:add(u(ehsize, 8))		-- phoff
		out:add(u(0, 8))		-- shoff
	else
		out:add(u(entry, 4))
		out:add(u(ehsize, 4))
		out:add(u(0, 4))
	end
	out:add(u(target == "riscv64" and 4 or 0, 4))	-- e_flags
	out:add(u(ehsize, 2))
	out:add(u(phsize, 2))
	out:add(u(1, 2))			-- one program header
	out:add(u(bits == 64 and 64 or 40, 2))
	out:add(u(0, 2))
	out:add(u(0, 2))

	if bits == 64 then
		out:add(u(1, 4))		-- PT_LOAD
		out:add(u(7, 4))		-- rwx
		out:add(u(0, 8))		-- offset
		out:add(u(base, 8))		-- vaddr
		out:add(u(base, 8))		-- paddr
		out:add(u(filesz, 8))
		out:add(u(memsz, 8))
		out:add(u(0x1000, 8))
	else
		out:add(u(1, 4))
		out:add(u(0, 4))
		out:add(u(base, 4))
		out:add(u(base, 4))
		out:add(u(filesz, 4))
		out:add(u(memsz, 4))
		out:add(u(7, 4))
		out:add(u(0x1000, 4))
	end
	out:add(body:text())
	return out:text()
end

-- Link one or more assembled units into a static executable.
function ld.link(units, opt)
	opt = opt or {}
	local base = opt.base or 0x10000
	local target = opt.target or "riscv64"
	local bits = (target == "riscv32") and 32 or 64
	local start = (bits == 64 and 64 + 56) or (52 + 32)
	local secs, globals, endaddr = ld.layout(units, base + start)
	local absolute = ld.relocate(secs, globals)
	local entry = globals[opt.entry or "_start"]
	if not entry then error("no entry symbol") end
	return ld.elf(secs, entry, base, endaddr, target), globals, absolute
end

return ld
