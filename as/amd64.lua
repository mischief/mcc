-- SPDX-License-Identifier: ISC
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
-- The AVX-512 file.  Only the low sixteen are reachable here: the
-- prefix has a bit for each of the other two halves and this writer
-- leaves both saying "no".
local ZMM = {}
for i = 0, 15 do ZMM["zmm" .. i] = i end
-- The eight opmask registers of AVX-512.  A masked instruction says
-- which one in the EVEX prefix; these name one as an operand, which
-- is how a compare writes its answer and how kmov moves it about.
local KREG = {}
for i = 0, 7 do KREG["k" .. i] = i end

-- operands ------------------------------------------------------------

-- The segment registers, which only `mov` and `push` name.
local SEG = {es = 0, cs = 1, ss = 2, ds = 3, fs = 4, gs = 5}
local SEGPREFIX = {es = 0x26, cs = 0x2e, ss = 0x36, ds = 0x3e,
		   fs = 0x64, gs = 0x65}

-- A name `.set` to a register stands for it, and may stand for another
-- such name.
-- `((gdt)-startup_32)` is one displacement. Take off a pair of
-- parentheses that wraps the whole of it, and only such a pair:
-- `(a)+(b)` is not wrapped in one however it looks.
local function unwrap(t)
	while true do
		local inner = t:match("^%s*%((.*)%)%s*$")

		if not inner then return t end
		local d = 0

		for c in inner:gmatch("[()]") do
			d = d + (c == "(" and 1 or -1)
			if d < 0 then return t end
		end
		if d ~= 0 then return t end
		t = inner
	end
