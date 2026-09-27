-- SPDX-License-Identifier: ISC
-- Disassembly: bytes to instructions, one machine at a time.
--
-- Each machine is a module with one entry point, `decode`, which
-- answers the instruction at an offset or nil when the bytes run out.
-- What comes back says enough to follow control flow: the length, the
-- text, and where a branch or a call goes.

local dis = {}

-- The machines there is a decoder for.  A target with none says so
-- rather than printing something that is not the instruction.
local ARCH = {amd64 = "amd64"}

function dis.arch(name)
	local mod = ARCH[name]

	if not mod then return nil, "no disassembler for " .. name end
	return require("mcc.dis." .. mod)
end

-- Walk a block of bytes as instructions.  `addr` is where the first
-- byte stands, so a branch target comes out as an address and not as a
-- distance.  A byte no instruction starts with is one byte long and
-- says so, which keeps a decode that lost its place from running away.
function dis.each(m, bytes, addr, from, to)
	local at = (from or 0) + 1
	local last = (to or #bytes)

	return function()
		if at > last then return nil end
		local pos = at - 1
		local ins = m.decode(bytes, at, addr + pos)

		if not ins then
			-- Fewer bytes left than the instruction needs.
			local rest = last - pos

			at = last + 1
			return pos, {len = rest, mnem = "(bad)", ops = {},
				     text = "(bad)", bad = true,
				     bytes = bytes:sub(pos + 1, last)}
		end
		at = at + ins.len
		return pos, ins
	end
end

-- Where the addresses of a section's bytes start.  In a relocatable
-- object every section starts at zero, so an address there is an offset
-- into one and the section has to be named beside it.
local function basof(f, sec)
	return f.typ == "rel" and 0 or sec.addr
end

-- Where each instruction of a section begins.  An address only means
-- anything once something has decoded from a known start to it, which
-- is what this does.
local function walk(m, bytes, base, from, upto)
	local out = {}

	for off, ins in dis.each(m, bytes, base, from - base, #bytes) do
		local a = base + off

		out[#out + 1] = {addr = a, ins = ins}
		if a >= upto then break end
	end
	return out
end

-- How far back to decode from when no symbol says where to start.
local BACK = 64

-- The instructions around an address, and whose they are.  The walk
-- starts at the symbol the address belongs to, the only place in the
-- middle of a section an instruction is known to begin.  A walk that
-- never lands on the address disagrees with it about where the
-- instructions are: `sync` is then false and what comes back is read
-- from the address itself, which may be nonsense.
function dis.window(f, addr, n)
	n = n or 8
	local m, err = dis.arch(f.arch)

	if not m then return nil, err end
	local loc = f:locate(addr)
	local sec = loc.sec

	if not sec then return nil, "no section holds that address" end
	local bytes = f:contents(sec)
	local base = basof(f, sec)

	if addr < base or addr >= base + #bytes then
		return nil, "that address is not in this file"
	end
	-- A symbol's value is an address in a linked file and an offset
	-- into its own section in an object, which is what an address
	-- means in each.
	local start = loc.sym and loc.sym.sec == sec and loc.sym.value

	if not start or start > addr or addr - start > 0x4000 then
		start = math.max(base, addr - BACK)
	end
	local list = walk(m, bytes, base, start, addr)
	local at

	for i, e in ipairs(list) do
		if e.addr == addr then
			at = i
			break
		end
	end
	local sync = at ~= nil

	if not sync then
		list = walk(m, bytes, base, addr, addr)
		at = 1
		loc.sure = false
		loc.why = loc.why or
			"no instruction boundary reaches this address"
	end
	-- What follows, decoded onward from the one at the address.
	local upto = list[#list] and list[#list].addr or addr
	local more = walk(m, bytes, base, upto, upto + 16 * (n + 1))

	for i = 2, #more do list[#list + 1] = more[i] end
	local out = {}
	local from = math.max(1, at - n)

	for i = from, math.min(#list, at + n) do
		out[#out + 1] = list[i]
	end
	return {loc = loc, sync = sync, sec = sec, arch = f.arch,
		at = at - from + 1, list = out}
end

-- Where control may go from one instruction: the next one, and the
-- branch target when the instruction has one.  An indirect branch
-- answers only what it is, because the target is in a register.
function dis.follow(ins, addr)
	local next = addr + ins.len

	if ins.kind == "ret" then return {} end
	if ins.indirect then return {}, true end
	if ins.kind == "jmp" then return {ins.target} end
	if ins.kind == "call" or ins.kind == "jcc" then
		return {next, ins.target}
	end
	return {next}
end

return dis
