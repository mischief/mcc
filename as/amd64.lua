-- amd64, for what target/amd64 produces.
--
-- Sixty mnemonics in the forms that file emits, which is far short of the
-- machine but enough to assemble everything this compiler writes, and
-- little enough to be checked against the real assembler byte for byte.
--
-- An instruction is a REX byte, an opcode, a ModRM byte, sometimes a SIB
-- byte, a displacement and an immediate.  Everything below builds that.

local as = require "as"

local amd64 = {}

local R64 = {"rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
	     "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"}
local R32 = {"eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi"}
local R16 = {"ax", "cx", "dx", "bx", "sp", "bp", "si", "di"}
local R8 = {"al", "cl", "dl", "bl", "spl", "bpl", "sil", "dil"}

local REG = {}
for i, n in ipairs(R64) do REG[n] = {num = i - 1, size = 8} end
for i, n in ipairs(R32) do REG[n] = {num = i - 1, size = 4} end
for i, n in ipairs(R16) do REG[n] = {num = i - 1, size = 2} end
for i, n in ipairs(R8) do REG[n] = {num = i - 1, size = 1} end
for i = 8, 15 do
	REG["r" .. i .. "d"] = {num = i, size = 4}
	REG["r" .. i .. "w"] = {num = i, size = 2}
	REG["r" .. i .. "b"] = {num = i, size = 1}
end
-- the four that need no REX, and must not have one
local NOREX = {ah = 4, ch = 5, dh = 6, bh = 7}
for n, v in pairs(NOREX) do REG[n] = {num = v, size = 1, norex = true} end

local XMM = {}
for i = 0, 15 do XMM["xmm" .. i] = i end

-- operands ------------------------------------------------------------

-- The segment registers, which only `mov` and `push` name.
local SEG = {es = 0, cs = 1, ss = 2, ds = 3, fs = 4, gs = 5}

local function operand(s)
	if s:sub(1, 1) == "$" then
		local body = s:sub(2)

		return {kind = "imm", val = tonumber(body) or
			as.evalexpr(body) or
			error("bad immediate " .. s)}
	end
	if s:sub(1, 1) == "*" then
		local o = operand(s:sub(2))
		o.indirect = true
		return o
	end
	if s:sub(1, 1) == "%" then
		local n = s:sub(2)
		if XMM[n] then return {kind = "xmm", num = XMM[n]} end
		-- The control and debug registers, which only a kernel
		-- names and only `mov` reaches.
		local ctl, no = n:match("^(cr)(%d+)$")

		if not ctl then ctl, no = n:match("^(dr)(%d+)$") end
		if ctl then
			return {kind = ctl, num = tonumber(no)}
		end
		if SEG[n] then return {kind = "seg", num = SEG[n]} end
		local r = REG[n] or error("no register " .. s)
		return {kind = "reg", num = r.num, size = r.size,
			norex = r.norex}
	end
	-- memory: an optional displacement or symbol, then a base register
	local disp, base = s:match("^(.-)%((%%[%w]+)%)$")
	if base then
		local b = base:sub(2)
		if b == "rip" then
			local sym, at = disp:match("^([%w.$_]+)@?(%w*)$")
			if not sym then error("bad rip operand " .. s) end
			return {kind = "mem", rip = true, sym = sym,
				got = at == "GOTPCREL"}
		end
		local r = REG[b] or error("no register " .. base)
		return {kind = "mem", base = r.num,
			disp = disp == "" and 0 or (tonumber(disp) or
				error("bad displacement " .. s))}
	end
	return {kind = "sym", sym = s}
end

-- encoding -------------------------------------------------------------

local function byte(a, v) a:emit(v & 255, 1) end

local function imm(a, v, n)
	a:emit(v & ((1 << (8 * n)) - 1), n)
end

