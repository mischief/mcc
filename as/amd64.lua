-- amd64, for what target/amd64 produces.
--
-- Sixty mnemonics in the forms that file emits, which is far short of the
-- machine but enough to assemble everything this compiler writes, and
-- little enough to be checked against the real assembler byte for byte.
--
-- An instruction is a REX byte, an opcode, a ModRM byte, sometimes a SIB
-- byte, a displacement and an immediate.  Everything below builds that.

local as = require "as"

-- `codefill` pads a gap in code with nops, so a reader that decodes
-- the section straight through keeps in step.
local amd64 = {wordbytes = 2, codefill = 0x90}

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
local YMM = {}
for i = 0, 15 do YMM["ymm" .. i] = i end

-- operands ------------------------------------------------------------

-- The segment registers, which only `mov` and `push` name.
local SEG = {es = 0, cs = 1, ss = 2, ds = 3, fs = 4, gs = 5}
local SEGPREFIX = {es = 0x26, cs = 0x2e, ss = 0x36, ds = 0x3e,
		   fs = 0x64, gs = 0x65}

-- A name `.set` to a register stands for it, and may stand for another
-- such name.
local function unalias(a, s)
	for _ = 1, 8 do
		local t = a.regalias[s]

		if not t then break end
		s = t
	end
	return s
end