end

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
		-- The way from a label in this section to a name the
		-- linker places, which is what `$(sym - here)` is.  The
		-- field's own spot is part of the distance, so the
		-- relocation is the PC-relative one.
		local ps, po = a:pcexpr(body)

		if ps then
			return {kind = "imm", val = 0,
				rel = {pcrel = true, sym = ps,
				       addend = po}}
		end
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

		-- gas folds the case of a register name as it does a
		-- mnemonic, and a kernel macro that builds one out of a
		-- parameter can hand over `%Zmm14`.
		if n:find("%u") and not REG[n] and not XMM[n] and
		   not YMM[n] and not ZMM[n] then
			n = n:lower()
		end
		if XMM[n] then return {kind = "xmm", num = XMM[n]} end
		if YMM[n] then return {kind = "ymm", num = YMM[n]} end
		if ZMM[n] then return {kind = "zmm", num = ZMM[n]} end
		if KREG[n] then return {kind = "kreg", num = KREG[n]} end
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
		if SEG[n] then
			return {kind = "seg", num = SEG[n], seg = n}
		end
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
		-- How wide the address is: `(%bx,%si)` names 16-bit
		-- registers and is a different encoding from
		-- `(%ebx,%esi)`, not the same one with a prefix.
		local aw

		local function num(t)
			if t == nil or t == "" then return nil end
			t = unalias(a, t)
			local r = REG[t:sub(2)] or error("no register " .. t)

			if aw and aw ~= r.size then
				error("an address written with registers " ..
					"of two widths: " .. s)
			end
			aw = r.size
			return r.num
		end
		-- `sym(,1)`: no base, no index, a scale of one, which is
		-- the plain address; OpenBSD's mbr.S writes it that way.
		if #part == 2 and part[1] == "" and part[2]:match("^%d+$") then
			return operand(a, d2 ~= "" and d2 or "0")
		end
		local b, x = num(part[1]), num(part[2])

		local m = {kind = "mem", base = b, index = x, awidth = aw,
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
				local psym, pbase = nil, nil

				if not sym and not nn then
					psym, pbase = a:pcexpr(d2)
				end
				if sym then
					m.symdisp, m.disp = sym, off or 0
				elseif nn then
					m.disp = nn
				elseif psym then
					m.pcdisp, m.pcbase = psym, pbase
				elseif a.pass < 2 then
					m.wide = true
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
	-- What is in the parentheses may not be a register at all: a
	-- name in them is an expression with parentheses round it, and
	-- the place is the address it works out to.  openbsd writes
	-- `lgdtl (.Lmptramp_gdt32_desc)`.
	if base and disp == "" and base:sub(1, 1) ~= "%" then
		base = unalias(a, base)
		if base:sub(1, 1) ~= "%" then
			local n = tonumber(base) or as.evalexpr(base)

			if n then
				return {kind = "mem", disp = n, abs = true}
			end
			return {kind = "sym", sym = base}
		end
	end
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
			body = unwrap(body)
			-- A name starts with a letter, an underscore, a
			-- dot or a dollar; a digit begins a number, and
			-- `0(%rip)` is a distance rather than a place.
			local sym, off =
				body:match("^([%a_.$\128-\255][%w.$_\128-\255]*)%s*([-+].+)$")
			local addend = 0

			if sym then
				addend = a:absexpr(off)
				-- What follows the name is not a plain
				-- number, so the name at the front was
				-- not the one the linker fills in.
				if not addend then sym, addend = nil, 0 end
			end
			if not sym then
				sym = body:match("^%s*([%a_.$\128-\255][%w.$_\128-\255]*)%s*$")
			end
			-- The name may sit anywhere in the expression:
			-- linux writes `8*t+K512(%rip)` and
			-- `K_XMM+K_XMM_AR(%rip)`.
			if not sym and not body:match("^%s*$") then
				local _, s2, o2 = a:symexpr(body)

				if s2 then sym, addend = s2, o2 end
			end
			if not sym then
				-- No one name to hand over: what is left is
				-- a distance from the next instruction, and
				-- zero is that instruction.  A kernel asks
				-- where it is with `lea 0(%rip), %0`.
				-- `(%rip)` on its own is the next
				-- instruction, the same as `0(%rip)`.
				local n = body:match("^%s*$") and 0 or
					a:absexpr(body)

				-- A label further down the file is not
				-- placed on the first pass.  The width does
				-- not turn on the value, so zero holds the
				-- space and the second pass fills it in.
				if not n and a.pass < 2 then n = 0 end
				if n then
					return {kind = "mem", rip = true,
						here = n}
				end
				error("bad rip operand " .. s)
			end
			return {kind = "mem", rip = true, sym = sym,
				addend = addend, got = at == "GOTPCREL"}
		end
		local r = REG[b] or error("no register " .. base)
		-- `sym@tpoff(%reg)` is how far into a thread's own block
		-- the object sits, which only the linker knows.
		local tp = disp:match("^([%w.$_\128-\255]+)@tpoff$")

		if tp then
			return {kind = "mem", awidth = r.size, base = r.num, disp = 0,
				tpoff = tp}
		end
		-- `sym@GOT(%ebx)` is how far into the global offset
		-- table the entry for sym sits, which 32-bit
		-- position-independent code reaches everything through.
		local gt = disp:match("^([%w.$_\128-\255]+)@GOT$")

		if gt then
			return {kind = "mem", awidth = r.size, base = r.num, disp = 0,
				got32 = gt}
		end
		-- `sym@GOTOFF(%ebx)` is how far the object sits from the
		-- table, which is what a name this unit owns uses when
		-- the code may be loaded anywhere.
		local go, goff = disp:match(
			"^([%w.$_\128-\255]+)@GOTOFF([+%-]%d*)$")

		if not go then
			go = disp:match("^([%w.$_\128-\255]+)@GOTOFF$")
		end
		if go then
			return {kind = "mem", awidth = r.size, base = r.num,
				disp = tonumber(goff) or 0, gotoff = go}
		end
		if disp == "" then
			return {kind = "mem", awidth = r.size, base = r.num, disp = 0}
		end
		disp = unwrap(disp)
		local n = tonumber(disp) or a:absexpr(disp)

		if n then
			return {kind = "mem", awidth = r.size, base = r.num, disp = n}
		end
		-- `sym(%reg)` and `sym+8(%reg)`: the displacement is an
		-- address the linker fills in, and the addend travels
		-- with the relocation.
		local nn, sym, off = a:symexpr(disp)

		if sym then
			return {kind = "mem", awidth = r.size, base = r.num, disp = off or 0,
				symdisp = sym}
		end
		if nn then
			-- The first pass could not work it out and held
			-- four bytes for it, so the second keeps them.
			return {kind = "mem", awidth = r.size, base = r.num, disp = nn,
				wide = a.widedisp and a.widedisp[disp]
					or nil}
		end
		-- `A - B` where the two sit in different sections: no
		-- number says how far apart they are, but a PC-relative
		-- relocation on A does, once the way from the field back
		-- to B rides along in the addend.
		local psym, pbase = a:pcexpr(disp)

		if psym then
			return {kind = "mem", awidth = r.size, base = r.num, disp = 0,
				pcdisp = psym, pcbase = pbase}
		end
		-- A distance between two labels is a number, but not
		-- until both are placed. The width does not turn on the
		-- value, so the first pass holds the space with zero and
		-- the second fills it in.
		if a.pass < 2 then
			a.widedisp = a.widedisp or {}
			a.widedisp[disp] = true
			return {kind = "mem", awidth = r.size, base = r.num, disp = 0,
				wide = true}
		end
		error("bad displacement " .. s)
	end
	-- A place named by a number alone, which follows a segment
	-- override: no base, no index, a four byte displacement.
	local n = tonumber(s) or as.evalexpr(s)

	if n then return {kind = "mem", disp = n, abs = true} end
	-- `call f@PLT` is a call to f that may go through the table the
	-- loader fills in, which is the relocation a call already asks
	-- for.  The suffix says how to reach the name, not what it is.
	local plt = s:match("^(.*)@[Pp][Ll][Tt]$")

	return {kind = "sym", sym = plt or s}
end

-- encoding -------------------------------------------------------------

local function byte(a, v) a:emit(v & 255, 1) end

local function imm(a, v, n)
	a:emit(v & ((1 << (8 * n)) - 1), n)
end

-- An immediate, with a relocation in front of it when it names a
-- symbol.  The wide form of an instruction sign extends its immediate,
-- so the linker has to be told which of the two it is.
-- What a call to a name reaches it by.  Long mode says the procedure
-- table even for a name the object defines, because the linker may
-- still want one; 32-bit x86 says a plain distance, and gas writes
-- the two that way.
local function callkind(a)
	return a.bits == 64 and "plt32" or "pc32"
end

-- A name in an immediate takes a relocation of the field's own width.
-- Four bytes is the ordinary one and picks up the signed form under
-- REX.W, so it is not in here.
local IMMKIND = {[1] = "abs8", [2] = "abs16", [8] = "abs64"}

local function immrel(a, o)
	local r = o.immrel

	if r then
		if r.pcrel then
			if o.immsize ~= 4 then
				error("a distance to a name needs a four " ..
					"byte immediate")
			end
			a:reloc("pc32", r.sym, r.addend + a.cur.off)
		else
			-- The relocation is as wide as the field: a
			-- four byte one over a two byte immediate, which
			-- is what 16-bit code writes, overwrites the
			-- instruction after it.
			local k = IMMKIND[o.immsize]

			if not k then
				k = o.rexw and "abs32s" or "abs32"
			end
			a:reloc(k, r.sym, r.addend)
		end
	end
	imm(a, o.imm, o.immsize)
end

-- The 16-bit address shapes by base and index register number.
local RM16 = {["3,6"] = 0, ["3,7"] = 1, ["5,6"] = 2,
	      ["5,7"] = 3, ["6"] = 4, ["7"] = 5,
	      ["5"] = 6, ["3"] = 7}
-- The SIB scale field by the scale written.
local SC = {[1] = 0, [2] = 1, [4] = 2, [8] = 3}

-- One instruction: `op` is the opcode bytes, `reg` the ModRM.reg field
-- (a register number or an opcode extension), `rm` the other operand.
local function insn(a, o)
	local size = o.size or 8
	local rm, reg = o.rm, o.reg or 0

	-- A bare name where a place was wanted is the address itself,
	-- which is how `testb $1, sym` reaches a fixed address.
	if rm.kind == "sym" then
		local n, sym, off = a:symexpr(rm.sym)
		-- A segment override was read before the name and
		-- belongs to the place it makes: linux reads `current`
		-- as `movq %gs:current_task, %rax`.
		local pfx = rm.prefix

		if n then
			rm = {kind = "mem", nobase = true, scale = 1,
			      disp = n, prefix = pfx}
		else
			rm = {kind = "mem", nobase = true, scale = 1,
			      disp = off or 0, symdisp = sym or rm.sym,
			      prefix = pfx}
		end
	end
	local rexb, rexx, rexr = 0, 0, 0

	if rm.kind == "reg" or rm.kind == "xmm" or rm.kind == "ymm" or
	   rm.kind == "zmm" or rm.kind == "kreg" then
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
	elseif a.bits == 16 then
		if needrexb then
			error("64-bit operand in 16-bit code")
		end
		if rm.rip then
			error("%rip addressing in 16-bit code")
		end
	end

	-- AVX-512 scales the one byte displacement by how much memory the
	-- instruction reaches, so only a multiple of that fits in one and
	-- anything else takes the four byte form.
	local dn = 1

	if o.evex then dn = o.evex.n or (16 << (o.evex.l or 0)) end
	local function short(d)
		return d % dn == 0 and d // dn >= -128 and d // dn <= 127
	end

	-- A segment override comes before everything, including the size
	-- prefix and the REX byte.
	if rm.prefix then byte(a, rm.prefix) end
	-- The VEX prefix has one bit for the width, so a form named with
	-- 512-bit registers is written the other way.
	if o.vex and o.vex.l == 2 then
		o.evex, o.vex = o.vex, nil
	end
	if o.evex then
		-- The four byte prefix of AVX-512.  It says everything VEX
		-- says and four things more: a second bit for each
		-- register number, a mask register, whether the masked
		-- lanes are zeroed, and whether the memory operand is
		-- broadcast.  None of those four is used here, so they
		-- are written as the value that means "no".
		local v = o.evex
		local nv = ~(v.vvvv or 0) & 15

		byte(a, 0x62)
		byte(a, (1 - rexr) << 7 | (1 - rexx) << 6 |
			(1 - rexb) << 5 | 1 << 4 | v.map)
		byte(a, (v.w or 0) << 7 | nv << 3 | 4 | (v.pp or 0))
		byte(a, (v.l or 0) << 5 | 1 << 3)
		byte(a, v.op)
	elseif o.vex then
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
		-- An address in 16-bit code is written the 16-bit way
		-- when it is nothing but a displacement, and the 32-bit
		-- way otherwise, which has to be asked for.
		local deflt = a.bits == 64 and 64 or a.bits
		-- The width the mode gives an address, in bytes, and the
		-- width the registers in this one ask for.
		local dfla = a.bits == 64 and 8 or (a.bits == 32 and 4 or 2)
		local aw = rm.kind == "mem" and not rm.rip and
			rm.awidth or nil

		if a.asize then
			if a.asize ~= deflt then byte(a, 0x67) end
		elseif aw and aw ~= dfla then
			byte(a, 0x67)
		end
		-- 32 and 64-bit code default to a four byte operand, 16-bit
		-- code to a two byte one, and the prefix asks for the
		-- other.
		if o.osize and ((a.bits == 16) == (o.osize == 4)) then
			byte(a, 0x66)
		end
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

	if rm.kind == "reg" or rm.kind == "xmm" or rm.kind == "ymm" or
	   rm.kind == "zmm" or rm.kind == "kreg" then
		byte(a, 0xc0 | reg << 3 | (rm.num & 7))
	elseif rm.rip then
		byte(a, 0x00 | reg << 3 | 5)
		-- A distance from the next instruction with no name on it:
		-- the field is that distance and the linker is not asked.
		if rm.here then
			imm(a, rm.here, 4)
			if o.imm then immrel(a, o) end
			return
		end
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
	elseif a.bits ~= 64 and (rm.nobase or rm.abs) and not rm.index then
		-- No SIB byte is needed: outside long mode mod 00 rm 101
		-- is the address itself, which is what gas writes.  In
		-- 16-bit code the same place is mod 00 rm 110 and the
		-- address is two bytes.
		local w = (a.asize or a.bits) == 16 and 2 or 4

		byte(a, 0x00 | reg << 3 | (w == 2 and 6 or 5))
		if rm.pcdisp then
			a:reloc("pc32", rm.pcdisp, rm.pcbase + a.cur.off)
			imm(a, 0, w)
		elseif rm.symdisp then
			a:reloc(w == 2 and "abs16" or "abs32", rm.symdisp,
				rm.disp)
			imm(a, 0, w)
		else
			imm(a, rm.disp, w)
		end
	elseif rm.awidth == 2 then
		-- A 16-bit address: the base and the index together are
		-- one of eight shapes, there is no scale, and there is no
		-- SIB byte.  `(%bx,%si)` is not `(%ebx,%esi)` with a
		-- prefix -- it is a different encoding.
		local key = tostring(rm.base) ..
			(rm.index and ("," .. rm.index) or "")
		local v = RM16[key]

		if not v or (rm.index and rm.scale ~= 1) then
			error("no 16-bit address of that shape")
		end
		local mod

		-- mod 00 with rm 110 is the displacement alone, so %bp
		-- on its own has to carry a zero byte.
		if rm.symdisp or rm.wide or not short(rm.disp) then
			mod = 2
		elseif rm.disp == 0 and v ~= 6 then
			mod = 0
		else
			mod = 1
		end
		byte(a, mod << 6 | reg << 3 | v)
		if mod == 2 then
			if rm.symdisp then
				a:reloc("abs16", rm.symdisp, rm.disp)
				imm(a, 0, 2)
			else
				imm(a, rm.disp, 2)
			end
		elseif mod == 1 then
			imm(a, rm.disp, 1)
		end
	elseif rm.index or rm.nobase then
		-- A scaled index needs the SIB byte, where 4 in the index
		-- field means there is none and 5 in the base field with
		-- mod 00 means the address is the displacement alone.
		local mod = 2

		if rm.nobase then
			mod = 0
		elseif rm.symdisp or rm.pcdisp or rm.wide then
			mod = 2
		elseif rm.disp == 0 and (rm.base & 7) ~= 5 then
			mod = 0
		elseif short(rm.disp) then
			mod = 1
		end
		byte(a, mod << 6 | reg << 3 | 4)
		byte(a, (SC[rm.scale] or 0) << 6 |
			(rm.index and (rm.index & 7) or 4) << 3 |
			(rm.nobase and 5 or (rm.base & 7)))
		if rm.nobase or mod == 2 then
			-- The addend travels in the relocation, so the
			-- field the linker writes over starts at zero.
			if rm.pcdisp then
				a:reloc("pc32", rm.pcdisp,
					rm.pcbase + a.cur.off)
				imm(a, 0, 4)
			elseif rm.symdisp then
				a:reloc("abs32s", rm.symdisp, rm.disp)
				imm(a, 0, 4)
			else
				imm(a, rm.disp, 4)
			end
		end
		if mod == 1 then imm(a, rm.disp // dn, 1) end
	elseif rm.abs then
		-- no base and no index: mod 00, rm 100, SIB saying so
		byte(a, 0x00 | reg << 3 | 4)
		byte(a, 0x25)
		imm(a, rm.disp, 4)
	else
		-- An instruction that only takes a place, given
		-- something that is not one.
		if not rm.base then
			error("this instruction takes a place, not " ..
				(rm.kind == "imm" and "a number" or
				 tostring(rm.kind)))
		end
		local b = rm.base & 7
		local mod
		if rm.tpoff or rm.got32 or rm.gotoff or rm.symdisp or
		   rm.pcdisp or rm.wide then
			mod = 2
		elseif rm.disp == 0 and b ~= 5 then
			mod = 0
		elseif short(rm.disp) then
			mod = 1
		else
			mod = 2
		end
		byte(a, mod << 6 | reg << 3 | (b == 4 and 4 or b))
		if b == 4 then byte(a, 0x24) end	-- SIB: base, no index
		if mod == 1 then imm(a, rm.disp // dn, 1) end
		if mod == 2 then
			if rm.tpoff then a:reloc("tpoff32", rm.tpoff, 0) end
			if rm.got32 then a:reloc("got32", rm.got32, 0) end
			if rm.gotoff then
				a:reloc("gotoff", rm.gotoff, rm.disp)
			end
			if rm.pcdisp then
				a:reloc("pc32", rm.pcdisp,
					rm.pcbase + a.cur.off)
				imm(a, 0, 4)
			elseif rm.symdisp then
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

-- Whether an immediate fits the short form.  A number written unsigned
-- stands for the same bits as the signed one, so `$0xffffffff` on a four
-- byte operand is -1 and one byte holds it.  Eight byte operands are left
-- alone: there the immediate is four bytes sign extended, and a value
-- that large is a different number, not the same one.
local function fitsbyte(v, size)
	if not v then return false end
	if size and size > 0 and size < 8 then
		local bits = size * 8

		v = v & ((1 << bits) - 1)
		if v >= (1 << (bits - 1)) then v = v - (1 << bits) end
	end
	return v >= -128 and v <= 127
end
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

local function splitword(m)
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
	    base == "lsl" or base == "movnti" or base == "crc32" or
	    base == "adcx" or base == "adox" or
	    base == "cvtsi2sd" or
	    base == "cvtsi2ss" or base == "cvttsd2si" or
	    base == "cvttss2si" or base == "cvtsd2si" or
	    base == "cvtss2si" or
	    -- The ones that take nothing: the letter names the operand
	    -- size, which is all that tells `pushfl` from `pushfw`.
	    base == "ret" or base == "iret" or base == "jmp" or
	    base == "lret" or base == "enter" or base == "leave" or
	    base == "pushf" or base == "popf" or
	    base == "pusha" or base == "popa") then
		return base, SIZE[suffix]
	end
	return m, nil
end

-- splitword by mnemonic, since the answer turns on the name alone.
local SPLIT = {}

local function split(m)
	local r = SPLIT[m]

	if not r then
		r = {splitword(m)}
		SPLIT[m] = r
	end
	return r[1], r[2]
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
-- The opcode and the width it moves.  The prefix is not written down:
-- which width needs one depends on the mode, and 16-bit code defaults
-- to two bytes where 32 and 64-bit code default to four.
local STRING = {
	insb = {0x6c, 1}, insw = {0x6d, 2}, insl = {0x6d, 4},
	outsb = {0x6e, 1}, outsw = {0x6f, 2}, outsl = {0x6f, 4},
	movsb = {0xa4, 1}, movsw = {0xa5, 2}, movsl = {0xa5, 4},
	movsq = {0xa5, 8},
	stosb = {0xaa, 1}, stosw = {0xab, 2}, stosl = {0xab, 4},
	stosq = {0xab, 8},
	lodsb = {0xac, 1}, lodsw = {0xad, 2}, lodsl = {0xad, 4},
	lodsq = {0xad, 8},
	scasb = {0xae, 1}, scasw = {0xaf, 2}, scasl = {0xaf, 4},
	scasq = {0xaf, 8},
	cmpsb = {0xa6, 1}, cmpsw = {0xa7, 2}, cmpsl = {0xa7, 4},
	cmpsq = {0xa7, 8},
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

-- The size prefixes named by what they ask for rather than by the byte
-- they write: whether a byte is needed at all turns on the mode the
-- code is in.  openbsd's wake-up trampoline writes `addr32 lidtl`.
-- addr16 is left out: sixteen-bit addressing names its registers with
-- an encoding of its own, which nothing here writes.
local SIZEPFX = {addr32 = {0x67, 32},
		 data32 = {0x66, 32}, data16 = {0x66, 16}}

-- The bit tests.  A register operand is 0F A3 and its kin; an
-- immediate is 0F BA with the operation in the reg field.
local BIT = {bt = {0xa3, 4}, bts = {0xab, 5}, btr = {0xb3, 6},
	     btc = {0xbb, 7}}

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
	     pminsw = {0xea, 0x66}, pmaxsw = {0xee, 0x66},
	     paddsb = {0xec, 0x66}, paddsw = {0xed, 0x66},
	     paddusb = {0xdc, 0x66}, paddusw = {0xdd, 0x66},
	     psubsb = {0xe8, 0x66}, psubsw = {0xe9, 0x66},
	     psubusb = {0xd8, 0x66}, psubusw = {0xd9, 0x66},
	     pmaddwd = {0xf5, 0x66}, pmulhw = {0xe5, 0x66},
	     pmulhuw = {0xe4, 0x66}, psadbw = {0xf6, 0x66},
	     packsswb = {0x63, 0x66}, packssdw = {0x6b, 0x66},
	     packuswb = {0x67, 0x66},
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

-- Between an integer register and the float file.  The general
-- register decides the width, so this cannot ride on the table
-- above, which is sixteen bytes wide throughout.
local CVTI = {cvtsi2ss = {0x2a, 0xf3}, cvtsi2sd = {0x2a, 0xf2}}

local CVTF = {cvttss2si = {0x2c, 0xf3}, cvttsd2si = {0x2c, 0xf2},
	      cvtss2si = {0x2d, 0xf3}, cvtsd2si = {0x2d, 0xf2}}

-- A bit scan, which reads a place and writes a register.
-- The double shifts, which take a count in cl or written out and
-- shift one register into another.
local DSH = {shld = 0xa4, shrd = 0xac}

local SCAN = {bsf = 0xbc, bsr = 0xbd}

-- The counted forms of the same, which are the scan opcodes
-- behind an F3 prefix, and the population count beside them.
local CNT = {tzcnt = 0xbc, lzcnt = 0xbd, popcnt = 0xb8}

-- The segment descriptor readers, which only a kernel writes.
local SEGQ = {lar = 0x02, lsl = 0x03}

-- The cache hints: 0F 18 with the level in the reg field, and
-- the write hint beside them at 0F 0D.
local PREF = {prefetchnta = 0, prefetcht0 = 1, prefetcht1 = 2,
	      prefetcht2 = 3}

local CACHE = {clflush = {0x0f, 0xae, 7},
	       clflushopt = {0x0f, 0xae, 7, 0x66},
	       clwb = {0x0f, 0xae, 6, 0x66}}

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

-- The hashing instructions, three byte opcodes with no prefix.
local SHA = {sha1nexte = 0xc8, sha1msg1 = 0xc9, sha1msg2 = 0xca,
	     sha256rnds2 = 0xcb, sha256msg1 = 0xcc,
	     sha256msg2 = 0xcd}

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
	vpcmpeqb = {0x74, 1, 1}, vpcmpeqw = {0x75, 1, 1},
	vpcmpeqd = {0x76, 1, 1}, vpcmpeqq = {0x29, 2, 1},
	vpcmpgtb = {0x64, 1, 1}, vpcmpgtw = {0x65, 1, 1},
	vpcmpgtd = {0x66, 1, 1}, vpcmpgtq = {0x37, 2, 1},
	vaesenc = {0xdc, 2, 1}, vaesenclast = {0xdd, 2, 1},
	vaesdec = {0xde, 2, 1}, vaesdeclast = {0xdf, 2, 1},
	vpshufb = {0x00, 2, 1}, vpmulld = {0x40, 2, 1},
	vpmaddubsw = {0x04, 2, 1}, vpmaddwd = {0xf5, 1, 1},
	vpaddusb = {0xdc, 1, 1}, vpaddusw = {0xdd, 1, 1},
	vpsubusb = {0xd8, 1, 1}, vpsubusw = {0xd9, 1, 1},
	vpackuswb = {0x67, 1, 1}, vpminub = {0xda, 1, 1},
	vpmaxub = {0xde, 1, 1},
	vpxorps = {0x57, 1, 0}, vxorps = {0x57, 1, 0},
	vandps = {0x54, 1, 0}, vorps = {0x56, 1, 0},
	-- The same eight with the size prefix, which is what
	-- tells a double from a single.  openbsd's mds.S writes
	-- vorpd.
	vxorpd = {0x57, 1, 1}, vandpd = {0x54, 1, 1},
	vorpd = {0x56, 1, 1}, vandnps = {0x55, 1, 0},
	vandnpd = {0x55, 1, 1},
	vaddps = {0x58, 1, 0}, vaddpd = {0x58, 1, 1},
	vsubps = {0x5c, 1, 0}, vsubpd = {0x5c, 1, 1},
	vmulps = {0x59, 1, 0}, vmulpd = {0x59, 1, 1},
	vdivps = {0x5e, 1, 0}, vdivpd = {0x5e, 1, 1},
	vminps = {0x5d, 1, 0}, vminpd = {0x5d, 1, 1},
	vmaxps = {0x5f, 1, 0}, vmaxpd = {0x5f, 1, 1},
	vunpcklps = {0x14, 1, 0}, vunpcklpd = {0x14, 1, 1},
	vunpckhps = {0x15, 1, 0}, vunpckhpd = {0x15, 1, 1},
	vaddss = {0x58, 1, 2}, vaddsd = {0x58, 1, 3},
	vsubss = {0x5c, 1, 2}, vsubsd = {0x5c, 1, 3},
	vmulss = {0x59, 1, 2}, vmulsd = {0x59, 1, 3},
	vdivss = {0x5e, 1, 2}, vdivsd = {0x5e, 1, 3},
}

-- The two operand forms: one source, one destination.
local VEX2 = {
	vpmovzxbd = {0x31, 2, 1}, vpmovzxbw = {0x30, 2, 1},
	vpmovzxwd = {0x33, 2, 1}, vpabsd = {0x1e, 2, 1},
	vpmovzxbq = {0x32, 2, 1}, vpmovzxwq = {0x34, 2, 1},
	vpmovzxdq = {0x35, 2, 1},
	vpmovsxbw = {0x20, 2, 1}, vpmovsxbd = {0x21, 2, 1},
	vpmovsxbq = {0x22, 2, 1}, vpmovsxwd = {0x23, 2, 1},
	vpmovsxwq = {0x24, 2, 1}, vpmovsxdq = {0x25, 2, 1},
	vbroadcastss = {0x18, 2, 1}, vbroadcastsd = {0x19, 2, 1},
	vbroadcastf128 = {0x1a, 2, 1},
	vbroadcasti128 = {0x5a, 2, 1},
	vpbroadcastb = {0x78, 2, 1}, vpbroadcastw = {0x79, 2, 1},
	vpbroadcastd = {0x58, 2, 1}, vpbroadcastq = {0x59, 2, 1},
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
	       vaeskeygenassist = {0xdf, 3, 1},
	       vpshuflw = {0x70, 1, 3},
	       vpermq = {0x00, 3, 1, w = 1},
	       vpermpd = {0x01, 3, 1, w = 1}}

local VMIX = {vpalignr = {0x0f, 3, 1}, vperm2i128 = {0x46, 3, 1},
	      vpclmulqdq = {0x44, 3, 1},
	      vperm2f128 = {0x06, 3, 1}, vpblendd = {0x02, 3, 1},
	      vinserti128 = {0x38, 3, 1}, vinsertf128 = {0x18, 3, 1}}

-- The shifts by a count written out, where the operation sits in
-- the reg field and the register written goes in the prefix.
local VEXSHI = {vpsrlw = {0x71, 2}, vpsrld = {0x72, 2},
	      vpsrlq = {0x73, 2}, vpsraw = {0x71, 4},
	      vpsrad = {0x72, 4}, vpsllw = {0x71, 6},
	      vpslld = {0x72, 6}, vpsllq = {0x73, 6},
	      vpsrldq = {0x73, 3}, vpslldq = {0x73, 7}}

-- The bit handling group, which the VEX prefix spells on the
-- ordinary registers.  In the first set the second operand is
-- the one the prefix carries, in the second the first.
local BMIA = {andn = {0xf2, 0}, mulx = {0xf6, 3},
	      pdep = {0xf5, 3}, pext = {0xf5, 2}}

local BMIB = {bextr = {0xf7, 0}, bzhi = {0xf5, 0},
	      shlx = {0xf7, 1}, sarx = {0xf7, 2},
	      shrx = {0xf7, 3}}

-- The AVX-512 spellings, which say the element width in the
-- name because the prefix carries it.
local EV3 = {vpxorq = {0xef, 1, 1, w = 1},
	     vpxord = {0xef, 1, 1, w = 0},
	     vpandq = {0xdb, 1, 1, w = 1},
	     vpandd = {0xdb, 1, 1, w = 0},
	     vporq = {0xeb, 1, 1, w = 1},
	     vpord = {0xeb, 1, 1, w = 0}}

local EVMIX = {vpternlogq = {0x25, 3, 1, w = 1},
	       vpternlogd = {0x25, 3, 1, w = 0}}

-- A quarter or a half of a wide register, which reaches only
-- that much memory and so scales its displacement by it.
-- Turning a mask into lanes and back: the mask register is one
-- operand and the vector the other, and nothing else about
-- them differs from any two operand EVEX form.
local EV2 = {vpmovm2b = {0x28, 2, 2, w = 0},
	     vpmovm2w = {0x28, 2, 2, w = 1},
	     vpmovm2d = {0x38, 2, 2, w = 0},
	     vpmovm2q = {0x38, 2, 2, w = 1},
	     vpmovb2m = {0x29, 2, 2, w = 0},
	     vpmovw2m = {0x29, 2, 2, w = 1},
	     vpmovd2m = {0x39, 2, 2, w = 0},
	     vpmovq2m = {0x39, 2, 2, w = 1},
	     -- Spreading a lane, or one value, over a register.
	     -- The letter pair says how wide the piece is and
	     -- how many of them: i64x2 is two eight-byte lanes,
	     -- which is one sixteen-byte piece repeated.
	     vbroadcasti32x4 = {0x5a, 2, 1, w = 0, n = 16},
	     vbroadcasti64x2 = {0x5a, 2, 1, w = 1, n = 16},
	     vbroadcasti32x8 = {0x5b, 2, 1, w = 0, n = 32},
	     vbroadcasti64x4 = {0x5b, 2, 1, w = 1, n = 32},
	     vbroadcastf32x4 = {0x1a, 2, 1, w = 0, n = 16},
	     vbroadcastf64x2 = {0x1a, 2, 1, w = 1, n = 16},
	     vbroadcastf32x8 = {0x1b, 2, 1, w = 0, n = 32},
	     vbroadcastf64x4 = {0x1b, 2, 1, w = 1, n = 32},
	     -- These four have a VEX form as well, and the wide
	     -- bit does not mean the same thing in the two, so
	     -- this entry is for the 512-bit one alone.
	     vpbroadcastb = {0x78, 2, 1, w = 0, n = 1, big = true},
	     vpbroadcastw = {0x79, 2, 1, w = 0, n = 2, big = true},
	     vpbroadcastd = {0x58, 2, 1, w = 0, n = 4, big = true},
	     vpbroadcastq = {0x59, 2, 1, w = 1, n = 8, big = true}}

local EVCUT = {vextracti32x4 = {0x39, w = 0, n = 16},
	       vextractf32x4 = {0x19, w = 0, n = 16},
	       vextracti64x4 = {0x3b, w = 1, n = 32},
	       vextractf64x4 = {0x1b, w = 1, n = 32}}

local EVPUT = {vinserti32x4 = {0x38, w = 0, n = 16},
	       vinsertf32x4 = {0x18, w = 0, n = 16},
	       vinserti64x4 = {0x3a, w = 1, n = 32},
	       vinsertf64x4 = {0x1a, w = 1, n = 32}}

local EVMOV = {vmovdqu8 = {3, 0}, vmovdqu16 = {3, 1},
	       vmovdqu32 = {2, 0}, vmovdqu64 = {2, 1},
	       vmovdqa32 = {1, 0}, vmovdqa64 = {1, 1}}

-- Moving a mask: between two mask registers or memory (90 to
-- load, 91 to store) and between a mask register and a general
-- one (92 in, 93 out).  Which width is which prefix is the one
-- part of this that has to be read from the table rather than
-- worked out: b and d take the size prefix, w and q do not,
-- and the general register forms put d and q behind F2.
local KMOV = {kmovb = {pp = 1, w = 0, gpp = 1},
	      kmovw = {pp = 0, w = 0, gpp = 0},
	      kmovd = {pp = 1, w = 1, gpp = 3},
	      kmovq = {pp = 0, w = 1, gpp = 3, gw = 1}}

-- Taking one lane out and putting one in, in the VEX spelling.
local VEXTR = {vpextrb = 0x14, vpextrw = 0x15, vpextrd = 0x16,
	       vpextrq = 0x16, vextractps = 0x17}

local VINSR = {vpinsrb = 0x20, vpinsrw = 0xc4, vpinsrd = 0x22,
	       vpinsrq = 0x22, vinsertps = 0x21}

-- The blend whose mask is a register, which the encoding puts in
-- the top half of a pattern byte.
local VBLENDV = {vpblendvb = 0x4c, vblendvps = 0x4a,
		 vblendvpd = 0x4b}

-- A store that does not keep the line, in the VEX encoding.
-- There is no load form: the register is always the source,
-- which is why these are not in the table above.
local VNTST = {vmovntdq = {0xe7, 1, 1}, vmovntps = {0x2b, 1, 0},
	       vmovntpd = {0x2b, 1, 1}}

-- The three byte vector opcodes that take a pattern byte,
-- 66 0F 3A xx.
local V3A = {palignr = 0x0f, pblendw = 0x0e, roundpd = 0x09,
	     roundps = 0x08, roundsd = 0x0b, roundss = 0x0a,
	     pinsrb = 0x20, pinsrd = 0x22, pclmulqdq = 0x44,
	     aeskeygenassist = 0xdf}

-- The other way round: the vector register is the source and
-- names the reg field, and what it is taken apart into is the
-- rm operand, register or memory alike.
local V3AX = {pextrb = 0x14, pextrw = 0x15, pextrd = 0x16,
	      pextrq = 0x16, extractps = 0x17}

-- The three byte vector opcodes this compiler needs, 66 0F 38 xx.
-- The blends take xmm0 as a third operand the encoding takes
-- for granted.
local VBLEND = {pblendvb = 0x10, blendvps = 0x14, blendvpd = 0x15}

-- The AES round instructions, which a kernel's crypto writes
-- out by hand.
local V38 = {aesimc = 0xdb, aesenc = 0xdc, aesenclast = 0xdd,
	     aesdec = 0xde, aesdeclast = 0xdf,
	     pshufb = 0x00, pmulld = 0x40, pcmpeqq = 0x29,
	     pmaddubsw = 0x04,
	     packusdw = 0x2b, ptest = 0x17, pminsb = 0x38,
	     pmaxsb = 0x3c, pminud = 0x3b, pmaxud = 0x3f,
	     pmovzxbw = 0x30, pmovzxbd = 0x31, pmovzxbq = 0x32,
	     pmovzxwd = 0x33, pmovzxwq = 0x34, pmovzxdq = 0x35,
	     pmovsxbw = 0x20, pmovsxbd = 0x21, pmovsxbq = 0x22,
	     pmovsxwd = 0x23, pmovsxwq = 0x24, pmovsxdq = 0x25}

-- The thread pointer registers, F3 0F AE with the operation in
-- the reg field.
local BASE = {rdfsbase = 0, rdgsbase = 1, wrfsbase = 2,
	      wrgsbase = 3}

-- Saving and restoring the floating point and vector state,
-- 0F AE with the operation in the reg field.
local FXS = {fxsave = 0, fxrstor = 1, ldmxcsr = 2, stmxcsr = 3,
	     xsave = 4, xrstor = 5, xsaveopt = 6}

local RAND = {rdrand = 6, rdseed = 7}

-- A store that does not keep the line: the register is the
-- source, so it takes the reg field and the place takes the
-- other.  linux clears the CPU buffers with one of these.
local NTST = {movntdq = {0xe7, 0x66}, movntps = {0x2b},
	      movntpd = {0x2b, 0x66}}

-- The shuffles, which take a pattern byte: pshufd wants the size
-- prefix, shufps does not.
local SHUF = {pshufd = {0x70, 2}, pshufhw = {0x70, nil, 0xf3},
	      pshuflw = {0x70, nil, 0xf2}, shufps = {0xc6},
	      shufpd = {0xc6, 2}}

-- the widening moves, whose two sizes are in the mnemonic
-- The fourth field is the width of what it widens to.  That is
-- the operand size, and in 16-bit code a four byte one needs
-- the prefix that says so -- without it `movswl` is `movsww`
-- and the top half of the register keeps what it had.
local WIDEN = {
	movsbw = {{0x0f, 0xbe}, 1, false, 2},
	movsbl = {{0x0f, 0xbe}, 1, false, 4},
	movsbq = {{0x0f, 0xbe}, 1, true},
	movswl = {{0x0f, 0xbf}, 2, false, 4},
	movswq = {{0x0f, 0xbf}, 2, true},
	movzbw = {{0x0f, 0xb6}, 1, false, 2},
	movzbl = {{0x0f, 0xb6}, 1, false, 4},
	movzbq = {{0x0f, 0xb6}, 1, true},
	movzwl = {{0x0f, 0xb7}, 2, false, 4},
	movzwq = {{0x0f, 0xb7}, 2, true},
	movslq = {{0x63}, 4, true},
}

-- Saving and restoring the extended state, which a kernel does on
-- every context switch.  All of them are 0F AE with the operation
-- in the reg field, and the 64 forms add REX.W.
local XSAVE = {fxsave = 0, fxrstor = 1, xsave = 4, xrstor = 5,
	       xsaveopt = 6}

-- The supervisor forms are the same idea under another opcode.
local XSAVES = {xrstors = 3, xsavec = 4, xsaves = 5}

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
	-- a time.  The w and l forms carry a size letter, so they
	-- go through NOOP, where the mode decides the prefix.
	pushfq = {0x9c}, popfq = {0x9d}, pushf = {0x9c},
	popf = {0x9d}, cld = {0xfc}, std = {0xfd},
	leaveq = {0xc9}, retq = {0xc3}, sysret = {0x0f, 0x07},
	sysretq = {0x48, 0x0f, 0x07}, ["int3"] = {0xcc},
	clc = {0xf8}, stc = {0xf9}, cmc = {0xf5},
	sysretl = {0x0f, 0x07}, sysexitl = {0x0f, 0x35},
	sysexitq = {0x48, 0x0f, 0x35},
	clac = {0x0f, 0x01, 0xca}, stac = {0x0f, 0x01, 0xcb},
	lret = {0xcb}, lretq = {0x48, 0xcb}, iret = {0xcf},
	sahf = {0x9e}, lahf = {0x9f},
	sysenter = {0x0f, 0x34}, sysexit = {0x0f, 0x35},
	ud0 = {0x0f, 0xff}, ud1 = {0x0f, 0xb9},
	emms = {0x0f, 0x77}, femms = {0x0f, 0x0e},
}

-- The ones that take nothing and whose letter names an operand
-- size.  The prefix asks for the size the mode does not give,
-- which is how a boot stub in 16-bit code writes `pushfl`.
local NOOP = {ret = 0xc3, lret = 0xcb, iret = 0xcf, pushf = 0x9c,
	      popf = 0x9d, pusha = 0x60, popa = 0x61}

-- Under `.code16gcc` the ones that move the stack take a four
-- byte operand where the mode would give two.  iret is not one
-- of them: gas leaves that 16-bit and says so.
local WIDENS = {ret = true, pushf = true, popf = true,
		pusha = true, popa = true}

-- The descriptor table instructions and their kin: 0F 01 with the
-- operation in the reg field.
local G7 = {sgdt = 0, sidt = 1, lgdt = 2, lidt = 3, smsw = 4,
	    lmsw = 6, invlpg = 7}

local G6 = {sldt = 0, str = 1, lldt = 2, ltr = 3, verr = 4,
	    verw = 5}

-- The VMX instructions a hypervisor writes.  The pointer forms
-- share one opcode and differ in the reg field and the prefix;
-- openbsd's vmm writes every one of them.
local VMX = {vmxon = {0xf3, 6}, vmclear = {0x66, 6},
	     vmptrld = {nil, 6}, vmptrst = {nil, 7}}

-- The AMD forms name %rax, %eax or %ax, which the encoding does
-- not carry: the operand is written and dropped.
local SVM = {vmrun = 0xd8, vmmcall = 0xd9, vmload = 0xda,
	     vmsave = 0xdb, invlpga = 0xdf, skinit = 0xde}

-- The count-register loops, which only reach a byte away.  A
-- kernel's delay loops are written with them.
local LOOP = {loop = 0xe2, loope = 0xe1, loopz = 0xe1,
	      loopne = 0xe0, loopnz = 0xe0, jrcxz = 0xe3,
	      jecxz = 0xe3}

-- Widening the accumulator in place.  Which pair of registers
-- it names is the operand size, so in 16-bit code the four byte
-- forms carry the prefix and the two byte forms do not.
local ACC = {cbtw = {0x98, 2}, cwtl = {0x98, 4},
	     cwtd = {0x99, 2}, cltd = {0x99, 4}}

-- push, pop, call, ret, leave and enter move a word of the mode's own
-- width unless a letter says otherwise.  `.code16gcc` is 16-bit code
-- from a 32-bit code generator, so there the width they default to is
-- four rather than two.
local function stackw(a, size)
	if size then return size end
	if a.bits == 16 then return a.stackop or 2 end
	return a.bits == 64 and 8 or 4
end

-- The prefix that asks for the width the mode does not give.
local function stackp(a, w)
	if (w == 2 or w == 4) and ((a.bits == 16) == (w == 4)) then
		byte(a, 0x66)
	end
end

-- A call to a name.  The distance is as wide as the operand size: two
-- bytes in 16-bit code, four otherwise, and `.code16gcc` makes it four
-- there too.  The prefix goes down before the distance is measured,
-- because it is part of the way.
local function calldirect(a, size, sym)
	local w = stackw(a, size) == 2 and 2 or 4

	a.lasteax = nil
	stackp(a, w)
	local rel = a:localhere(sym)

	byte(a, 0xe8)
	if rel then return imm(a, rel - 1 - w, w) end
	a:reloc(w == 2 and "pc16" or callkind(a), sym, -w)
	return imm(a, 0, w)
end

-- A jump to a name; `cc` is the condition, nil for jmp.  Two forms
-- reach two distances, and the real assembler takes the shorter
-- whenever it reaches.  A pass that has not placed the label yet
-- assumes it does and asks to be run again; from there a form only
-- ever grows, so this settles.
local function jumpdirect(a, cc, sym)
	a.lasteax = nil
	a.nbr = a.nbr + 1
	local id = a.nbr
	-- A branch reaches a place, not a name: the loader never puts
	-- one through a table, so the distance to a definition in this
	-- section holds even when the name is global.  gas measures it
	-- the same way.
	local rel = a:here(sym)

	-- Which form is used comes from the decision made at the end of
	-- the last round and from nothing else.  A pass that widened as
	-- it measured would move the ground under the next measurement.
	-- A target this file never defines takes the long form.
	if not a.long[id] then
		local d = (rel or 0) - 2

		if a.pass == 1 and (not rel or d < -128 or d > 127) then
			a.pending[id] = true
		end
		byte(a, cc and (0x70 + cc) or 0xeb)
		return imm(a, d, 1)
	end
	local w = a.bits == 16 and 2 or 4

	if cc then
		byte(a, 0x0f)
		byte(a, 0x80 + cc)
	else
		byte(a, 0xe9)
	end
	if rel then return imm(a, rel - (cc and 2 or 1) - w, w) end
	-- A branch to a name this file does not define may end up going
	-- through the table the loader fills in, the same as a call,
	-- which is what gas says of one.
	a:reloc(w == 2 and "pc16" or callkind(a), sym, -w)
	return imm(a, 0, w)
end

-- The direct jumps and calls by mnemonic, which amd64.inst answers
-- before its search through the tables: the condition code of a jump,
-- false for jmp, and the size letter of a call.
local JUMP = {jmp = false, jmpq = false, jmpl = false, jmpw = false}
for k, v in pairs(CC) do JUMP["j" .. k] = v end
local CALL = {call = false, callq = 8, calll = 4, callw = 2}

-- The control and debug register moves: load opcode, store opcode.
local CTL = {cr = {0x20, 0x22}, dr = {0x21, 0x23}}
-- The segment register pushes and pops, one byte and two byte.
local SEG1 = {es = 0x06, cs = 0x0e, ss = 0x16, ds = 0x1e}
local SEG2 = {fs = 0xa0, gs = 0xa8}

function amd64.inst(a, m, ops)
	-- gas folds the case of a mnemonic, and a kernel leans on it:
	-- arch/x86/kernel/ftrace_64.S writes `CALL` in capitals.  Only
	-- the mnemonic folds; a name is what it is written as.
	if m:find("%u") then m = m:lower() end
	-- The carry-less multiply's halves, named: `pclmullqhqdq` is
	-- `pclmulqdq $0x10`.
	local v, lo, hi = m:match("^(v?)pclmul([lh]q)([lh]q)dq$")

	if v then
		local imm = (lo == "hq" and 1 or 0) | (hi == "hq" and 0x10 or 0)
		local no = {("$0x%x"):format(imm)}

		for _, x in ipairs(ops) do no[#no + 1] = x end
		return amd64.inst(a, v .. "pclmulqdq", no)
	end
	local top = a.redook
	local cc, csize = JUMP[m], CALL[m]

	a.redook = nil
	if (cc ~= nil or csize ~= nil) and #ops == 1 and
	   ops[1]:sub(1, 1) ~= "*" then
		local o = operand(a, ops[1])

		if o.kind == "sym" then
			local fn, x = jumpdirect, cc or nil

			if cc == nil then fn, x = calldirect, csize or nil end
			if top then a:redo(fn, x, o.sym) end
			return fn(a, x, o.sym)
		end
	end
	if SIZEPFX[m] then
		local d = SIZEPFX[m]
		local rest = table.concat(ops, ",")
		local nm, tail = rest:match("^%s*([%w_.]+)%s*(.*)$")

		-- An address size the code asks for decides both the
		-- prefix byte and the shape of the address itself, so
		-- the instruction is told rather than the byte written
		-- here.  An operand size is only ever the byte.
		if d[1] == 0x66 then
			if d[2] ~= a.bits then byte(a, d[1]) end
			if not nm then return end
			local no = {}

			for t in tail:gmatch("[^,]+") do no[#no + 1] = t end
			return amd64.inst(a, nm, no)
		end
		if not nm then
			byte(a, d[1])
			return
		end
		local no = {}

		for t in tail:gmatch("[^,]+") do no[#no + 1] = t end
		a.asize = d[2]
		local okrun, err = pcall(amd64.inst, a, nm, no)

		a.asize = nil
		if not okrun then error(err, 0) end
		return
	end
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
	if STRING[m] then
		local op, sz = STRING[m][1], STRING[m][2]

		if (sz == 2 or sz == 4) and ((a.bits == 16) == (sz == 4)) then
			byte(a, 0x66)
		end
		if sz == 8 then byte(a, 0x48) end
		byte(a, op)
		return
	end
	if PADLOCK[m] then
		for _, b in ipairs(PADLOCK[m]) do byte(a, b) end
		return
	end
	if x87(a, m, ops) then return end
	local base, size = split(m)
	local o = {}
	for i, t in ipairs(ops) do o[i] = operand(a, t) end

	-- A mnemonic with no size letter takes its size from a register
	-- operand, which is what gas does.  A shift counts by cl and no
	-- other register, so that operand says nothing about the width:
	-- `shl %cl,%rax` is a quadword shift, not a byte one.
	local first = 1

	if #o > 1 and (SHIFT[base] or base == "shld" or base == "shrd") then
		first = 2
	end
	if not size then
		for i = first, #o do
			if o[i].kind == "reg" then
				size = o[i].size
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
	local function stackwidth() return stackw(a, size) end
	local function stackpfx(w) stackp(a, w) end
	-- Which operand size the instruction asks for, when the opcode
	-- does not say.  Two and four both matter: the prefix means the
	-- other one, and which is the other one depends on the mode.
	local function osize()
		return (size == 2 or size == 4) and size or nil
	end
	-- a byte operation that names one of the low four registers by its
	-- new name needs REX to mean that register and not ah..bh
	-- The low byte of rsp, rbp, rsi and rdi is only reachable with a
	-- REX prefix.  `%ah` and its three share those numbers and must
	-- not have one: the prefix is what tells the two apart.
	local function needrex(x)
		return size == 1 and x and x.kind == "reg" and
			not x.norex and x.num >= 4 and x.num < 8
	end

	-- Moving to or from a control or debug register: the number goes
	-- in the reg field, and the operand size is always eight bytes.
	if base == "mov" and #o == 2 then
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
				osize = (dst.size == 2 or dst.size == 4)
					and dst.size or nil})
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
			-- A whole register`s worth of value has nowhere to
			-- go but the ten-byte form: the plain one carries
			-- four bytes and reads them as signed.
			if dst.kind == "reg" and size == 8 and
			   not src.rel and
			   (src.val < -0x80000000 or src.val > 0x7fffffff) then
				return insn(a, {op = {0xb8 + (dst.num & 7)},
					reg = 0, rm = dst, rexw = true,
					norm = true, rex = needrex(dst),
					imm = src.val, immsize = 8})
			end
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
		-- Outside long mode the accumulator and a fixed address
		-- take the short form, the address straight after the
		-- opcode, as gas writes it.
		local function fixed(x)
			return x.kind == "sym" or (x.kind == "mem" and
				not x.base and not x.index and
				(x.abs or x.nobase) and not x.pcdisp and
				not x.rip)
		end
		local acc = src.kind == "reg" and src.num == 0 and fixed(dst)
			and dst or (dst.kind == "reg" and dst.num == 0 and
			fixed(src) and src)
		if a.bits ~= 64 and acc and size ~= 8 then
			local w = (a.asize or a.bits) == 16 and 2 or 4
			local sym, disp = nil, acc.disp or 0

			if acc.kind == "sym" then
				local n, s2, off = a:symexpr(acc.sym)

				if n then disp = n else sym, disp = s2 or
					acc.sym, off or 0 end
			elseif acc.symdisp then
				sym = acc.symdisp
			end
			local op = (acc == dst and 0xa2 or 0xa0) +
				(size == 1 and 0 or 1)

			return insn(a, {op = {op}, reg = 0,
				rm = acc == dst and src or dst, norm = true,
				osize = osize(),
				prefix = acc.prefix and {acc.prefix} or nil,
				imm = sym and 0 or disp, immsize = w,
				immrel = sym and {sym = sym, addend = disp}})
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
			   fitsbyte(src.val, size) then
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
	-- `imull $c,%eax` is the three operand form with the destination
	-- written once, which is how gas reads it.
	if base == "imul" and #ops == 2 and o[1].kind == "imm" then
		o[3], ops[3] = o[2], ops[2]
	end
	if base == "imul" and #o == 3 then
		local v = o[1].val
		if not o[1].rel and fitsbyte(v, size) then
			return insn(a, {op = {0x6b}, reg = o[3], rm = o[2],
				size = size, rexw = rexw(), osize = osize(),
				imm = v, immsize = 1})
		end
		return insn(a, {op = {0x69}, reg = o[3], rm = o[2],
			size = size, rexw = rexw(), osize = osize(),
			imm = v, immsize = 4})
	end
	if base == "imul" and #o == 2 then
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
		-- The segment registers have opcodes of their own, and
		-- a kernel's bios call saves two of them.  The four the
		-- 8086 had are one byte and long mode has none of them;
		-- fs and gs are two bytes and long mode has both.
		local sr = o[1].seg

		if sr and SEG2[sr] then
			byte(a, 0x0f)
			return byte(a, SEG2[sr] + (up and 0 or 1))
		end
		if sr and SEG1[sr] then
			if a.bits == 64 then
				error("no instruction " .. m .. " %" .. sr)
			end
			if not up and sr == "cs" then
				error("no instruction pop %cs")
			end
			return byte(a, SEG1[sr] + (up and 0 or 1))
		end
		local w = stackwidth()

		if o[1].kind == "reg" then
			return insn(a, {op = {(up and 0x50 or 0x58) +
				(o[1].num & 7)}, reg = 0, rm = o[1],
				osize = (w == 2 or w == 4) and w or nil,
				norm = true})
		end
		if o[1].kind == "imm" then
			if not up then error("pop needs a place") end
			local v = o[1].val
			if not o[1].rel and v and v >= -128 and
			   v <= 127 then
				stackpfx(w)
				byte(a, 0x6a)
				return a:emit(v & 0xff, 1)
			end
			-- The immediate is two bytes or four; in long
			-- mode the four are widened to eight on the way
			-- to the stack.
			local iw = w == 2 and 2 or 4

			stackpfx(w)
			byte(a, 0x68)
			if o[1].rel then
				a:reloc(iw == 2 and "abs16" or "abs32s",
					o[1].rel.sym, o[1].rel.addend)
			end
			return a:emit((v or 0) & ((1 << (iw * 8)) - 1), iw)
		end
		return insn(a, {op = {up and 0xff or 0x8f},
			osize = (w == 2 or w == 4) and w or nil,
			reg = up and 6 or 0, rm = o[1]})
	end


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
	-- The byte mask: an integer register from the top bit of each
	-- byte of a vector one.
	if m == "pmovmskb" and #o == 2 then
		return insn(a, {op = {0x0f, 0xd7}, reg = o[2], rm = o[1],
			size = 4, prefix = {0x66}})
	end
	if VOP[m] and #o == 2 then
		local d = VOP[m]

		return insn(a, {op = {0x0f, d[1]}, reg = o[2], rm = o[1],
			size = 16, prefix = d[2] and {d[2]} or nil})
	end

	if DSH[base] and #o == 3 then
		-- The count is in cl or written out, so the width comes
		-- from the two registers being shifted, not from the
		-- first operand.
		local sz = o[3].size or o[2].size or size

		if o[1].kind == "imm" then
			return insn(a, {op = {0x0f, DSH[base]}, reg = o[2],
				rm = o[3], size = sz,
				rexw = sz == 8 or nil,
				osize = (sz == 2 or sz == 4) and sz or nil,
				imm = o[1].val,
				immrel = o[1].rel, immsize = 1})
		end
		return insn(a, {op = {0x0f, DSH[base] + 1}, reg = o[2],
			rm = o[3], size = sz, rexw = sz == 8 or nil,
			osize = (sz == 2 or sz == 4) and sz or nil})
	end

	if SCAN[base] and #o == 2 then
		return insn(a, {op = {0x0f, SCAN[base]}, reg = o[2],
			rm = o[1], size = size, rexw = rexw(),
			osize = osize()})
	end

	if CNT[base] and #o == 2 then
		return insn(a, {op = {0x0f, CNT[base]}, reg = o[2],
			rm = o[1], size = size, rexw = rexw(),
			osize = osize(), prefix = {0xf3}})
	end

	if SEGQ[base] and #o == 2 then
		return insn(a, {op = {0x0f, SEGQ[base]}, reg = o[2],
			rm = o[1], size = size, rexw = rexw(),
			osize = osize()})
	end

	if PREF[m] and #o == 1 then
		return insn(a, {op = {0x0f, 0x18}, reg = PREF[m],
			rm = o[1], size = 1})
	end
	if (m == "prefetch" or m == "prefetchw") and #o == 1 then
		return insn(a, {op = {0x0f, 0x0d},
			reg = m == "prefetchw" and 1 or 0,
			rm = o[1], size = 1})
	end

	if CACHE[m] and #o == 1 then
		local d = CACHE[m]

		return insn(a, {op = {d[1], d[2]}, reg = d[3], rm = o[1],
			size = 1, prefix = d[4] and {d[4]} or nil})
	end

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

	if SHA[m] and #o >= 2 then
		-- sha256rnds2 names xmm0 as a third operand, which the
		-- encoding takes for granted.
		return insn(a, {op = {0x0f, 0x38, SHA[m]}, reg = o[2],
			rm = o[1], size = 16})
	end

	-- 256 bits wide when any register named is.
	local function wide()
		for _, x in ipairs(o) do
			if x.kind == "zmm" then return 2 end
		end
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
	if VEXSHI[m] and #o == 3 and o[1].kind == "imm" then
		local d = VEXSHI[m]

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

	if (BMIA[base] or BMIB[base]) and #o == 3 then
		local d = BMIA[base] or BMIB[base]
		local sz = o[3].size or size
		local rm, vv = o[1], o[2]

		if BMIB[base] then rm, vv = o[2], o[1] end
		return insn(a, {rm = rm, reg = o[3],
			vex = {op = d[1], map = 2, pp = d[2],
			       w = sz == 8 and 1 or 0, vvvv = vv.num}})
	end
	if VEX3[m] and #o == 3 then
		local d = VEX3[m]

		return insn(a, {rm = o[1], reg = o[3],
			vex = {op = d[1], map = d[2], pp = d[3],
			       l = wide(), vvvv = o[2].num}})
	end

	if EV3[m] and #o == 3 then
		local d = EV3[m]

		return insn(a, {rm = o[1], reg = o[3],
			evex = {op = d[1], map = d[2], pp = d[3], w = d.w,
				l = wide(), vvvv = o[2].num}})
	end
	if EVMIX[m] and #o == 4 and o[1].kind == "imm" then
		local d = EVMIX[m]

		return insn(a, {rm = o[2], reg = o[4], imm = o[1].val,
			immsize = 1,
			evex = {op = d[1], map = d[2], pp = d[3], w = d.w,
				l = wide(), vvvv = o[3].num}})
	end
	if EV2[m] and #o == 2 and not (EV2[m].big and wide() ~= 2) then
		local d = EV2[m]

		return insn(a, {rm = o[1], reg = o[2],
			evex = {op = d[1], map = d[2], pp = d[3], w = d.w,
				l = wide(), n = d.n}})
	end
	if EVCUT[m] and #o == 3 then
		local d = EVCUT[m]

		return insn(a, {rm = o[3], reg = o[2], imm = o[1].val,
			immsize = 1,
			evex = {op = d[1], map = 3, pp = 1, w = d.w,
				l = wide(), n = d.n}})
	end
	if EVPUT[m] and #o == 4 then
		local d = EVPUT[m]

		return insn(a, {rm = o[2], reg = o[4], imm = o[1].val,
			immsize = 1,
			evex = {op = d[1], map = 3, pp = 1, w = d.w,
				l = wide(), n = d.n, vvvv = o[3].num}})
	end
	if EVMOV[m] and #o == 2 then
		local d = EVMOV[m]
		local store = o[2].kind ~= "xmm" and o[2].kind ~= "ymm"
			and o[2].kind ~= "zmm"

		return insn(a, {rm = store and o[2] or o[1],
			reg = store and o[1] or o[2],
			evex = {op = store and 0x7f or 0x6f, map = 1,
				pp = d[1], w = d[2], l = wide()}})
	end
	-- The two AVX-512 forms a kernel writes, on the narrow registers:
	-- the two source permute, and the rotate that takes its count in
	-- an immediate.
	if m == "vpermi2d" and #o == 3 then
		return insn(a, {rm = o[1], reg = o[3],
			evex = {op = 0x76, map = 2, pp = 1,
				l = wide(), vvvv = o[2].num}})
	end
	if (m == "vprord" or m == "vprold") and #o == 3 and
	   o[1].kind == "imm" then
		-- The answer goes in the field that names a second
		-- source, and the opcode says which way it turns.
		return insn(a, {rm = o[2], reg = m == "vprord" and 0 or 1,
			imm = o[1].val, immsize = 1,
			evex = {op = 0x72, map = 1, pp = 1,
				l = wide(), vvvv = o[3].num}})
	end

	if KMOV[m] and #o == 2 then
		local d = KMOV[m]
		local src, dst = o[1], o[2]

		if dst.kind == "kreg" and src.kind == "reg" then
			return insn(a, {rm = src, reg = dst,
				vex = {op = 0x92, map = 1, pp = d.gpp,
				       w = d.gw or 0}})
		end
		if dst.kind == "reg" and src.kind == "kreg" then
			return insn(a, {rm = src, reg = dst,
				vex = {op = 0x93, map = 1, pp = d.gpp,
				       w = d.gw or 0}})
		end
		if dst.kind == "kreg" then
			return insn(a, {rm = src, reg = dst,
				vex = {op = 0x90, map = 1, pp = d.pp,
				       w = d.w}})
		end
		return insn(a, {rm = dst, reg = src,
			vex = {op = 0x91, map = 1, pp = d.pp, w = d.w}})
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

	if VEXTR[m] and #o == 3 then
		return insn(a, {rm = o[3], reg = o[2], imm = o[1].val,
			immsize = 1,
			vex = {op = VEXTR[m], map = 3, pp = 1,
			       w = m == "vpextrq" and 1 or 0}})
	end
	if VINSR[m] and #o == 4 then
		return insn(a, {rm = o[2], reg = o[4], imm = o[1].val,
			immsize = 1,
			vex = {op = VINSR[m],
			       map = m == "vpinsrw" and 1 or 3, pp = 1,
			       w = m == "vpinsrq" and 1 or 0,
			       vvvv = o[3].num}})
	end

	if VBLENDV[m] and #o == 4 then
		return insn(a, {rm = o[2], reg = o[4],
			imm = o[1].num << 4, immsize = 1,
			vex = {op = VBLENDV[m], map = 3, pp = 1,
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
	if m == "vpmovmskb" and #o == 2 then
		return insn(a, {rm = o[1], reg = o[2],
			vex = {op = 0xd7, map = 1, pp = 1, l = wide()}})
	end
	if VMOVV[m] and #o == 2 then
		local d = VMOVV[m]
		local w = m == "vmovq" and 1 or nil

		-- The store form when what is written is not a register
		-- of the vector file.
		if o[2].kind ~= "xmm" and o[2].kind ~= "ymm" and
		   o[2].kind ~= "zmm" then
			return insn(a, {rm = o[2], reg = o[1],
				vex = {op = d[2], map = d[3], pp = d[4],
				       l = wide(), w = w}})
		end
		return insn(a, {rm = o[1], reg = o[2],
			vex = {op = d[1], map = d[3], pp = d[4],
			       l = wide(), w = w}})
	end

	if VNTST[m] and #o == 2 then
		local d = VNTST[m]

		return insn(a, {rm = o[2], reg = o[1],
			vex = {op = d[1], map = d[2], pp = d[3],
			       l = wide()}})
	end

	-- Taking a word out into a register is the older 66 0F C5, with
	-- the register named in the reg field rather than the rm one.
	-- Only a place in memory needs the 0F 3A form.
	if base == "pextrw" and #o == 3 and o[3].kind == "reg" then
		return insn(a, {op = {0x0f, 0xc5}, reg = o[3], rm = o[2],
			size = 16,
			prefix = {0x66}, imm = o[1].val,
			immrel = o[1].rel, immsize = 1})
	end
	if V3AX[base] and #o == 3 then
		return insn(a, {op = {0x0f, 0x3a, V3AX[base]}, reg = o[2],
			rm = o[3], size = 16, prefix = {0x66},
			rexw = base == "pextrq",
			imm = o[1].val, immrel = o[1].rel, immsize = 1})
	end

	-- The word insert is older than the 0F 3A group its byte and
	-- long kin live in: 66 0F C4 with the pattern byte after it.
	if base == "pinsrw" and #o == 3 then
		return insn(a, {op = {0x0f, 0xc4}, reg = o[3], rm = o[2],
			size = 16, prefix = {0x66},
			imm = o[1].val, immrel = o[1].rel, immsize = 1})
	end
	if V3A[base] and #o == 3 then
		return insn(a, {op = {0x0f, 0x3a, V3A[base]}, reg = o[3],
			rm = o[2], size = 16, prefix = {0x66},
			imm = o[1].val, immrel = o[1].rel, immsize = 1})
	end
	-- The one round-of-four that takes a pattern byte and no size
	-- prefix, 0F 3A CC.
	if m == "sha1rnds4" and #o == 3 then
		return insn(a, {op = {0x0f, 0x3a, 0xcc}, reg = o[3],
			rm = o[2], size = 16,
			imm = o[1].val, immrel = o[1].rel, immsize = 1})
	end
	-- The checksum, F2 0F 38 F0 over a byte and F1 over anything
	-- wider.  The size is the source, and the answer is a register.
	if base == "crc32" and #o == 2 then
		return insn(a, {op = {0x0f, 0x38,
			size == 1 and 0xf0 or 0xf1},
			reg = o[2], rm = o[1], size = size,
			rexw = size == 8, osize = osize(),
			prefix = {0xf2}})
	end

	-- The carry chains of ADX, 0F 38 F6: 66 adds with the carry flag,
	-- F3 with the overflow flag.
	if (base == "adcx" or base == "adox") and #o == 2 then
		return insn(a, {op = {0x0f, 0x38, 0xf6},
			reg = o[2], rm = o[1], size = size,
			rexw = size == 8,
			prefix = {base == "adcx" and 0x66 or 0xf3}})
	end

	if VBLEND[m] and #o >= 2 then
		return insn(a, {op = {0x0f, 0x38, VBLEND[m]},
			reg = o[#o], rm = o[#o - 1], size = 16,
			prefix = {0x66}})
	end

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

	if BASE[base] and #o == 1 then
		return insn(a, {op = {0x0f, 0xae}, reg = BASE[base],
			rm = o[1], size = size or 8, rexw = rexw(),
			prefix = {0xf3}})
	end

	if FXS[base] and #o == 1 then
		return insn(a, {op = {0x0f, 0xae}, reg = FXS[base],
			rm = o[1], size = 4, rexw = size == 8 or nil})
	end

	if RAND[base] and #o == 1 then
		return insn(a, {op = {0x0f, 0xc7}, reg = RAND[base],
			rm = o[1], size = size, rexw = rexw(),
			osize = osize()})
	end
	if m == "movntdqa" and #o == 2 then
		return insn(a, {op = {0x0f, 0x38, 0x2a}, reg = o[2],
			rm = o[1], size = 16, prefix = {0x66}})
	end

	if NTST[m] and #o == 2 then
		local d = NTST[m]

		return insn(a, {op = {0x0f, d[1]}, reg = o[1], rm = o[2],
			size = 16, prefix = d[2] and {d[2]} or nil})
	end

	if SHUF[m] and #o == 3 then
		local d = SHUF[m]

		return insn(a, {op = {0x0f, d[1]}, reg = o[3], rm = o[2],
			size = 16,
			prefix = d[2] and {0x66} or
				d[3] and {d[3]} or nil,
			imm = o[1].val, immrel = o[1].rel, immsize = 1})
	end

	if WIDEN[m] then
		local d = WIDEN[m]
		return insn(a, {op = d[1], reg = o[2], rm = o[1],
			size = d[2], rexw = d[3], osize = d[4],
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
	-- How wide an indirect branch's target is.  The register named
	-- says so; without one it is as wide as a call, which
	-- `.code16gcc` makes four.
	local function branchwidth(x)
		local w = (x.kind == "reg" and x.size) or stackwidth()

		return (w == 2 or w == 4) and w or nil
	end

	if base == "call" then
		if o[1].indirect then
			return insn(a, {op = {0xff}, reg = 2, rm = o[1],
				osize = branchwidth(o[1])})
		end
		return calldirect(a, size, o[1].sym)
	end
	if m == "jmp" or m == "jmpq" or m == "jmpl" or m == "jmpw" or
	   (m:sub(1, 1) == "j" and CC[m:sub(2)]) then
		if o[1].indirect then
			-- `jmpl *%eax` in 16-bit code asks for a wider
			-- target than the mode gives.
			return insn(a, {op = {0xff}, reg = 4, rm = o[1],
				osize = (m == "jmpl" and 4) or
					(m == "jmpw" and 2) or
					branchwidth(o[1])})
		end
		return jumpdirect(a, base ~= "jmp" and CC[m:sub(2)] or nil,
				  o[1].sym)
	end

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



	local widened = false

	if #ops == 0 and NOOP[base] and not size and a.bits == 16 and
	   a.stackop and WIDENS[base] then
		size, widened = a.stackop, true
	end
	if #ops == 0 and BARE[m] and not widened then
		for _, b in ipairs(BARE[m]) do byte(a, b) end
		return
	end
	if #ops == 0 and NOOP[base] then
		-- Long mode has no 32-bit flag or all-register form, and
		-- no all-register form at all.
		if a.bits == 64 and (base == "pusha" or base == "popa" or
		    ((base == "pushf" or base == "popf") and size == 4)) then
			error("no instruction " .. m)
		end
		if size == 2 or size == 4 then
			if (a.bits == 16) == (size == 4) then
				byte(a, 0x66)
			end
		end
		return byte(a, NOOP[base])
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

		-- With no letter after it the offset is as wide as the
		-- mode says: `ljmp $seg, $off` in .code16 is ptr16:16.
		if m == "ljmp" or m == "lcall" then
			w = (a.bits == 16) and 2 or 4
		end

		-- The prefix asks for the offset width the mode does not
		-- give by default.
		if (a.bits == 16) == (w == 4) then byte(a, 0x66) end
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



	if #ops >= 1 and SVM[base] then
		byte(a, 0x0f)
		byte(a, 0x01)
		byte(a, SVM[base])
		return
	end
	if #ops == 1 and VMX[base] then
		local v = VMX[base]

		return insn(a, {op = {0x0f, 0xc7}, reg = v[2], rm = o[1],
			size = 8, prefix = v[1] and {v[1]} or nil})
	end
	if #ops == 1 then
		if G7[base] then
			-- In 16-bit code `lgdtl` wants the prefix that asks
			-- for a four byte base; `lgdtw` does not.
			return insn(a, {op = {0x0f, 0x01}, reg = G7[base],
				rm = o[1], size = size or 8,
				osize = osize()})
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

		-- The prefix asks for the width the mode does not give,
		-- so `outw` needs none in 16-bit code.
		if (size == 2 or size == 4) and
		   ((a.bits == 16) == (size == 4)) then
			byte(a, 0x66)
		end
		if port.kind == "imm" then
			byte(a, (base == "in" and 0xe4 or 0xe6) +
				(wide and 1 or 0))
			return byte(a, port.val & 255)
		end
		return byte(a, (base == "in" and 0xec or 0xee) +
			(wide and 1 or 0))
	end


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
	if (base == "invept" or base == "invvpid") and #ops == 2 then
		return insn(a, {op = {0x0f, 0x38,
			base == "invept" and 0x80 or 0x81},
			reg = o[2], rm = o[1], size = 8, prefix = {0x66}})
	end
	-- Reading a VMCS field names the field in the reg operand and
	-- the place in the other; writing one is the other way round.
	if base == "vmread" and #ops == 2 then
		return insn(a, {op = {0x0f, 0x78}, reg = o[1], rm = o[2],
			size = 8})
	end
	if base == "vmwrite" and #ops == 2 then
		return insn(a, {op = {0x0f, 0x79}, reg = o[2], rm = o[1],
			size = 8})
	end

	-- exchange and add, and compare and exchange: the lock prefix a
	-- caller writes is its own instruction here
	if base == "xadd" and #ops == 2 then
		return insn(a, {op = {0x0f, size == 1 and 0xc0 or 0xc1},
			reg = o[1], rm = o[2], size = size,
			rexw = size == 8, osize = osize()})
	end
	if base == "cmpxchg" and #ops == 2 then
		return insn(a, {op = {0x0f, size == 1 and 0xb0 or 0xb1},
			reg = o[1], rm = o[2], size = size,
			rexw = size == 8, osize = osize()})
	end
	if base == "xchg" and #ops == 2 then
		return insn(a, {op = {size == 1 and 0x86 or 0x87},
			reg = o[1], rm = o[2], size = size,
			rexw = size == 8, osize = osize()})
	end
	-- increment and decrement, which are the unary group
	if (base == "inc" or base == "dec") and #ops == 1 then
		-- Outside long mode there is a one-byte form for a whole
		-- register, which is what long mode took for the REX
		-- prefixes.  Boot code counts its bytes, so use it.
		if a.bits ~= 64 and size ~= 1 and o[1].kind == "reg" and
		   o[1].num < 8 then
			return insn(a, {op = {(base == "inc" and 0x40
				or 0x48) + o[1].num}, reg = 0, rm = o[1],
				norm = true, osize = osize()})
		end
		return insn(a, {op = {size == 1 and 0xfe or 0xff},
			reg = base == "inc" and 0 or 1, rm = o[1],
			size = size, rexw = size == 8,
			osize = osize()})
	end
	if m == "syscall" then
		-- The call number is whatever was last put in eax, which
		-- is how every one of these is written.
		a:syscallsite(a.lasteax)
		byte(a, 0x0f)
		return byte(a, 0x05)
	end
	-- `ret $n` takes n bytes of arguments off on the way back, which
	-- is how a callee that was handed a record pointer drops it.
	if (base == "ret" or base == "lret") and #o == 1 and
	   o[1].kind == "imm" then
		local w = stackwidth()

		if base == "ret" then stackpfx(w) end
		byte(a, base == "ret" and 0xc2 or 0xca)
		return imm(a, o[1].val, 2)
	end
	if base == "enter" and #o == 2 then
		stackpfx(stackwidth())
		byte(a, 0xc8)
		imm(a, o[1].val, 2)
		return imm(a, o[2].val, 1)
	end
	if base == "leave" and #o == 0 then
		stackpfx(stackwidth())
		return byte(a, 0xc9)
	end
	if m == "ret" then return byte(a, 0xc3) end
	if m == "nop" then return byte(a, 0x90) end

	if ACC[m] then
		if (a.bits == 16) == (ACC[m][2] == 4) then byte(a, 0x66) end
		return byte(a, ACC[m][1])
	end
	if m == "cqto" then
		byte(a, 0x48)
		return byte(a, 0x99)
	end
	if m == "cltq" then
		byte(a, 0x48)
		return byte(a, 0x98)
	end
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

-- Intel syntax, as `.intel_syntax` asks for: each instruction is written
-- again the AT&T way and read as that.  The operands come in the other
-- order, a register has no %, a place is `[base + index*scale + disp]`
-- and says its width with `X ptr`, a bare number is an immediate, and a
-- bare name is the place it names unless `offset` asks for its address.
local PTRSIZE = {byte = 1, word = 2, dword = 4, qword = 8, tbyte = 10,
		 fword = 6, xmmword = 16, ymmword = 32, zmmword = 64,
		 oword = 16}
local SUFFIX = {[1] = "b", [2] = "w", [4] = "l", [8] = "q"}
-- The ones gas spells one way in each syntax.
local INTELNAME = {cdqe = "cltq", cwde = "cwtl", cbw = "cbtw", cwd = "cwtd",
		   cdq = "cltd", cqo = "cqto", movsxd = "movslq"}
-- The x87 ones take the width of a place into their name.
local X87 = {fld = {[4] = "flds", [8] = "fldl", [10] = "fldt"},
	     fst = {[4] = "fsts", [8] = "fstl"},
	     fstp = {[4] = "fstps", [8] = "fstpl", [10] = "fstpt"},
	     fild = {[2] = "filds", [4] = "fildl", [8] = "fildll"},
	     fistp = {[2] = "fistps", [4] = "fistpl", [8] = "fistpll"},
	     fisttp = {[2] = "fisttps", [4] = "fisttpl", [8] = "fisttpll"}}

local function intelreg(w)
	w = w:lower():gsub("^%%", "")
	if REG[w] or XMM[w] or YMM[w] or ZMM[w] or KREG[w] or SEG[w] or
	   w == "rip" or w == "eip" or w:match("^[cd]r%d+$") or
	   w:match("^mm%d$") or w == "st" or w:match("^st%(%d%)$") then
		return w
	end
	return nil
end

-- Cut at the commas that are not inside brackets or parentheses.
local function intelsplit(rest)
	local out, depth, cur = {}, 0, {}

	for c in rest:gmatch(".") do
		if c == "[" or c == "(" then depth = depth + 1
		elseif c == "]" or c == ")" then depth = depth - 1 end
		if c == "," and depth == 0 then
			out[#out + 1] = table.concat(cur):match("^%s*(.-)%s*$")
			cur = {}
		else
			cur[#cur + 1] = c
		end
	end
	local last = table.concat(cur):match("^%s*(.-)%s*$")

	if last ~= "" or #out > 0 then out[#out + 1] = last end
	return out
end

-- `[base + index*scale + disp]`, with whatever stood in front of the
-- bracket added to the displacement.
local function intelmem(inside, before, seg)
	local base, index, scale
	local disp = {}

	if before and before ~= "" then disp[1] = before end
	inside = inside:gsub("%s+", "")
	for sign, term in inside:gmatch("([+-]?)([^+-]+)") do
		local r = intelreg(term)
		local a, b = term:match("^(.-)%*(.-)$")

		if a and (intelreg(a) or intelreg(b)) then
			index = intelreg(a) or intelreg(b)
			scale = intelreg(a) and b or a
		elseif r and not base and sign ~= "-" then
			base = r
		elseif r then
			index, scale = r, "1"
		else
			disp[#disp + 1] = (sign == "-" and "-" or
				(#disp > 0 and "+" or "")) .. term
		end
	end
	local d = table.concat(disp)

	if d:sub(1, 1) == "+" then d = d:sub(2) end
	local s = (seg and ("%" .. seg .. ":") or "") .. d

	if base or index then
		s = s .. "(" .. (base and "%" .. base or "") ..
			(index and ("," .. "%" .. index ..
			 (scale and scale ~= "1" and "," .. scale or "")) or "")
			.. ")"
	end
	return s
end

function amd64.intel(a, word, rest)
	word = word:lower()
	-- A prefix on the line stands in front of the instruction it
	-- prefixes, which is translated on its own.
	if PREFIX[word] and rest ~= "" then
		local w, r = rest:match("^(%S+)%s*(.*)$")
		local w2, r2 = amd64.intel(a, w, r)

		return word, w2 .. (r2 ~= "" and " " .. r2 or "")
	end
	local branch = word:match("^j") or word == "call" or
		word:match("^loop") or word == "xbegin"
	local ops = intelsplit(rest)
	local out, size, anyreg = {}, nil, false

	for i, op in ipairs(ops) do
		local o = op
		local w, rest2 = o:match("^(%a+)%s+[Pp][Tt][Rr]%s+(.*)$")

		if w and PTRSIZE[w:lower()] then
			size, o = PTRSIZE[w:lower()], rest2
		end
		local seg, after = o:match("^(%a%a):%s*(.*)$")

		if seg and SEG[seg:lower()] then o = after else seg = nil end
		local before, inside = o:match("^(.-)%[(.*)%]$")
		local t

		if inside then
			t = intelmem(inside, before, seg and seg:lower())
			if branch then t = "*" .. t end
		elseif intelreg(o) then
			t = "%" .. intelreg(o)
			anyreg = true
			if branch then t = "*" .. t end
		elseif o:lower():match("^offset%s") then
			t = "$" .. o:match("^%a+%s+(.*)$")
		elseif branch or o:match("^[-+~(]*%d") then
			-- a number is a value; a branch's operand is
			-- where it goes
			t = branch and o or "$" .. o
		else
			-- a bare name is the place it names
			t = (seg and ("%" .. seg:lower() .. ":") or "") .. o
			if branch then t = "*" .. t end
		end
		out[i] = t
	end
	-- `enter` keeps its order in both syntaxes.
	if word ~= "enter" then
		local rev = {}

		for i = #out, 1, -1 do rev[#rev + 1] = out[i] end
		out = rev
	end
	if INTELNAME[word] then word = INTELNAME[word] end
	if (word == "movzx" or word == "movsx") and size and #out == 2 then
		-- the source width goes into the name, and the
		-- destination's with it
		local dst = out[2]:gsub("^%%", "")
		local dw = REG[dst] and REG[dst].size

		word = (word == "movzx" and "movz" or "movs") ..
			(SUFFIX[size] or "") .. (SUFFIX[dw] or "")
	elseif X87[word] and size then
		word = X87[word][size] or word
	elseif size and not anyreg and SUFFIX[size] and not branch and
	       not word:match("^v") then
		word = word .. SUFFIX[size]
	end
	return word, table.concat(out, ",")
end

-- `#` starts a comment on this machine, anywhere on the line.
amd64.hash = true

return amd64