-- One instruction: `op` is the opcode bytes, `reg` the ModRM.reg field
-- (a register number or an opcode extension), `rm` the other operand.
local function insn(a, o)
	local size = o.size or 8
	local rm, reg = o.rm, o.reg or 0
	local rexb, rexx, rexr = 0, 0, 0

	if rm.kind == "reg" or rm.kind == "xmm" then
		rexb = (rm.num >= 8) and 1 or 0
	elseif rm.kind == "mem" and rm.base then
		rexb = (rm.base >= 8) and 1 or 0
	end
	if type(reg) == "table" then
		rexr = (reg.num >= 8) and 1 or 0
		reg = reg.num & 7
	else
		rexr = 0
	end

	if o.osize == 2 then byte(a, 0x66) end
	for _, p in ipairs(o.prefix or {}) do byte(a, p) end

	local rexw = o.rexw and 1 or 0
	local need = rexw == 1 or rexr == 1 or rexx == 1 or rexb == 1 or
		o.rex
	if need then
		byte(a, 0x40 | rexw << 3 | rexr << 2 | rexx << 1 | rexb)
	end
	for _, b in ipairs(o.op) do byte(a, b) end

	if o.norm then
		if o.imm then imm(a, o.imm, o.immsize) end
		return
	end

	if rm.kind == "reg" or rm.kind == "xmm" then
		byte(a, 0xc0 | reg << 3 | (rm.num & 7))
	elseif rm.rip then
		byte(a, 0x00 | reg << 3 | 5)
		-- a label this section owns needs no help from the linker
		local rel = not rm.got and a:localhere(rm.sym) or nil

		if rel then
			imm(a, rel - 4 - (o.immsize or 0), 4)
		else
			a:reloc(rm.got and "gotpcrel" or "pc32", rm.sym,
				-4 - (o.immsize or 0))
			imm(a, 0, 4)
		end
	else
		local b = rm.base & 7
		local mod
		if rm.disp == 0 and b ~= 5 then
			mod = 0
		elseif rm.disp >= -128 and rm.disp <= 127 then
			mod = 1
		else
			mod = 2
		end
		byte(a, mod << 6 | reg << 3 | (b == 4 and 4 or b))
		if b == 4 then byte(a, 0x24) end	-- SIB: base, no index
		if mod == 1 then imm(a, rm.disp, 1) end
		if mod == 2 then imm(a, rm.disp, 4) end
	end
	if o.imm then imm(a, o.imm, o.immsize) end
end

-- tables ---------------------------------------------------------------

-- op src,dst for the eight arithmetic forms: {rm<-reg, reg<-rm, /ext}
local ARITH = {
	add = {0x00, 0x02, 0},
	["or"] = {0x08, 0x0a, 1},
	["and"] = {0x20, 0x22, 4},
	sub = {0x28, 0x2a, 5},
	xor = {0x30, 0x32, 6},
	cmp = {0x38, 0x3a, 7},
}
-- F7 /ext, one operand
local UNARY = {["not"] = 2, neg = 3, mul = 4, imul = 5, div = 6, idiv = 7}
-- C1 /ext and D3 /ext
local SHIFT = {rol = 0, ror = 1, shl = 4, shr = 5, sar = 7}
local CC = {
	o = 0, no = 1, b = 2, ae = 3, e = 4, ne = 5, be = 6, a = 7,
	s = 8, ns = 9, p = 10, np = 11, l = 12, ge = 13, le = 14, g = 15,
}
local SIZE = {b = 1, w = 2, l = 4, q = 8}

local function split(m)
	local base, suffix = m:match("^(.-)([bwlq])$")
	if base and SIZE[suffix] and (ARITH[base] or UNARY[base] or
	    SHIFT[base] or base == "mov" or base == "lea" or base == "test" or
	    base == "push" or base == "pop" or base == "movabs" or
	    base == "bswap" or base == "xadd" or base == "cmpxchg" or
	    base == "xchg" or base == "inc" or base == "dec" or
	    base == "in" or base == "out") then
		return base, SIZE[suffix]
	end
	return m, nil
end

-- A prefix byte, which may stand on its own line or share one with the
-- instruction it prefixes.
local PREFIX = {["rep"] = {0xf3}, repe = {0xf3}, repz = {0xf3},
		repne = {0xf2}, repnz = {0xf2}, ["lock"] = {0xf0}}