local function operand(a, s)
	s = unalias(a, s)
	-- The preprocessor may leave a space where the source had none,
	-- as `x86_pred_cmd (% rip)`.  gas reads over them and so does
	-- this: nothing in an operand is told apart by a space.
	if s:find("%s") then
		s = s:gsub("^%s+", ""):gsub("%s+$", "")
		if not s:find('"') then s = s:gsub("%s+", "") end
	end
	if s:sub(1, 1) == "$" then
		local body = s:sub(2)

		local v = tonumber(body)

		if v then return {kind = "imm", val = v} end
		local n, sym, addend = a:symexpr(body)

		if n then return {kind = "imm", val = n} end
		-- The address of a name, which only the linker knows.
		if sym then
			return {kind = "imm", val = 0,
				rel = {sym = sym, addend = addend}}
		end
		-- Anything else a whole expression can measure, such as
		-- the distance between two labels in parentheses.
		local e = a:absexpr(body)

		if e then return {kind = "imm", val = e} end
		-- A label further down the file is not placed yet on the
		-- first pass.  The width does not depend on the value, so
		-- zero holds the space and the second pass fills it in.
		if a.pass < 2 then return {kind = "imm", val = 0} end
		error("bad immediate " .. s)
	end
	if s:sub(1, 1) == "*" then
		local o = operand(a, s:sub(2))
		o.indirect = true
		return o
	end
	-- A segment override, which only a kernel writes: the prefix byte
	-- goes in front and the rest is an ordinary place.
	local sg, rest = s:match("^%%(%a%a):(.*)$")

	if sg and SEG[sg] then
		local o = operand(a, rest)

		o.prefix = SEGPREFIX[sg]
		return o
	end
	if s:sub(1, 1) == "%" then
		local n = s:sub(2)
		if XMM[n] then return {kind = "xmm", num = XMM[n]} end
		if YMM[n] then return {kind = "ymm", num = YMM[n]} end
		-- The control and debug registers, which only a kernel
		-- names and only `mov` reaches.
		local ctl, no = n:match("^(cr)(%d+)$")

		-- gas spells a debug register `dr0` or `db0`.
		if not ctl then ctl, no = n:match("^(dr)(%d+)$") end
		if not ctl then
			local d = n:match("^db(%d+)$")

			if d then ctl, no = "dr", d end
		end
		if ctl then
			return {kind = ctl, num = tonumber(no)}
		end
		if SEG[n] then return {kind = "seg", num = SEG[n]} end
		local r = REG[n] or error("no register " .. s)
		return {kind = "reg", num = r.num, size = r.size,
			norex = r.norex}
	end
	-- memory with an index: `disp(base,index,scale)`, where the base
	-- and the scale may both be left out.
	-- The place is the last parenthesised group, so the split is
	-- greedy: `(A + B)(%rsp,%rcx)` names a displacement of its own.
	local d2, inner = s:match("^(.*)%(([^()]*)%)$")

	if inner and inner:find(",", 1, true) then
		local part = {}

		for w in (inner .. ","):gmatch("([^,]*),") do
			part[#part + 1] = w:match("^%s*(.-)%s*$")
		end
		local function num(t)
			if t == nil or t == "" then return nil end
			t = unalias(a, t)
			local r = REG[t:sub(2)] or error("no register " .. t)

			return r.num
		end
		local b, x = num(part[1]), num(part[2])

		local m = {kind = "mem", base = b, index = x,
			   nobase = b == nil,
			   scale = tonumber(part[3] or "") or 1, disp = 0}

		if d2 ~= "" then
			local n = tonumber(d2) or a:absexpr(d2)

			if n then
				m.disp = n
			else
				-- a displacement the linker fills in,
				-- with its addend travelling along
				local nn, sym, off = a:symexpr(d2)

				if sym then
					m.symdisp, m.disp = sym, off or 0
				elseif nn then
					m.disp = nn
				else
					error("bad displacement " .. s)
				end
			end
		end
		return m
	end
	-- memory: an optional displacement or symbol, then a base
	-- register, which the preprocessor may have left a space in
	-- front of
	local disp, base = s:match("^(.*)%(%s*([%%%w.$_]+)%s*%)$")
	if base then
		base = unalias(a, base)
		local b = base:sub(2)

		if base:sub(1, 1) ~= "%" then
			error("no register " .. base)
		end
		if b == "rip" then
			-- `sym@KIND+off(%rip)`: the name, what the linker is
			-- being asked for, and an offset that is anything
			-- the assembler can work out.
			local body, at = disp, ""
			local h, k = disp:match("^([^@]*)@(%a+)(.*)$")

			if h then body, at = h .. (disp:match("@%a+(.*)$")
				or ""), k end
			-- The whole thing may be in parentheses.
			body = body:match("^%s*%((.*)%)%s*$") or body
			local sym, off = body:match("^([%w.$_]+)%s*([-+].+)$")
			local addend = 0

			if sym then
				addend = a:absexpr(off) or
					error("bad rip operand " .. s)
			else
				sym = body:match("^%s*([%w.$_]+)%s*$")
			end
			if not sym then error("bad rip operand " .. s) end
			return {kind = "mem", rip = true, sym = sym,
				addend = addend, got = at == "GOTPCREL"}
		end
		local r = REG[b] or error("no register " .. base)
		-- `sym@tpoff(%reg)` is how far into a thread's own block
		-- the object sits, which only the linker knows.
		local tp = disp:match("^([%w.$_]+)@tpoff$")

		if tp then
			return {kind = "mem", base = r.num, disp = 0,
				tpoff = tp}
		end
		if disp == "" then
			return {kind = "mem", base = r.num, disp = 0}
		end
		local n = tonumber(disp) or a:absexpr(disp)

		if n then
			return {kind = "mem", base = r.num, disp = n}
		end
		-- `sym(%reg)` and `sym+8(%reg)`: the displacement is an
		-- address the linker fills in, and the addend travels
		-- with the relocation.
		local nn, sym, off = a:symexpr(disp)

		if sym then
			return {kind = "mem", base = r.num, disp = off or 0,
				symdisp = sym}
		end
		if nn then
			return {kind = "mem", base = r.num, disp = nn}
		end
		error("bad displacement " .. s)
	end
	-- A place named by a number alone, which follows a segment
	-- override: no base, no index, a four byte displacement.
	local n = tonumber(s) or as.evalexpr(s)

	if n then return {kind = "mem", disp = n, abs = true} end
	return {kind = "sym", sym = s}
end

-- encoding -------------------------------------------------------------

local function byte(a, v) a:emit(v & 255, 1) end

local function imm(a, v, n)
	a:emit(v & ((1 << (8 * n)) - 1), n)
end

-- An immediate, with a relocation in front of it when it names a
-- symbol.  The wide form of an instruction sign extends its immediate,
-- so the linker has to be told which of the two it is.
local function immrel(a, o)
	local r = o.immrel

	if r then
		a:reloc(o.immsize == 8 and "abs64" or
			(o.rexw and "abs32s" or "abs32"), r.sym, r.addend)
	end
	imm(a, o.imm, o.immsize)
end

-- One instruction: `op` is the opcode bytes, `reg` the ModRM.reg field
-- (a register number or an opcode extension), `rm` the other operand.
local function insn(a, o)
	local size = o.size or 8
	local rm, reg = o.rm, o.reg or 0

	-- A bare name where a place was wanted is the address itself,
	-- which is how `testb $1, sym` reaches a fixed address.
	if rm.kind == "sym" then
		local n, sym, off = a:symexpr(rm.sym)

		if n then
			rm = {kind = "mem", nobase = true, scale = 1,
			      disp = n}
		else
			rm = {kind = "mem", nobase = true, scale = 1,
			      disp = off or 0, symdisp = sym or rm.sym}
		end
	end
	local rexb, rexx, rexr = 0, 0, 0

	if rm.kind == "reg" or rm.kind == "xmm" or rm.kind == "ymm" then
		rexb = (rm.num >= 8) and 1 or 0
	elseif rm.kind == "mem" then
		if rm.base then rexb = (rm.base >= 8) and 1 or 0 end
		if rm.index then rexx = (rm.index >= 8) and 1 or 0 end
	end
	if type(reg) == "table" then
		rexr = (reg.num >= 8) and 1 or 0
		reg = reg.num & 7
	else
		rexr = 0
	end

	local rexw = o.rexw and 1 or 0
	local needrexb = rexw == 1 or rexr == 1 or rexx == 1 or rexb == 1 or
		o.rex

	-- Everything these files write encodes the same in 32-bit mode as
	-- in long mode, with two exceptions: there is no REX byte, and
	-- mod 00 rm 101 is an address rather than a distance from the
	-- program counter.
	if a.bits == 32 then
		if needrexb then
			error("64-bit operand in 32-bit code")
		end
		if rm.rip then
			error("%rip addressing in 32-bit code")
		end
	elseif a.bits ~= 64 then
		error(a.bits .. "-bit code is not supported")
	end

	-- A segment override comes before everything, including the size
	-- prefix and the REX byte.
	if rm.prefix then byte(a, rm.prefix) end
	if o.vex then
		-- The VEX prefix says in two or three bytes what the
		-- size prefix, the escape bytes and REX said in up to
		-- five, and names a second source register besides.
		-- `map` is which escape it stands for, `pp` which size
		-- prefix, `l` whether the registers are 256 bits wide
		-- and `vvvv` the extra source, all of the last three
		-- written the other way up.
		local v = o.vex
		-- The field holds the register the other way up, so a
		-- form with no second source leaves it at all ones.
		local nv = ~(v.vvvv or 0) & 15
		local w = v.w or 0
		local l = v.l or 0
		local pp = v.pp or 0

		if rexx == 0 and rexb == 0 and w == 0 and v.map == 1 then
			byte(a, 0xc5)
			byte(a, (1 - rexr) << 7 | nv << 3 | l << 2 | pp)
		else
			byte(a, 0xc4)
			byte(a, (1 - rexr) << 7 | (1 - rexx) << 6 |
				(1 - rexb) << 5 | v.map)
			byte(a, w << 7 | nv << 3 | l << 2 | pp)
		end
		byte(a, v.op)
	else
		if o.osize == 2 then byte(a, 0x66) end
		for _, p in ipairs(o.prefix or {}) do byte(a, p) end

		if needrexb then
			byte(a, 0x40 | rexw << 3 | rexr << 2 | rexx << 1 |
				rexb)
		end
		for _, b in ipairs(o.op) do byte(a, b) end
	end

	if o.norm then
		if o.imm then immrel(a, o) end
		return
	end

	if rm.kind == "reg" or rm.kind == "xmm" or rm.kind == "ymm" then
		byte(a, 0xc0 | reg << 3 | (rm.num & 7))
	elseif rm.rip then
		byte(a, 0x00 | reg << 3 | 5)
		-- a label this section owns needs no help from the linker
		local rel = not rm.got and a:localhere(rm.sym) or nil
		local add = rm.addend or 0

		if rel then
			imm(a, rel + add - 4 - (o.immsize or 0), 4)
		else
			local kind = "pc32"

			if rm.got then
				-- `mov sym@GOTPCREL(%rip),reg` is the form
				-- the linker may turn into a `lea`, and
				-- the relocation is what says so.  Which
				-- of the two names it wears depends on
				-- whether a REX byte went in front.
				kind = "gotpcrel"
				if #o.op == 1 and o.op[1] == 0x8b then
					kind = needrexb and "rexgotpcrelx"
						or "gotpcrelx"
				end
			end
			a:reloc(kind, rm.sym, add - 4 - (o.immsize or 0))
			imm(a, 0, 4)
		end
	elseif a.bits == 32 and rm.nobase and not rm.index then
		-- No SIB byte is needed: in 32-bit mode mod 00 rm 101 is
		-- the address itself, which is what gas writes.
		byte(a, 0x00 | reg << 3 | 5)
		if rm.symdisp then
			a:reloc("abs32", rm.symdisp, rm.disp)
			imm(a, 0, 4)
		else
			imm(a, rm.disp, 4)
		end
	elseif rm.index or rm.nobase then
		-- A scaled index needs the SIB byte, where 4 in the index
		-- field means there is none and 5 in the base field with
		-- mod 00 means the address is the displacement alone.
		local SC = {[1] = 0, [2] = 1, [4] = 2, [8] = 3}
		local mod = 2

		if rm.nobase then
			mod = 0
		elseif rm.symdisp then
			mod = 2
		elseif rm.disp == 0 and (rm.base & 7) ~= 5 then
			mod = 0
		elseif rm.disp >= -128 and rm.disp <= 127 then
			mod = 1
		end
		byte(a, mod << 6 | reg << 3 | 4)
		byte(a, (SC[rm.scale] or 0) << 6 |
			(rm.index and (rm.index & 7) or 4) << 3 |
			(rm.nobase and 5 or (rm.base & 7)))
		if rm.nobase or mod == 2 then
			-- The addend travels in the relocation, so the
			-- field the linker writes over starts at zero.
			if rm.symdisp then
				a:reloc("abs32s", rm.symdisp, rm.disp)
				imm(a, 0, 4)
			else
				imm(a, rm.disp, 4)
			end
		end
		if mod == 1 then imm(a, rm.disp, 1) end
	elseif rm.abs then
		-- no base and no index: mod 00, rm 100, SIB saying so
		byte(a, 0x00 | reg << 3 | 4)
		byte(a, 0x25)
		imm(a, rm.disp, 4)
	else
		local b = rm.base & 7
		local mod
		if rm.tpoff or rm.symdisp then
			mod = 2
		elseif rm.disp == 0 and b ~= 5 then
			mod = 0
		elseif rm.disp >= -128 and rm.disp <= 127 then
			mod = 1
		else
			mod = 2
		end
		byte(a, mod << 6 | reg << 3 | (b == 4 and 4 or b))
		if b == 4 then byte(a, 0x24) end	-- SIB: base, no index
		if mod == 1 then imm(a, rm.disp, 1) end
		if mod == 2 then
			if rm.tpoff then a:reloc("tpoff32", rm.tpoff, 0) end
			if rm.symdisp then
				a:reloc("abs32s", rm.symdisp, rm.disp)
				imm(a, 0, 4)
			else
				imm(a, rm.disp, 4)
			end
		end
	end
	if o.imm then immrel(a, o) end
end

-- tables ---------------------------------------------------------------

-- op src,dst for the eight arithmetic forms: {rm<-reg, reg<-rm, /ext}
local ARITH = {
	add = {0x00, 0x02, 0},
	["or"] = {0x08, 0x0a, 1},
	["and"] = {0x20, 0x22, 4},
	adc = {0x10, 0x12, 2},
	sbb = {0x18, 0x1a, 3},
	sub = {0x28, 0x2a, 5},
	xor = {0x30, 0x32, 6},
	cmp = {0x38, 0x3a, 7},
}
-- F7 /ext, one operand
local UNARY = {["not"] = 2, neg = 3, mul = 4, imul = 5, div = 6, idiv = 7}
-- C1 /ext and D3 /ext
local SHIFT = {rol = 0, ror = 1, shl = 4, shr = 5, sar = 7,
	       rcl = 2, rcr = 3, sal = 4}
local CC = {
	o = 0, no = 1, b = 2, ae = 3, e = 4, ne = 5, be = 6, a = 7,
	s = 8, ns = 9, p = 10, np = 11, l = 12, ge = 13, le = 14, g = 15,
}
-- The other spellings gas takes for the same condition.
for a, b in pairs{c = "b", nae = "b", nb = "ae", nc = "ae", z = "e",
		  nz = "ne", na = "be", nbe = "a", pe = "p", po = "np",
		  nge = "l", nl = "ge", ng = "le", nle = "g"} do
	CC[a] = CC[b]
end
local SIZE = {b = 1, w = 2, l = 4, q = 8}

local function split(m)
	local base, suffix = m:match("^(.-)([bwlq])$")
	if base and SIZE[suffix] and (ARITH[base] or UNARY[base] or
	    SHIFT[base] or base == "mov" or base == "lea" or base == "test" or
	    base == "push" or base == "pop" or base == "movabs" or
	    base == "bswap" or base == "xadd" or base == "cmpxchg" or
	    base == "xchg" or base == "inc" or base == "dec" or
	    base == "in" or base == "out" or base == "bsf" or
	    base == "bsr" or base == "rdseed" or base == "rdrand" or
	    base == "call" or base == "bt" or base == "bts" or
	    base == "shld" or base == "shrd" or base == "rorx" or
	    base == "fxsave" or base == "fxrstor" or base == "xsave" or
	    base == "xrstor" or base == "xsaveopt" or
	    base == "lgdt" or base == "lidt" or base == "sgdt" or
	    base == "sidt" or base == "lldt" or base == "sldt" or
	    base == "ltr" or base == "str" or base == "lmsw" or
	    base == "smsw" or
	    base == "ljmp" or base == "lcall" or base == "rdfsbase" or
	    base == "rdgsbase" or base == "wrfsbase" or
	    base == "wrgsbase" or
	    base == "btr" or base == "btc" or base == "tzcnt" or
	    base == "lzcnt" or base == "popcnt" or base == "lar" or
	    base == "lsl" or base == "movnti" or base == "cvtsi2sd" or
	    base == "cvtsi2ss" or base == "cvttsd2si" or
	    base == "cvttss2si" or base == "cvtsd2si" or
	    base == "cvtss2si") then
		return base, SIZE[suffix]
	end
	return m, nil
end

-- A prefix byte, which may stand on its own line or share one with the
-- instruction it prefixes.
-- A prefix written on its own, before the instruction it belongs to.
-- The segment ones stand in front of an instruction that names no
-- place, which is how a kernel pads one alternative out to the length
-- of another.
local PREFIX = {["rep"] = {0xf3}, repe = {0xf3}, repz = {0xf3},
		repne = {0xf2}, repnz = {0xf2}, ["lock"] = {0xf0},
		["ds"] = {0x3e}, ["es"] = {0x26}, ["cs"] = {0x2e},
		["ss"] = {0x36}, ["fs"] = {0x64}, ["gs"] = {0x65},
		notrack = {0x3e}, bnd = {0xf2}}

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

-- x87.
--
-- This compiler keeps a float in an ordinary register and does the
-- arithmetic with calls, so it writes none of these itself.  A
-- freestanding libm does: the eighty-bit unit is the only way to reach
-- log, exp and the rest without a library under you.
--
-- The stack registers are %st and %st(0) through %st(7).

-- No operands: the whole instruction is two bytes.
local FNOARG = {
	f2xm1 = {0xd9, 0xf0}, fabs = {0xd9, 0xe1}, fchs = {0xd9, 0xe0},
	fcompp = {0xde, 0xd9}, fdecstp = {0xd9, 0xf6},
	fincstp = {0xd9, 0xf7}, fld1 = {0xd9, 0xe8},
	fldl2e = {0xd9, 0xea}, fldl2t = {0xd9, 0xe9},
	fldlg2 = {0xd9, 0xec}, fldln2 = {0xd9, 0xed},
	fldpi = {0xd9, 0xeb}, fldz = {0xd9, 0xee}, fnop = {0xd9, 0xd0},
	fpatan = {0xd9, 0xf3}, fprem = {0xd9, 0xf8},
	fprem1 = {0xd9, 0xf5}, fptan = {0xd9, 0xf2},
	frndint = {0xd9, 0xfc}, fscale = {0xd9, 0xfd},
	fsin = {0xd9, 0xfe}, fcos = {0xd9, 0xff}, fsincos = {0xd9, 0xfb},
	fsqrt = {0xd9, 0xfa}, ftst = {0xd9, 0xe4}, fxam = {0xd9, 0xe5},
	fxtract = {0xd9, 0xf4}, fyl2x = {0xd9, 0xf1},
	fyl2xp1 = {0xd9, 0xf9}, fnclex = {0xdb, 0xe2},
	fninit = {0xdb, 0xe3}, fucompp = {0xda, 0xe9},
	-- The popping arithmetic, which with no operand means st(1)
	faddp = {0xde, 0xc1}, fmulp = {0xde, 0xc9},
	fsubp = {0xde, 0xe1}, fsubrp = {0xde, 0xe9},
	fdivp = {0xde, 0xf1}, fdivrp = {0xde, 0xf9},
}

-- One stack register: the opcode, and the byte the number is added to.
local FST1 = {
	fld = {0xd9, 0xc0}, fxch = {0xd9, 0xc8}, fst = {0xdd, 0xd0},
	fstp = {0xdd, 0xd8}, ffree = {0xdd, 0xc0}, fucom = {0xdd, 0xe0},
	fucomp = {0xdd, 0xe8}, fcom = {0xd8, 0xd0}, fcomp = {0xd8, 0xd8},
	fcomi = {0xdb, 0xf0}, fucomi = {0xdb, 0xe8},
	fcomip = {0xdf, 0xf0}, fucomip = {0xdf, 0xe8},
	-- One register on its own means "against the top of the stack",
	-- which is the same encoding as naming %st second.
	fadd = {0xd8, 0xc0}, fmul = {0xd8, 0xc8},
	fsub = {0xd8, 0xe0}, fsubr = {0xd8, 0xe8},
	fdiv = {0xd8, 0xf0}, fdivr = {0xd8, 0xf8},
}

-- Two stack registers.  The base byte is the same whichever way round
-- they are written; only the opcode changes: D8 answers into the top of
-- the stack, DC into the register named, DE into the register named and
-- pops.  The number added is always the one that is not %st.
local FST2 = {
	fadd = 0xc0, fmul = 0xc8,
	fsub = 0xe0, fsubr = 0xe8,
	fdiv = 0xf0, fdivr = 0xf8,
	faddp = 0xc0, fmulp = 0xc8,
	fsubp = 0xe0, fsubrp = 0xe8,
	fdivp = 0xf0, fdivrp = 0xf8,
}
-- Which of the three answers each mnemonic gives.
local FPOP = {faddp = true, fmulp = true, fsubp = true, fsubrp = true,
	      fdivp = true, fdivrp = true}

-- A place in memory: the opcode and the extension in the ModRM byte.
-- The name says the width, as gas spells it.
local FMEM = {
	flds = {0xd9, 0}, fld = {0xd9, 0}, fldl = {0xdd, 0},
	fldt = {0xdb, 5},
	fsts = {0xd9, 2}, fst = {0xd9, 2}, fstl = {0xdd, 2},
	fstps = {0xd9, 3}, fstp = {0xd9, 3}, fstpl = {0xdd, 3},
	fstpt = {0xdb, 7},
	filds = {0xdf, 0}, fildl = {0xdb, 0}, fildll = {0xdf, 5},
	fildq = {0xdf, 5},
	fists = {0xdf, 2}, fistl = {0xdb, 2},
	fistps = {0xdf, 3}, fistpl = {0xdb, 3}, fistpll = {0xdf, 7},
	fistpq = {0xdf, 7},
	fadds = {0xd8, 0}, faddl = {0xdc, 0},
	fmuls = {0xd8, 1}, fmull = {0xdc, 1},
	fcoms = {0xd8, 2}, fcoml = {0xdc, 2},
	fcomps = {0xd8, 3}, fcompl = {0xdc, 3},
	fsubs = {0xd8, 4}, fsubl = {0xdc, 4},
	fsubrs = {0xd8, 5}, fsubrl = {0xdc, 5},
	fdivs = {0xd8, 6}, fdivl = {0xdc, 6},
	fdivrs = {0xd8, 7}, fdivrl = {0xdc, 7},
	fnstsw = {0xdd, 7},
}

-- `%st`, `%st(0)` .. `%st(7)`; nil when the text is something else.
local function stnum(t)
	if type(t) ~= "string" then return nil end
	t = t:match("^%s*(.-)%s*$")
	if t == "%st" then return 0 end
	local n = t:match("^%%st%((%d)%)$")
	return n and tonumber(n) or nil
end

local function x87(a, m, ops)
	if m:sub(1, 1) ~= "f" and m ~= "wait" then return false end
	if m == "fwait" or m == "wait" then
		byte(a, 0x9b)
		return true
	end
	local n = #ops

	if n == 0 and FNOARG[m] then
		byte(a, FNOARG[m][1])
		byte(a, FNOARG[m][2])
		return true
	end
	if n == 1 and m == "fnstsw" and stnum(ops[1]) == nil and
	   ops[1]:match("^%s*%%[ae]ax%s*$") then
		byte(a, 0xdf)
		byte(a, 0xe0)
		return true
	end
	if n == 1 then
		local i = stnum(ops[1])

		-- `fsubrp %st(1)` is the two-operand form with %st left
		-- out, the same as writing it second.
		if i and FPOP[m] then
			byte(a, 0xde)
			byte(a, FST2[m] + i)
			return true
		end
		if i and FST1[m] then
			byte(a, FST1[m][1])
			byte(a, FST1[m][2] + i)
			return true
		end
		-- Saving and restoring the whole x87 state, which is D9 or DD
	-- with the operation in the reg field.  The n spelling does not
	-- wait for the unit first.
	local FSTATE = {fnsave = {0xdd, 6}, fsave = {0xdd, 6, true},
			frstor = {0xdd, 4},
			fnstenv = {0xd9, 6}, fstenv = {0xd9, 6, true},
			fldenv = {0xd9, 4},
			fnstcw = {0xd9, 7}, fstcw = {0xd9, 7, true},
			fldcw = {0xd9, 5},
			fnstsw = {0xdd, 7}, fstsw = {0xdd, 7, true}}

	-- The status word into ax is its own encoding, not the one that
	-- writes it to a place.
	if (m == "fnstsw" or m == "fstsw") and #ops == 1 and
	   ops[1]:match("^%%e?ax$") then
		if m == "fstsw" then byte(a, 0x9b) end
		byte(a, 0xdf)
		byte(a, 0xe0)
		return true
	end
	if i == nil and FSTATE[m] and #ops == 1 then
		local d = FSTATE[m]

		if d[3] then byte(a, 0x9b) end
		return insn(a, {op = {d[1]}, reg = d[2],
			rm = operand(a, ops[1])}) or true
	end
	if not i and FMEM[m] then
			return insn(a, {op = {FMEM[m][1]}, reg = FMEM[m][2],
				rm = operand(a, ops[1])}) or true
		end
	end
	if n == 2 then
		local one, two = stnum(ops[1]), stnum(ops[2])

		if one and two and FST2[m] then
			local base = FST2[m]

			if FPOP[m] then
				byte(a, 0xde)
				byte(a, base + two)
			elseif two == 0 then
				byte(a, 0xd8)
				byte(a, base + one)
			else
				byte(a, 0xdc)
				byte(a, base + two)
			end
			return true
		end
		-- `fucomip %st(1),%st`: the flag-setting compares name the
		-- top of the stack as the second operand and nothing else.
		if one and two == 0 and FST1[m] then
			byte(a, FST1[m][1])
			byte(a, FST1[m][2] + one)
			return true
		end
	end
	if FNOARG[m] or FST1[m] or FMEM[m] or FST2[m] then
		error("bad operands for " .. m)
	end
	return false
end

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
	if x87(a, m, ops) then return end
	local base, size = split(m)
	local o = {}
	for i, t in ipairs(ops) do o[i] = operand(a, t) end

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
					imm = src.val, immrel = src.rel,
					immsize = size})
			end
			return insn(a, {op = {size == 1 and 0xc6 or 0xc7},
				reg = 0, rm = dst, size = size,
				rexw = rexw(), osize = osize(),
				rex = needrex(dst),
				imm = src.val, immrel = src.rel,
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
			imm = o[1].val, immrel = o[1].rel,
			immsize = 8})
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
			if size ~= 1 and not src.rel and
			   src.val >= -128 and src.val <= 127 then
				return insn(a, {op = {0x83}, reg = d[3],
					rm = dst, size = size,
					rexw = rexw(), osize = osize(),
					imm = src.val, immrel = src.rel,
					immsize = 1})
			end
			-- the accumulator has a form of its own with no
			-- ModRM byte, which is what the real assembler picks
			if dst.kind == "reg" and dst.num == 0 then
				return insn(a, {
					op = {d[1] + (size == 1 and 4 or 5)},
					reg = 0, rm = dst, norm = true,
					rexw = rexw(), osize = osize(),
					imm = src.val, immrel = src.rel,
					immsize = size == 1 and 1 or
						(size == 2 and 2 or 4)})
			end
			return insn(a, {op = {size == 1 and 0x80 or 0x81},
				reg = d[3], rm = dst, size = size,
				rexw = rexw(), osize = osize(),
				rex = needrex(dst),
				imm = src.val, immrel = src.rel,
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
	if base == "test" and o[1].kind == "imm" then
		-- The accumulator has a form with no modrm byte, which is
		-- the one gas writes.
		if o[2].kind == "reg" and o[2].num == 0 then
			return insn(a, {op = {size == 1 and 0xa8 or 0xa9},
				reg = 0, rm = o[2], size = size,
				rexw = rexw(), osize = osize(), norm = true,
				imm = o[1].val, immrel = o[1].rel,
				immsize = size == 1 and 1 or
					(size == 2 and 2 or 4)})
		end
		-- F6 /0 and F7 /0: a mask against a place
		return insn(a, {op = {size == 1 and 0xf6 or 0xf7}, reg = 0,
			rm = o[2], size = size, rexw = rexw(),
			osize = osize(), rex = needrex(o[2]),
			imm = o[1].val, immrel = o[1].rel, immsize = size == 1 and 1 or
				(size == 2 and 2 or 4)})
	end
	if base == "test" then
		return insn(a, {op = {size == 1 and 0x84 or 0x85},
			reg = o[1], rm = o[2], size = size, rexw = rexw(),
			osize = osize(),
			rex = needrex(o[1]) or needrex(o[2])})
	end
	if base == "imul" and #ops == 3 then
		local v = o[1].val
		if not o[1].rel and v >= -128 and v <= 127 then
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

		-- One operand means shift by one, which gas takes as
		-- well as the spelled out `$1`.
		if #o == 1 then src, dst = {kind = "imm", val = 1}, o[1] end
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
				imm = src.val, immrel = src.rel,
					immsize = 1})
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
			if not o[1].rel and v and v >= -128 and
			   v <= 127 then
				byte(a, 0x6a)
				return a:emit(v & 0xff, 1)
			end
			byte(a, 0x68)
			if o[1].rel then
				a:reloc("abs32s", o[1].rel.sym,
					o[1].rel.addend)
			end
			return a:emit((v or 0) & 0xffffffff, 4)
		end
		return insn(a, {op = {up and 0xff or 0x8f},
			reg = up and 6 or 0, rm = o[1]})
	end

	-- The bit tests.  A register operand is 0F A3 and its kin; an
	-- immediate is 0F BA with the operation in the reg field.
	local BIT = {bt = {0xa3, 4}, bts = {0xab, 5}, btr = {0xb3, 6},
		     btc = {0xbb, 7}}

	if BIT[base] and #o == 2 then
		local d = BIT[base]

		if o[1].kind == "imm" then
			return insn(a, {op = {0x0f, 0xba}, reg = d[2],
				rm = o[2], size = size, rexw = rexw(),
				osize = osize(), imm = o[1].val, immrel = o[1].rel,
				immsize = 1})
		end
		return insn(a, {op = {0x0f, d[1]}, reg = o[1], rm = o[2],
			size = size, rexw = rexw(), osize = osize()})
	end
	-- The whole-register SSE moves and the bitwise ones: {load, store}
	-- opcodes and the prefix that picks the form.
	local VMOV = {
		movups = {0x10, 0x11}, movaps = {0x28, 0x29},
		movupd = {0x10, 0x11, 0x66}, movapd = {0x28, 0x29, 0x66},
		movdqa = {0x6f, 0x7f, 0x66}, movdqu = {0x6f, 0x7f, 0xf3},
		movsd = {0x10, 0x11, 0xf2}, movss = {0x10, 0x11, 0xf3},
		movlps = {0x12, 0x13}, movhps = {0x16, 0x17},
		movlpd = {0x12, 0x13, 0x66}, movhpd = {0x16, 0x17, 0x66},
	}
	local VOP = {pxor = {0xef, 0x66}, pand = {0xdb, 0x66},
		     pandn = {0xdf, 0x66},
		     por = {0xeb, 0x66}, pcmpeqb = {0x74, 0x66},
		     pcmpeqw = {0x75, 0x66}, pcmpeqd = {0x76, 0x66},
		     pcmpgtb = {0x64, 0x66}, pcmpgtw = {0x65, 0x66},
		     pcmpgtd = {0x66, 0x66},
		     punpcklbw = {0x60, 0x66}, punpcklwd = {0x61, 0x66},
		     punpckldq = {0x62, 0x66}, punpcklqdq = {0x6c, 0x66},
		     punpckhbw = {0x68, 0x66}, punpckhwd = {0x69, 0x66},
		     punpckhdq = {0x6a, 0x66}, punpckhqdq = {0x6d, 0x66},
		     paddb = {0xfc, 0x66}, paddw = {0xfd, 0x66},
		     paddd = {0xfe, 0x66}, paddq = {0xd4, 0x66},
		     psubb = {0xf8, 0x66}, psubw = {0xf9, 0x66},
		     psubd = {0xfa, 0x66}, psubq = {0xfb, 0x66},
		     pmuludq = {0xf4, 0x66}, pmullw = {0xd5, 0x66},
		     pavgb = {0xe0, 0x66}, pavgw = {0xe3, 0x66},
		     pminub = {0xda, 0x66}, pmaxub = {0xde, 0x66},
		     unpcklps = {0x14}, unpckhps = {0x15},
		     unpcklpd = {0x14, 0x66}, unpckhpd = {0x15, 0x66},
		     andnps = {0x55}, andnpd = {0x55, 0x66},
		     addps = {0x58}, addpd = {0x58, 0x66},
		     mulps = {0x59}, mulpd = {0x59, 0x66},
		     subps = {0x5c}, subpd = {0x5c, 0x66},
		     divps = {0x5e}, divpd = {0x5e, 0x66},
		     minps = {0x5d}, maxps = {0x5f},
		     xorps = {0x57}, andps = {0x54}, orps = {0x56},
		     xorpd = {0x57, 0x66}, andpd = {0x54, 0x66},
		     orpd = {0x56, 0x66},
		     -- The scalar forms, which is what a C double is
		     addss = {0x58, 0xf3}, addsd = {0x58, 0xf2},
		     subss = {0x5c, 0xf3}, subsd = {0x5c, 0xf2},
		     mulss = {0x59, 0xf3}, mulsd = {0x59, 0xf2},
		     divss = {0x5e, 0xf3}, divsd = {0x5e, 0xf2},
		     minss = {0x5d, 0xf3}, minsd = {0x5d, 0xf2},
		     maxss = {0x5f, 0xf3}, maxsd = {0x5f, 0xf2},
		     sqrtps = {0x51}, sqrtpd = {0x51, 0x66},
		     sqrtss = {0x51, 0xf3}, sqrtsd = {0x51, 0xf2},
		     ucomiss = {0x2e}, ucomisd = {0x2e, 0x66},
		     comiss = {0x2f}, comisd = {0x2f, 0x66},
		     cvtss2sd = {0x5a, 0xf3}, cvtsd2ss = {0x5a, 0xf2},
		     cvtps2pd = {0x5a}, cvtpd2ps = {0x5a, 0x66},
		     cvtdq2ps = {0x5b}, cvtps2dq = {0x5b, 0x66},
		     cvttps2dq = {0x5b, 0xf3},
		     cvtdq2pd = {0xe6, 0xf3}, cvtpd2dq = {0xe6, 0xf2},
		     cvttpd2dq = {0xe6, 0x66}}

	if VMOV[m] and #o == 2 then
		local d = VMOV[m]
		local pre = d[3] and {d[3]} or nil

		-- The store form when the destination is not a register
		-- of the vector file.
		if o[2].kind ~= "xmm" then
			return insn(a, {op = {0x0f, d[2]}, reg = o[1],
				rm = o[2], size = 16, prefix = pre})
		end
		return insn(a, {op = {0x0f, d[1]}, reg = o[2], rm = o[1],
			size = 16, prefix = pre})
	end
	-- Between an integer register and the float file.  The general
	-- register decides the width, so this cannot ride on the table
	-- above, which is sixteen bytes wide throughout.
	local CVTI = {cvtsi2ss = {0x2a, 0xf3}, cvtsi2sd = {0x2a, 0xf2}}
	local CVTF = {cvttss2si = {0x2c, 0xf3}, cvttsd2si = {0x2c, 0xf2},
		      cvtss2si = {0x2d, 0xf3}, cvtsd2si = {0x2d, 0xf2}}

	if CVTI[base] and #o == 2 then
		local d = CVTI[base]

		return insn(a, {op = {0x0f, d[1]}, reg = o[2], rm = o[1],
			size = size or 4, rexw = size == 8 or nil,
			prefix = {d[2]}})
	end
	if CVTF[base] and #o == 2 then
		local d = CVTF[base]

		return insn(a, {op = {0x0f, d[1]}, reg = o[2], rm = o[1],
			size = size or 4, rexw = size == 8 or nil,
			prefix = {d[2]}})
	end
	if VOP[m] and #o == 2 then
		local d = VOP[m]

		return insn(a, {op = {0x0f, d[1]}, reg = o[2], rm = o[1],
			size = 16, prefix = d[2] and {d[2]} or nil})
	end
	-- A bit scan, which reads a place and writes a register.
	-- The double shifts, which take a count in cl or written out and
	-- shift one register into another.
	local DSH = {shld = 0xa4, shrd = 0xac}

	if DSH[base] and #o == 3 then
		-- The count is in cl or written out, so the width comes
		-- from the two registers being shifted, not from the
		-- first operand.
		local sz = o[3].size or o[2].size or size

		if o[1].kind == "imm" then
			return insn(a, {op = {0x0f, DSH[base]}, reg = o[2],
				rm = o[3], size = sz,
				rexw = sz == 8 or nil,
				osize = sz == 2 and 2 or nil,
				imm = o[1].val,
				immrel = o[1].rel, immsize = 1})
		end
		return insn(a, {op = {0x0f, DSH[base] + 1}, reg = o[2],
			rm = o[3], size = sz, rexw = sz == 8 or nil,
			osize = sz == 2 and 2 or nil})
	end
	local SCAN = {bsf = 0xbc, bsr = 0xbd}

	if SCAN[base] and #o == 2 then
		return insn(a, {op = {0x0f, SCAN[base]}, reg = o[2],
			rm = o[1], size = size, rexw = rexw(),
			osize = osize()})
	end
	-- The counted forms of the same, which are the scan opcodes
	-- behind an F3 prefix, and the population count beside them.
	local CNT = {tzcnt = 0xbc, lzcnt = 0xbd, popcnt = 0xb8}

	if CNT[base] and #o == 2 then
		return insn(a, {op = {0x0f, CNT[base]}, reg = o[2],
			rm = o[1], size = size, rexw = rexw(),
			osize = osize(), prefix = {0xf3}})
	end
	-- The segment descriptor readers, which only a kernel writes.
	local SEGQ = {lar = 0x02, lsl = 0x03}

	if SEGQ[base] and #o == 2 then
		return insn(a, {op = {0x0f, SEGQ[base]}, reg = o[2],
			rm = o[1], size = size, rexw = rexw(),
			osize = osize()})
	end
	-- The cache hints: 0F 18 with the level in the reg field, and
	-- the write hint beside them at 0F 0D.
	local PREF = {prefetchnta = 0, prefetcht0 = 1, prefetcht1 = 2,
		      prefetcht2 = 3}

	if PREF[m] and #o == 1 then
		return insn(a, {op = {0x0f, 0x18}, reg = PREF[m],
			rm = o[1], size = 1})
	end
	if (m == "prefetch" or m == "prefetchw") and #o == 1 then
		return insn(a, {op = {0x0f, 0x0d},
			reg = m == "prefetchw" and 1 or 0,
			rm = o[1], size = 1})
	end
	local CACHE = {clflush = {0x0f, 0xae, 7},
		       clflushopt = {0x0f, 0xae, 7, 0x66},
		       clwb = {0x0f, 0xae, 6, 0x66}}

	if CACHE[m] and #o == 1 then
		local d = CACHE[m]

		return insn(a, {op = {d[1], d[2]}, reg = d[3], rm = o[1],
			size = 1, prefix = d[4] and {d[4]} or nil})
	end
	-- The vector shifts by a count in a register or a place, and the
	-- forms that take the count as a byte, which put the operation in
	-- the reg field.
	local VSH = {psrlw = 0xd1, psrld = 0xd2, psrlq = 0xd3,
		     psraw = 0xe1, psrad = 0xe2,
		     psllw = 0xf1, pslld = 0xf2, psllq = 0xf3}
	local VSHI = {psrlw = {0x71, 2}, psrld = {0x72, 2},
		      psrlq = {0x73, 2}, psraw = {0x71, 4},
		      psrad = {0x72, 4}, psllw = {0x71, 6},
		      pslld = {0x72, 6}, psllq = {0x73, 6},
		      psrldq = {0x73, 3}, pslldq = {0x73, 7}}

	if #o == 2 and o[1].kind == "imm" and VSHI[m] then
		local d = VSHI[m]

		return insn(a, {op = {0x0f, d[1]}, reg = d[2], rm = o[2],
			size = 16, prefix = {0x66}, imm = o[1].val,
			immrel = o[1].rel, immsize = 1})
	end
	if #o == 2 and VSH[m] then
		return insn(a, {op = {0x0f, VSH[m]}, reg = o[2],
			rm = o[1], size = 16, prefix = {0x66}})
	end
	-- The hashing instructions, three byte opcodes with no prefix.
	local SHA = {sha1nexte = 0xc8, sha1msg1 = 0xc9, sha1msg2 = 0xca,
		     sha256rnds2 = 0xcb, sha256msg1 = 0xcc,
		     sha256msg2 = 0xcd}

	if SHA[m] and #o >= 2 then
		-- sha256rnds2 names xmm0 as a third operand, which the
		-- encoding takes for granted.
		return insn(a, {op = {0x0f, 0x38, SHA[m]}, reg = o[2],
			rm = o[1], size = 16})
	end
	-- The AVX forms, which the VEX prefix spells: three operands
	-- rather than two, and 256 bit registers.
	--
	-- Each entry is {opcode, map, pp}, where map is which escape the
	-- prefix stands for -- 1 for 0F, 2 for 0F38, 3 for 0F3A -- and
	-- pp which size prefix -- 1 for 66, 2 for F3, 3 for F2.
	local VEX3 = {
		vpaddb = {0xfc, 1, 1}, vpaddw = {0xfd, 1, 1},
		vpaddd = {0xfe, 1, 1}, vpaddq = {0xd4, 1, 1},
		vpsubb = {0xf8, 1, 1}, vpsubw = {0xf9, 1, 1},
		vpsubd = {0xfa, 1, 1}, vpsubq = {0xfb, 1, 1},
		vpxor = {0xef, 1, 1}, vpor = {0xeb, 1, 1},
		vpand = {0xdb, 1, 1}, vpandn = {0xdf, 1, 1},
		vpsllw = {0xf1, 1, 1}, vpslld = {0xf2, 1, 1},
		vpsllq = {0xf3, 1, 1}, vpsrlw = {0xd1, 1, 1},
		vpsrld = {0xd2, 1, 1}, vpsrlq = {0xd3, 1, 1},
		vpsraw = {0xe1, 1, 1}, vpsrad = {0xe2, 1, 1},
		vpunpckldq = {0x62, 1, 1}, vpunpcklqdq = {0x6c, 1, 1},
		vpunpckhdq = {0x6a, 1, 1}, vpunpckhqdq = {0x6d, 1, 1},
		vpcmpeqb = {0x74, 1, 1}, vpcmpeqd = {0x76, 1, 1},
		vpshufb = {0x00, 2, 1}, vpmulld = {0x40, 2, 1},
		vpxorps = {0x57, 1, 0}, vxorps = {0x57, 1, 0},
		vandps = {0x54, 1, 0}, vorps = {0x56, 1, 0},
	}
	-- The two operand forms: one source, one destination.
	local VEX2 = {
		vpmovzxbd = {0x31, 2, 1}, vpmovzxbw = {0x30, 2, 1},
		vpmovzxwd = {0x33, 2, 1}, vpabsd = {0x1e, 2, 1},
	}
	-- The moves, which have a load opcode and a store opcode.
	local VMOVV = {
		vmovdqa = {0x6f, 0x7f, 1, 1}, vmovdqu = {0x6f, 0x7f, 1, 2},
		vmovaps = {0x28, 0x29, 1, 0}, vmovups = {0x10, 0x11, 1, 0},
		vmovapd = {0x28, 0x29, 1, 1}, vmovupd = {0x10, 0x11, 1, 1},
		vmovd = {0x6e, 0x7e, 1, 1}, vmovq = {0x6e, 0x7e, 1, 1},
	}
	-- The forms that take a pattern byte.  `shuf` reads one source,
	-- `mix` two.
	local VSHUF = {vpshufd = {0x70, 1, 1}, vpshufhw = {0x70, 1, 2},
		       vpshuflw = {0x70, 1, 3},
		       vpermq = {0x00, 3, 1, w = 1},
		       vpermpd = {0x01, 3, 1, w = 1}}
	local VMIX = {vpalignr = {0x0f, 3, 1}, vperm2i128 = {0x46, 3, 1},
		      vperm2f128 = {0x06, 3, 1}, vpblendd = {0x02, 3, 1},
		      vinserti128 = {0x38, 3, 1}, vinsertf128 = {0x18, 3, 1}}
	-- The shifts by a count written out, where the operation sits in
	-- the reg field and the register written goes in the prefix.
	local VSHI = {vpsrlw = {0x71, 2}, vpsrld = {0x72, 2},
		      vpsrlq = {0x73, 2}, vpsraw = {0x71, 4},
		      vpsrad = {0x72, 4}, vpsllw = {0x71, 6},
		      vpslld = {0x72, 6}, vpsllq = {0x73, 6},
		      vpsrldq = {0x73, 3}, vpslldq = {0x73, 7}}

	-- 256 bits wide when any register named is.
	local function wide()
		for _, x in ipairs(o) do
			if x.kind == "ymm" then return 1 end
		end
		return 0
	end

	if m == "vzeroupper" or m == "vzeroall" then
		byte(a, 0xc5)
		byte(a, 0xf8 | (m == "vzeroall" and 4 or 0))
		byte(a, 0x77)
		return
	end
	if VSHI[m] and #o == 3 and o[1].kind == "imm" then
		local d = VSHI[m]

		return insn(a, {rm = o[2], reg = d[2], imm = o[1].val,
			immsize = 1,
			vex = {op = d[1], map = 1, pp = 1, l = wide(),
			       vvvv = o[3].num}})
	end
	-- A rotate that writes somewhere other than what it read, which
	-- the VEX prefix spells with no second source.
	if base == "rorx" and #o == 3 and o[1].kind == "imm" then
		local sz = o[3].size or o[2].size or size

		return insn(a, {rm = o[2], reg = o[3], imm = o[1].val,
			immsize = 1,
			vex = {op = 0xf0, map = 3, pp = 3,
			       w = sz == 8 and 1 or 0}})
	end
	if VEX3[m] and #o == 3 then
		local d = VEX3[m]

		return insn(a, {rm = o[1], reg = o[3],
			vex = {op = d[1], map = d[2], pp = d[3],
			       l = wide(), vvvv = o[2].num}})
	end
	if VEX2[m] and #o == 2 then
		local d = VEX2[m]

		return insn(a, {rm = o[1], reg = o[2],
			vex = {op = d[1], map = d[2], pp = d[3],
			       l = wide()}})
	end
	if VSHUF[m] and #o == 3 and o[1].kind == "imm" then
		local d = VSHUF[m]

		return insn(a, {rm = o[2], reg = o[3], imm = o[1].val,
			immsize = 1,
			vex = {op = d[1], map = d[2], pp = d[3],
			       l = wide(), w = d.w}})
	end
	if VMIX[m] and #o == 4 and o[1].kind == "imm" then
		local d = VMIX[m]

		return insn(a, {rm = o[2], reg = o[4], imm = o[1].val,
			immsize = 1,
			vex = {op = d[1], map = d[2], pp = d[3],
			       l = wide(), vvvv = o[3].num}})
	end
	-- Taking half of a wide register out is a store: the wide one
	-- goes in the reg field and the narrow place in the other.
	if (m == "vextracti128" or m == "vextractf128") and #o == 3 then
		return insn(a, {rm = o[3], reg = o[2], imm = o[1].val,
			immsize = 1,
			vex = {op = m == "vextracti128" and 0x39 or 0x19,
			       map = 3, pp = 1, l = 1}})
	end
	if VMOVV[m] and #o == 2 then
		local d = VMOVV[m]
		local w = m == "vmovq" and 1 or nil

		-- The store form when what is written is not a register
		-- of the vector file.
		if o[2].kind ~= "xmm" and o[2].kind ~= "ymm" then
			return insn(a, {rm = o[2], reg = o[1],
				vex = {op = d[2], map = d[3], pp = d[4],
				       l = wide(), w = w}})
		end
		return insn(a, {rm = o[1], reg = o[2],
			vex = {op = d[1], map = d[3], pp = d[4],
			       l = wide(), w = w}})
	end
	-- The three byte vector opcodes that take a pattern byte,
	-- 66 0F 3A xx.
	local V3A = {palignr = 0x0f, pblendw = 0x0e, roundpd = 0x09,
		     roundps = 0x08, roundsd = 0x0b, roundss = 0x0a,
		     pextrb = 0x14, pextrd = 0x16, pinsrb = 0x20,
		     pinsrd = 0x22}

	if V3A[base] and #o == 3 then
		return insn(a, {op = {0x0f, 0x3a, V3A[base]}, reg = o[3],
			rm = o[2], size = 16, prefix = {0x66},
			imm = o[1].val, immrel = o[1].rel, immsize = 1})
	end
	-- The three byte vector opcodes this compiler needs, 66 0F 38 xx.
	local V38 = {pshufb = 0x00, pmulld = 0x40, pcmpeqq = 0x29,
		     packusdw = 0x2b, ptest = 0x17, pminsb = 0x38,
		     pmaxsb = 0x3c, pminud = 0x3b, pmaxud = 0x3f}

	if V38[m] and #o == 2 then
		return insn(a, {op = {0x0f, 0x38, V38[m]}, reg = o[2],
			rm = o[1], size = 16, prefix = {0x66}})
	end
	-- The random number instructions, 0F C7 with the operation in the
	-- reg field and the register to fill in the rm field.
	-- The two-register compare and exchange, 0F C7 with 1 in the reg
	-- field: eight bytes across edx:eax, sixteen across rdx:rax with
	-- the wide bit set.
	if (m == "cmpxchg8b" or m == "cmpxchg16b") and #o == 1 then
		return insn(a, {op = {0x0f, 0xc7}, reg = 1, rm = o[1],
			size = 8, rexw = m == "cmpxchg16b" or nil})
	end
	-- The process id read, which shares 0F C7 with the random ones
	-- behind an F3 prefix.
	if m == "rdpid" and #o == 1 then
		return insn(a, {op = {0x0f, 0xc7}, reg = 7, rm = o[1],
			size = 8, prefix = {0xf3}})
	end
	-- A store that does not keep the line in the cache.
	if base == "movnti" and #o == 2 then
		return insn(a, {op = {0x0f, 0xc3}, reg = o[1], rm = o[2],
			size = size, rexw = rexw()})
	end
	-- The thread pointer registers, F3 0F AE with the operation in
	-- the reg field.
	local BASE = {rdfsbase = 0, rdgsbase = 1, wrfsbase = 2,
		      wrgsbase = 3}

	if BASE[base] and #o == 1 then
		return insn(a, {op = {0x0f, 0xae}, reg = BASE[base],
			rm = o[1], size = size or 8, rexw = rexw(),
			prefix = {0xf3}})
	end
	-- Saving and restoring the floating point and vector state,
	-- 0F AE with the operation in the reg field.
	local FXS = {fxsave = 0, fxrstor = 1, ldmxcsr = 2, stmxcsr = 3,
		     xsave = 4, xrstor = 5, xsaveopt = 6}

	if FXS[base] and #o == 1 then
		return insn(a, {op = {0x0f, 0xae}, reg = FXS[base],
			rm = o[1], size = 4, rexw = size == 8 or nil})
	end
	local RAND = {rdrand = 6, rdseed = 7}

	if RAND[base] and #o == 1 then
		return insn(a, {op = {0x0f, 0xc7}, reg = RAND[base],
			rm = o[1], size = size, rexw = rexw(),
			osize = osize()})
	end
	if m == "movntdqa" and #o == 2 then
		return insn(a, {op = {0x0f, 0x38, 0x2a}, reg = o[2],
			rm = o[1], size = 16, prefix = {}, osize = 2})
	end
	-- The shuffles, which take a pattern byte: pshufd wants the size
	-- prefix, shufps does not.
	local SHUF = {pshufd = {0x70, 2}, pshufhw = {0x70, nil, 0xf3},
		      pshuflw = {0x70, nil, 0xf2}, shufps = {0xc6},
		      shufpd = {0xc6, 2}}

	if SHUF[m] and #o == 3 then
		local d = SHUF[m]

		return insn(a, {op = {0x0f, d[1]}, reg = o[3], rm = o[2],
			size = 16, osize = d[2],
			prefix = d[3] and {d[3]} or nil,
			imm = o[1].val, immrel = o[1].rel, immsize = 1})
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
	-- A conditional move, whose condition may carry a size letter.
	if m:sub(1, 4) == "cmov" and #o == 2 then
		local c = m:sub(5)
		local cc = CC[c]

		if not cc and SIZE[c:sub(-1)] then cc = CC[c:sub(1, -2)] end
		if cc then
			return insn(a, {op = {0x0f, 0x40 + cc}, reg = o[2],
				rm = o[1], size = size, rexw = rexw(),
				osize = osize()})
		end
	end
	if m:sub(1, 3) == "set" and CC[m:sub(4)] then
		return insn(a, {op = {0x0f, 0x90 + CC[m:sub(4)]}, reg = 0,
			rm = o[1], size = 1, rex = needrex(o[1])})
	end
	if base == "call" then
		if o[1].indirect then
			return insn(a, {op = {0xff}, reg = 2, rm = o[1]})
		end
		local rel = a:localhere(o[1].sym)

		byte(a, 0xe8)
		if rel then return imm(a, rel - 5, 4) end
		a:reloc("plt32", o[1].sym, -4)
		return imm(a, 0, 4)
	end
	if m == "jmp" or m == "jmpq" or
	   (m:sub(1, 1) == "j" and CC[m:sub(2)]) then
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
		monitorx = {0x0f, 0x01, 0xfa}, mwaitx = {0x0f, 0x01, 0xfb},
		xsetbv = {0x0f, 0x01, 0xd1}, stgi = {0x0f, 0x01, 0xdc},
		clgi = {0x0f, 0x01, 0xdd},
		-- fninit does not wait first; finit does
		fninit = {0xdb, 0xe3}, finit = {0x9b, 0xdb, 0xe3},
		fwait = {0x9b}, int3 = {0xcc}, iretq = {0x48, 0xcf},
		["rep"] = {0xf3}, repe = {0xf3}, repz = {0xf3},
		repne = {0xf2}, repnz = {0xf2}, ["lock"] = {0xf0},
		rdpkru = {0x0f, 0x01, 0xee}, wrpkru = {0x0f, 0x01, 0xef},
		vmcall = {0x0f, 0x01, 0xc1}, vmlaunch = {0x0f, 0x01, 0xc2},
		vmresume = {0x0f, 0x01, 0xc3}, vmxoff = {0x0f, 0x01, 0xc4},
		vmmcall = {0x0f, 0x01, 0xd9}, vmrun = {0x0f, 0x01, 0xd8},
		vmload = {0x0f, 0x01, 0xda}, vmsave = {0x0f, 0x01, 0xdb},
		invlpga = {0x0f, 0x01, 0xdf},
		serialize = {0x0f, 0x01, 0xe8}, endbr64 = {0xf3, 0x0f, 0x1e,
			0xfa},
		-- In long mode the flags go on the stack eight bytes at
		-- a time unless the w form asks otherwise.
		pushfq = {0x9c}, popfq = {0x9d}, pushf = {0x9c},
		popf = {0x9d}, pushfw = {0x66, 0x9c},
		popfw = {0x66, 0x9d}, cld = {0xfc}, std = {0xfd},
		leaveq = {0xc9}, retq = {0xc3}, sysret = {0x0f, 0x07},
		sysretq = {0x48, 0x0f, 0x07}, ["int3"] = {0xcc},
		clc = {0xf8}, stc = {0xf9}, cmc = {0xf5},
		sysretl = {0x0f, 0x07}, sysexitl = {0x0f, 0x35},
		sysexitq = {0x48, 0x0f, 0x35}, lretl = {0xcb},
		lretw = {0x66, 0xcb}, iretw = {0x66, 0xcf},
		clac = {0x0f, 0x01, 0xca}, stac = {0x0f, 0x01, 0xcb},
		lret = {0xcb}, lretq = {0x48, 0xcb}, iret = {0xcf},
		iretl = {0xcf}, sahf = {0x9e}, lahf = {0x9f},
		sysenter = {0x0f, 0x34}, sysexit = {0x0f, 0x35},
		ud0 = {0x0f, 0xff}, ud1 = {0x0f, 0xb9},
		emms = {0x0f, 0x77}, femms = {0x0f, 0x0e},
	}

	if #ops == 0 and BARE[m] then
		for _, b in ipairs(BARE[m]) do byte(a, b) end
		return
	end
	-- The l forms of the flag instructions belong to 32-bit code;
	-- gas refuses them in long mode and so does this.
	if a.bits == 32 and (m == "pushfl" or m == "popfl") then
		byte(a, m == "pushfl" and 0x9c or 0x9d)
		return
	end

	-- A far jump or call through a place, which a kernel writes to
	-- change the code segment.  The size letter says nothing the
	-- opcode does not.
	-- `ljmpl $sel, $off`: the opcode carries the pair, offset first
	-- and then the selector.  The size letter says how wide the
	-- offset is.
	if (base == "ljmp" or base == "lcall") and #o == 2 and
	   o[1].kind == "imm" and o[2].kind == "imm" then
		local w = size == 2 and 2 or 4

		if size == 2 then byte(a, 0x66) end
		byte(a, base == "ljmp" and 0xea or 0x9a)
		if o[2].rel then
			a:reloc(w == 2 and "abs16" or "abs32",
				o[2].rel.sym, o[2].rel.addend)
			imm(a, 0, w)
		else
			imm(a, o[2].val, w)
		end
		if o[1].rel then
			a:reloc("abs16", o[1].rel.sym, o[1].rel.addend)
			imm(a, 0, 2)
		else
			imm(a, o[1].val, 2)
		end
		return
	end
	if (base == "ljmp" or base == "lcall") and #o == 1 then
		return insn(a, {op = {0xff},
			reg = base == "ljmp" and 5 or 3,
			rm = o[1], size = 8, rexw = size == 8 or nil})
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

-- `#` starts a comment on this machine, anywhere on the line.
amd64.hash = true

return amd64