-- The string instructions.  Their operands say nothing the opcode does
-- not already say, so gas takes them or leaves them and so does this.
local STRING = {
	insb = {0x6c}, insw = {0x66, 0x6d}, insl = {0x6d},
	outsb = {0x6e}, outsw = {0x66, 0x6f}, outsl = {0x6f},
	movsb = {0xa4}, movsw = {0x66, 0xa5}, movsl = {0xa5},
	movsq = {0x48, 0xa5},
	stosb = {0xaa}, stosw = {0x66, 0xab}, stosl = {0xab},
	stosq = {0x48, 0xab},
	lodsb = {0xac}, lodsw = {0x66, 0xad}, lodsl = {0xad},
	lodsq = {0x48, 0xad},
	scasb = {0xae}, scasw = {0x66, 0xaf}, scasl = {0xaf},
	scasq = {0x48, 0xaf},
	cmpsb = {0xa6}, cmpsw = {0x66, 0xa7}, cmpsl = {0xa7},
	cmpsq = {0x48, 0xa7},
}

-- The VIA padlock unit.  Everything but xstore carries an F3 of its own,
-- which the `rep` these are written with must not repeat.
local PADLOCK = {
	xstore = {0x0f, 0xa7, 0xc0}, xstorerng = {0x0f, 0xa7, 0xc0},
	xcryptecb = {0xf3, 0x0f, 0xa7, 0xc8},
	xcryptcbc = {0xf3, 0x0f, 0xa7, 0xd0},
	xcryptctr = {0xf3, 0x0f, 0xa7, 0xd8},
	xcryptcfb = {0xf3, 0x0f, 0xa7, 0xe0},
	xcryptofb = {0xf3, 0x0f, 0xa7, 0xe8},
	montmul = {0xf3, 0x0f, 0xa6, 0xc0},
	xsha1 = {0xf3, 0x0f, 0xa6, 0xc8},
	xsha256 = {0xf3, 0x0f, 0xa6, 0xd0},
}

function amd64.inst(a, m, ops)
	if PREFIX[m] and #ops > 0 then
		local rest = table.concat(ops, ",")
		local nm, tail = rest:match("^%s*([%w_]+)%s*(.*)$")

		if nm then
			local pre, tgt = PREFIX[m], PADLOCK[nm]

			-- a prefix the instruction already carries is not
			-- written twice
			if not tgt or tgt[1] ~= pre[1] then
				for _, b in ipairs(pre) do byte(a, b) end
			end
			local no = {}
			for t in tail:gmatch("[^,]+") do
				no[#no + 1] = t
			end
			return amd64.inst(a, nm, no)
		end
	end
	if STRING[m] or PADLOCK[m] then
		for _, b in ipairs(STRING[m] or PADLOCK[m]) do byte(a, b) end
		return
	end
	local base, size = split(m)
	local o = {}
	for i, t in ipairs(ops) do o[i] = operand(t) end

	-- A mnemonic with no size letter takes its size from a register
	-- operand, which is what gas does.
	if not size then
		for _, x in ipairs(o) do
			if x.kind == "reg" then
				size = x.size
				break
			end
		end
	end

	-- Remember a constant moved into the call number register, for the
	-- table of system call sites a kernel may ask for.
	if base == "mov" and #o == 2 and o[1].kind == "imm" and
	   o[2].kind == "reg" and o[2].num == 0 then
		a.lasteax = o[1].val
	elseif base ~= "nop" and base ~= "syscall" then
		a.lasteax = nil
	end

	local function rexw() return size == 8 end
	local function osize() return size == 2 and 2 or nil end
	-- a byte operation that names one of the low four registers by its
	-- new name needs REX to mean that register and not ah..bh
	local function needrex(x)
		return size == 1 and x and x.kind == "reg" and
			x.num >= 4 and x.num < 8
	end

	-- Moving to or from a control or debug register: the number goes
	-- in the reg field, and the operand size is always eight bytes.
	if base == "mov" and #o == 2 then
		local CTL = {cr = {0x20, 0x22}, dr = {0x21, 0x23}}
		local src, dst = o[1], o[2]

		if CTL[dst.kind] then
			return insn(a, {op = {0x0f, CTL[dst.kind][2]},
				reg = {num = dst.num}, rm = src, size = 8})
		end
		if CTL[src.kind] then
			return insn(a, {op = {0x0f, CTL[src.kind][1]},
				reg = {num = src.num}, rm = dst, size = 8})
		end
		-- A segment register moves to or from a 16 bit place, and
		-- the assembler writes no operand size prefix for it.
		if dst.kind == "seg" then
			return insn(a, {op = {0x8e}, reg = {num = dst.num},
				rm = src, size = 2})
		end
		if src.kind == "seg" then
			return insn(a, {op = {0x8c}, reg = {num = src.num},
				rm = dst, size = 2,
				osize = dst.size == 2 and 2 or nil})
		end
	end
	if m == "movd" or m == "movq" then
		local src, dst = o[1], o[2]

		if src.kind == "xmm" or dst.kind == "xmm" then
			return amd64.sse(a, src, dst, m == "movq")
		end
	end
	if base == "mov" then
		local src, dst = o[1], o[2]
		if src.kind == "imm" then
			-- a register destination takes the short form, which
			-- carries the value straight after the opcode
			if dst.kind == "reg" and size < 8 then
				return insn(a, {
					op = {(size == 1 and 0xb0 or 0xb8) +
						(dst.num & 7)},
					reg = 0, rm = dst, norm = true,
					osize = osize(), rex = needrex(dst),
					imm = src.val, immsize = size})
			end
			return insn(a, {op = {size == 1 and 0xc6 or 0xc7},
				reg = 0, rm = dst, size = size,
				rexw = rexw(), osize = osize(),
				rex = needrex(dst),
				imm = src.val,
				immsize = size == 1 and 1 or
					(size == 2 and 2 or 4)})
		end
		if src.kind == "reg" then
			return insn(a, {op = {size == 1 and 0x88 or 0x89},
				reg = src, rm = dst, size = size,
				rexw = rexw(), osize = osize(),
				rex = needrex(src) or needrex(dst)})
		end
		return insn(a, {op = {size == 1 and 0x8a or 0x8b},
			reg = dst, rm = src, size = size, rexw = rexw(),
			osize = osize(), rex = needrex(dst)})
	end
	if base == "movabs" then
		local dst = o[2]
		return insn(a, {op = {0xb8 + (dst.num & 7)}, reg = 0,
			rm = dst, rexw = true, norm = true,
			imm = o[1].val, immsize = 8})
	end
	if base == "lea" then
		return insn(a, {op = {0x8d}, reg = o[2], rm = o[1],
			size = size, rexw = rexw(), osize = osize()})
	end
	if ARITH[base] then
		local d = ARITH[base]
		local src, dst = o[1], o[2]
		if src.kind == "imm" then
			-- the short form when the value fits a byte, which
			-- is what the real assembler picks
			if size ~= 1 and src.val >= -128 and src.val <= 127
			then
				return insn(a, {op = {0x83}, reg = d[3],
					rm = dst, size = size,
					rexw = rexw(), osize = osize(),
					imm = src.val, immsize = 1})
			end
			-- the accumulator has a form of its own with no
			-- ModRM byte, which is what the real assembler picks
			if dst.kind == "reg" and dst.num == 0 then
				return insn(a, {
					op = {d[1] + (size == 1 and 4 or 5)},
					reg = 0, rm = dst, norm = true,
					rexw = rexw(), osize = osize(),
					imm = src.val,
					immsize = size == 1 and 1 or
						(size == 2 and 2 or 4)})
			end
			return insn(a, {op = {size == 1 and 0x80 or 0x81},
				reg = d[3], rm = dst, size = size,
				rexw = rexw(), osize = osize(),
				rex = needrex(dst),
				imm = src.val,
				immsize = size == 1 and 1 or
					(size == 2 and 2 or 4)})
		end
		if src.kind == "reg" then
			return insn(a, {op = {d[1] + (size == 1 and 0 or 1)},
				reg = src, rm = dst, size = size,
				rexw = rexw(), osize = osize(),
				rex = needrex(src) or needrex(dst)})
		end
		return insn(a, {op = {d[2] + (size == 1 and 0 or 1)},
			reg = dst, rm = src, size = size, rexw = rexw(),
			osize = osize(), rex = needrex(dst)})
	end
	if base == "test" then
		return insn(a, {op = {size == 1 and 0x84 or 0x85},
			reg = o[1], rm = o[2], size = size, rexw = rexw(),
			osize = osize(),
			rex = needrex(o[1]) or needrex(o[2])})
	end
	if base == "imul" and #ops == 3 then
		local v = o[1].val
		if v >= -128 and v <= 127 then
			return insn(a, {op = {0x6b}, reg = o[3], rm = o[2],
				size = size, rexw = rexw(), osize = osize(),
				imm = v, immsize = 1})
		end
		return insn(a, {op = {0x69}, reg = o[3], rm = o[2],
			size = size, rexw = rexw(), osize = osize(),
			imm = v, immsize = 4})
	end
	if base == "imul" and #ops == 2 then
		return insn(a, {op = {0x0f, 0xaf}, reg = o[2], rm = o[1],
			size = size, rexw = rexw(), osize = osize()})
	end
	-- bswap names the register in the opcode, and reaches only the
	-- four and eight byte forms.
	if base == "bswap" and #ops == 1 and o[1].kind == "reg" then
		local r = o[1].num

		if size == 8 or r >= 8 then
			byte(a, 0x40 | (size == 8 and 8 or 0) |
				(r >= 8 and 1 or 0))
		end
		byte(a, 0x0f)
		return byte(a, 0xc8 + (r & 7))
	end
	-- gas takes `divl %ecx,%eax`, which names the accumulator the
	-- one operand form uses anyway; the second operand says nothing.
	if #ops == 2 and (base == "div" or base == "idiv" or base == "mul") then
		ops, o = {ops[1]}, {o[1]}
	end
	if UNARY[base] and #ops == 1 then
		return insn(a, {op = {size == 1 and 0xf6 or 0xf7},
			reg = UNARY[base], rm = o[1], size = size,
			rexw = rexw(), osize = osize(), rex = needrex(o[1])})
	end
	if SHIFT[base] then
		local src, dst = o[1], o[2]
		if src.kind == "imm" then
			-- shifting by one has an opcode of its own
			if src.val == 1 then
				return insn(a, {
					op = {size == 1 and 0xd0 or 0xd1},
					reg = SHIFT[base], rm = dst,
					size = size, rexw = rexw(),
					osize = osize(), rex = needrex(dst)})
			end
			return insn(a, {op = {size == 1 and 0xc0 or 0xc1},
				reg = SHIFT[base], rm = dst, size = size,
				rexw = rexw(), osize = osize(),
				rex = needrex(dst),
				imm = src.val, immsize = 1})
		end
		-- the count is always cl
		return insn(a, {op = {size == 1 and 0xd2 or 0xd3},
			reg = SHIFT[base], rm = dst, size = size,
			rexw = rexw(), osize = osize(), rex = needrex(dst)})
	end
	-- push and pop take a register, a place in memory, or, for push,
	-- an immediate.  In long mode all three are 64 bits wide.
	if base == "push" or base == "pop" then
		local up = base == "push"

		if o[1].kind == "reg" then
			return insn(a, {op = {(up and 0x50 or 0x58) +
				(o[1].num & 7)}, reg = 0, rm = o[1],
				norm = true})
		end
		if o[1].kind == "imm" then
			if not up then error("pop needs a place") end
			local v = o[1].val
			if v and v >= -128 and v <= 127 then
				byte(a, 0x6a)
				return a:emit(v & 0xff, 1)
			end
			byte(a, 0x68)
			return a:emit((v or 0) & 0xffffffff, 4)
		end
		return insn(a, {op = {up and 0xff or 0x8f},
			reg = up and 6 or 0, rm = o[1]})
	end

	-- the widening moves, whose two sizes are in the mnemonic
	local WIDEN = {
		movsbl = {{0x0f, 0xbe}, 1, false}, movsbq = {{0x0f, 0xbe}, 1, true},
		movswl = {{0x0f, 0xbf}, 2, false}, movswq = {{0x0f, 0xbf}, 2, true},
		movzbl = {{0x0f, 0xb6}, 1, false}, movzbq = {{0x0f, 0xb6}, 1, true},
		movzwl = {{0x0f, 0xb7}, 2, false}, movzwq = {{0x0f, 0xb7}, 2, true},
		movslq = {{0x63}, 4, true},
	}
	if WIDEN[m] then
		local d = WIDEN[m]
		return insn(a, {op = d[1], reg = o[2], rm = o[1],
			size = d[2], rexw = d[3],
			rex = d[2] == 1 and o[1].kind == "reg" and
				o[1].num >= 4 and o[1].num < 8})
	end
	if m:sub(1, 3) == "set" and CC[m:sub(4)] then
		return insn(a, {op = {0x0f, 0x90 + CC[m:sub(4)]}, reg = 0,
			rm = o[1], size = 1, rex = needrex(o[1])})
	end
	if m == "call" then
		if o[1].indirect then
			return insn(a, {op = {0xff}, reg = 2, rm = o[1]})
		end
		local rel = a:localhere(o[1].sym)

		byte(a, 0xe8)
		if rel then return imm(a, rel - 5, 4) end
		a:reloc("plt32", o[1].sym, -4)
		return imm(a, 0, 4)
	end
	if m == "jmp" or (m:sub(1, 1) == "j" and CC[m:sub(2)]) then
		if o[1].indirect then
			return insn(a, {op = {0xff}, reg = 4, rm = o[1]})
		end
		local cc = m ~= "jmp" and CC[m:sub(2)] or nil
		-- Two forms reach two distances, and the real assembler
		-- takes the shorter whenever it reaches.  A pass that has
		-- not placed the label yet assumes it does and asks to be
		-- run again; from there a form only ever grows, so this
		-- settles.
		a.nbr = a.nbr + 1
		local id = a.nbr
		local rel = a:localhere(o[1].sym)

		-- Which form is used comes from the decision made at the
		-- end of the last round and from nothing else.  A pass that
		-- widened as it measured would move the ground under the
		-- next measurement.  A target this file never defines
		-- cannot be measured at all, and takes the long form.
		if not a.long[id] then
			local d = (rel or 0) - 2

			if a.pass == 1 and
			   (not rel or d < -128 or d > 127) then
				a.pending[id] = true
			end
			byte(a, cc and (0x70 + cc) or 0xeb)
			return imm(a, d, 1)
		end
		if cc then
			byte(a, 0x0f)
			byte(a, 0x80 + cc)
		else
			byte(a, 0xe9)
		end
		if a:localhere(o[1].sym) then
			return imm(a, rel - (cc and 6 or 5), 4)
		end
		a:reloc("pc32", o[1].sym, -4)
		return imm(a, 0, 4)
	end
	-- Saving and restoring the extended state, which a kernel does on
	-- every context switch.  All of them are 0F AE with the operation
	-- in the reg field, and the 64 forms add REX.W.
	local XSAVE = {fxsave = 0, fxrstor = 1, xsave = 4, xrstor = 5,
		       xsaveopt = 6}
	-- The supervisor forms are the same idea under another opcode.
	local XSAVES = {xrstors = 3, xsavec = 4, xsaves = 5}

	if #ops == 1 then
		local base64 = m:match("^(%a+)64$")
		local nm = base64 or m
		local k = XSAVE[nm]

		if k then
			return insn(a, {op = {0x0f, 0xae}, reg = k,
				rm = o[1], size = 8,
				rexw = base64 ~= nil})
		end
		k = XSAVES[nm]
		if k then
			return insn(a, {op = {0x0f, 0xc7}, reg = k,
				rm = o[1], size = 8,
				rexw = base64 ~= nil})
		end
	end
	-- The instructions a kernel writes and a program never does: no
	-- operands, one opcode each.
	local BARE = {
		hlt = {0xf4}, cli = {0xfa}, sti = {0xfb},
		cpuid = {0x0f, 0xa2}, rdtsc = {0x0f, 0x31},
		rdtscp = {0x0f, 0x01, 0xf9}, rdmsr = {0x0f, 0x32},
		wrmsr = {0x0f, 0x30}, rdpmc = {0x0f, 0x33},
		wbinvd = {0x0f, 0x09}, invd = {0x0f, 0x08},
		clts = {0x0f, 0x06}, ud2 = {0x0f, 0x0b},
		pause = {0xf3, 0x90}, lfence = {0x0f, 0xae, 0xe8},
		mfence = {0x0f, 0xae, 0xf0}, sfence = {0x0f, 0xae, 0xf8},
		swapgs = {0x0f, 0x01, 0xf8}, monitor = {0x0f, 0x01, 0xc8},
		mwait = {0x0f, 0x01, 0xc9}, xgetbv = {0x0f, 0x01, 0xd0},
		xsetbv = {0x0f, 0x01, 0xd1}, stgi = {0x0f, 0x01, 0xdc},
		clgi = {0x0f, 0x01, 0xdd},
		-- fninit does not wait first; finit does
		fninit = {0xdb, 0xe3}, finit = {0x9b, 0xdb, 0xe3},
		fwait = {0x9b}, int3 = {0xcc}, iretq = {0x48, 0xcf},
		["rep"] = {0xf3}, repne = {0xf2}, ["lock"] = {0xf0},
		rdpkru = {0x0f, 0x01, 0xee}, wrpkru = {0x0f, 0x01, 0xef},
		vmcall = {0x0f, 0x01, 0xc1}, vmlaunch = {0x0f, 0x01, 0xc2},
		vmresume = {0x0f, 0x01, 0xc3}, vmxoff = {0x0f, 0x01, 0xc4},
		vmmcall = {0x0f, 0x01, 0xd9}, vmrun = {0x0f, 0x01, 0xd8},
		vmload = {0x0f, 0x01, 0xda}, vmsave = {0x0f, 0x01, 0xdb},
		invlpga = {0x0f, 0x01, 0xdf}, rdgsbase = {0x0f, 0x01, 0xf8},
		serialize = {0x0f, 0x01, 0xe8}, endbr64 = {0xf3, 0x0f, 0x1e,
			0xfa},
		pushfq = {0x9c}, popfq = {0x9d}, pushf = {0x66, 0x9c},
		popf = {0x66, 0x9d}, cld = {0xfc}, std = {0xfd},
		leaveq = {0xc9}, retq = {0xc3}, sysret = {0x0f, 0x07},
		sysretq = {0x48, 0x0f, 0x07}, ["int3"] = {0xcc},
	}

	if #ops == 0 and BARE[m] then
		for _, b in ipairs(BARE[m]) do byte(a, b) end
		return
	end

	-- The descriptor table instructions and their kin: 0F 01 with the
	-- operation in the reg field.
	local G7 = {sgdt = 0, sidt = 1, lgdt = 2, lidt = 3, smsw = 4,
		    lmsw = 6, invlpg = 7}
	local G6 = {sldt = 0, str = 1, lldt = 2, ltr = 3, verr = 4,
		    verw = 5}

	if #ops == 1 then
		if G7[base] then
			return insn(a, {op = {0x0f, 0x01}, reg = G7[base],
				rm = o[1], size = size or 8})
		end
		if G6[base] then
			return insn(a, {op = {0x0f, 0x00}, reg = G6[base],
				rm = o[1], size = size or 2})
		end
		if base == "clflush" or base == "clflushopt" then
			return insn(a, {op = {0x0f, 0xae},
				reg = base == "clflush" and 7 or 7,
				prefix = base == "clflushopt" and {0x66}
					or nil,
				rm = o[1], size = 1})
		end
		if base == "fldcw" then
			return insn(a, {op = {0xd9}, reg = 5, rm = o[1],
				size = 2})
		end
		if base == "fnstcw" then
			return insn(a, {op = {0xd9}, reg = 7, rm = o[1],
				size = 2})
		end
		if base == "ldmxcsr" then
			return insn(a, {op = {0x0f, 0xae}, reg = 2,
				rm = o[1], size = 4})
		end
		if base == "stmxcsr" then
			return insn(a, {op = {0x0f, 0xae}, reg = 3,
				rm = o[1], size = 4})
		end
	end

	-- A software interrupt, and the port instructions, which take
	-- either a byte of immediate or dx.
	if m == "int" and #ops == 1 and o[1].kind == "imm" then
		if o[1].val == 3 then return byte(a, 0xcc) end
		byte(a, 0xcd)
		return byte(a, o[1].val & 255)
	end
	if (base == "in" or base == "out") and #ops == 2 then
		local port = base == "in" and o[1] or o[2]
		local wide = size ~= 1

		if size == 2 then byte(a, 0x66) end
		if port.kind == "imm" then
			byte(a, (base == "in" and 0xe4 or 0xe6) +
				(wide and 1 or 0))
			return byte(a, port.val & 255)
		end
		return byte(a, (base == "in" and 0xec or 0xee) +
			(wide and 1 or 0))
	end

	-- The count-register loops, which only reach a byte away.  A
	-- kernel's delay loops are written with them.
	local LOOP = {loop = 0xe2, loope = 0xe1, loopz = 0xe1,
		      loopne = 0xe0, loopnz = 0xe0, jrcxz = 0xe3,
		      jecxz = 0xe3}

	if LOOP[m] and #ops == 1 then
		local rel = a:here(ops[1])

		byte(a, LOOP[m])
		if not rel then
			a:reloc("pc8", ops[1], -1)
			return byte(a, 0)
		end
		-- the distance is from the end of the instruction, which
		-- is the opcode and the byte after it
		rel = rel - 2
		if rel < -128 or rel > 127 then
			error(m .. " is too far to reach")
		end
		return byte(a, rel & 255)
	end

	-- Invalidating a translation by context, which the kernel does
	-- when it switches page tables.
	if base == "invpcid" and #ops == 2 then
		return insn(a, {op = {0x0f, 0x38, 0x82}, reg = o[2],
			rm = o[1], size = 8, prefix = {0x66}})
	end

	-- exchange and add, and compare and exchange: the lock prefix a
	-- caller writes is its own instruction here
	if base == "xadd" and #ops == 2 then
		return insn(a, {op = {0x0f, size == 1 and 0xc0 or 0xc1},
			reg = o[1], rm = o[2], size = size,
			rexw = size == 8, osize = size == 2 and 2 or nil})
	end
	if base == "cmpxchg" and #ops == 2 then
		return insn(a, {op = {0x0f, size == 1 and 0xb0 or 0xb1},
			reg = o[1], rm = o[2], size = size,
			rexw = size == 8, osize = size == 2 and 2 or nil})
	end
	if base == "xchg" and #ops == 2 then
		return insn(a, {op = {size == 1 and 0x86 or 0x87},
			reg = o[1], rm = o[2], size = size,
			rexw = size == 8, osize = size == 2 and 2 or nil})
	end
	-- increment and decrement, which are the unary group
	if (base == "inc" or base == "dec") and #ops == 1 then
		return insn(a, {op = {size == 1 and 0xfe or 0xff},
			reg = base == "inc" and 0 or 1, rm = o[1],
			size = size, rexw = size == 8,
			osize = size == 2 and 2 or nil})
	end
	if m == "syscall" then
		-- The call number is whatever was last put in eax, which
		-- is how every one of these is written.
		a:syscallsite(a.lasteax)
		byte(a, 0x0f)
		return byte(a, 0x05)
	end
	if m == "ret" then return byte(a, 0xc3) end
	if m == "leave" then return byte(a, 0xc9) end
	if m == "nop" then return byte(a, 0x90) end
	if m == "cltd" then return byte(a, 0x99) end
	if m == "cqto" then
		byte(a, 0x48)
		return byte(a, 0x99)
	end
	if m == "cltq" then
		byte(a, 0x48)
		return byte(a, 0x98)
	end
	if m == "cwtl" then return byte(a, 0x98) end
	error("no instruction " .. m)
end

-- The floating point this compiler writes is one move: four or eight bytes
-- between a general register or memory and an argument register.  The
-- arithmetic is a call, so nothing else is needed.
--
-- The four-byte forms are uniform.  The eight-byte ones are not: a
-- register pair is the same opcodes with REX.W, but memory has two
-- spellings of its own.
function amd64.sse(a, src, dst, wide)
	if dst.kind == "xmm" and src.kind == "reg" then
		return insn(a, {prefix = {0x66}, op = {0x0f, 0x6e},
			reg = dst, rm = src, rexw = wide})
	end
	if dst.kind == "reg" and src.kind == "xmm" then
		return insn(a, {prefix = {0x66}, op = {0x0f, 0x7e},
			reg = src, rm = dst, rexw = wide})
	end
	if dst.kind == "xmm" then
		if not wide then
			return insn(a, {prefix = {0x66}, op = {0x0f, 0x6e},
				reg = dst, rm = src})
		end
		return insn(a, {prefix = {0xf3}, op = {0x0f, 0x7e},
			reg = dst, rm = src})
	end
	if not wide then
		return insn(a, {prefix = {0x66}, op = {0x0f, 0x7e},
			reg = src, rm = dst})
	end
	return insn(a, {prefix = {0x66}, op = {0x0f, 0xd6}, reg = src,
		rm = dst})
end

-- `.align` in a text section pads with the one-byte nop, as the real
-- assembler does, so that a disassembly reads straight through.
function amd64.directive(a, d, rest)
	return false
end

return amd64
