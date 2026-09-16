-- Machine description: the table format and its compiler.
--
-- A target supplies, per context and per operator, a list of alternatives.
-- The matcher takes the first alternative whose operand shapes the tree can
-- satisfy.  This module turns the readable form into something the matcher
-- and the emitter walk without reparsing.
--
-- Operand shape:  <class>[<size>][*]
--   class  z 4   the constant zero      size  b 1   byte
--          c 8   any constant                 w 2   word
--          i 12  a name or address            l 4   long
--          a 16  addressable, no register     q 8   quad
--          e 20  fits the registers left      p     pointer
--          n 63  anything
--   p            a pointer; a size letter beside it names the pointee,
--                so "nbp" is any pointer to a byte
--   s u          signed or unsigned, where the instruction differs
--   *            the node must be an indirection
--
-- Evaluation list `ev`, space separated, run before the template:
--   L R T      left, right, this node, into the current register
--   L1 R1      into the next register
--   L* R*      an indirection's pointer instead of its value
--   Ls Rs      onto the stack
--   Lc Rc      into the condition codes
--
-- Template `asm`, where % is an escape only before these:
--   %A %A1 %A2   address text of this node, left, right
--   %R %R1       register name, sized for the node's type, or for an
--                operand's when the alternative sets rz = 1 or 2
--   %P %P1       the same register at pointer size, for addressing
--   %W %W1       the same register at 32 bits, for extension
--   %C1 %C2      an operand's literal number: its value or its frame offset
--   %N1 %N2      the same, negated
--   %z %z1 %z2   size suffix
--   %I           mnemonic for this operator, from target.mnem(node, alt)
--   %L0 %L1      fresh labels, stable within one expansion
--   %%           a literal percent
-- Anything else after % is literal, so AT&T register names pass through.
--
-- An alternative may also carry:
--   rz = 1 | 2   size %R from that operand instead of from the node
--   imm = true   a flag the target's mnem can read, for addi against add
--   clob = {i}   allocation-order registers the template destroys.  Any of
--                them still holding a value, meaning an index below the
--                current register, is saved and restored around it.

local md = {}

local CLASS = {z = 4, c = 8, i = 12, a = 16, e = 20, n = 63}
local SIZE  = {b = 1, w = 2, l = 4, q = 8}

function md.shape(s)
	local sh = {max = CLASS[s:sub(1, 1)]}
	if not sh.max then
		error("bad operand class in shape '" .. s .. "'")
	end
	for i = 2, #s do
		local c = s:sub(i, i)
		if c == "*" then
			sh.deref = true
		elseif SIZE[c] then
			sh.size = SIZE[c]
		elseif c == "p" then
			sh.kind = "ptr"
		elseif c == "s" then
			sh.kind = "int"
		elseif c == "u" then
			sh.kind = "uint"
		else
			error("bad shape letter '" .. c .. "' in '" .. s .. "'")
		end
	end
	return sh
end

local SEL = {L = "left", R = "right", T = "this"}
local CTX = {s = "stack", c = "cc", e = "eff"}

function md.ev(s)
	local list = {}
	for tok in (s or ""):gmatch("%S+") do
		local sel = SEL[tok:sub(1, 1)]
		if not sel then
			error("bad ev selector in '" .. tok .. "'")
		end
		local step = {sel = sel, ctx = "reg", bump = 0}
		for i = 2, #tok do
			local c = tok:sub(i, i)
			if c == "1" then
				step.bump = 1
			elseif c == "*" then
				step.deref = true
			elseif CTX[c] then
				step.ctx = CTX[c]
			else
				error("bad ev flag '" .. c .. "' in '" .. tok .. "'")
			end
		end
		list[#list + 1] = step
	end
	return list
end

local ESC = {A = true, R = true, P = true, W = true, C = true,
	     N = true, z = true, I = true, L = true}

function md.template(s)
	local out, lit, i = {}, {}, 1
	local function flush()
		if #lit > 0 then
			out[#out + 1] = {lit = table.concat(lit)}
			lit = {}
		end
	end
	while i <= #s do
		local c = s:sub(i, i)
		if c ~= "%" then
			lit[#lit + 1] = c
			i = i + 1
		elseif s:sub(i + 1, i + 1) == "%" then
			lit[#lit + 1] = "%"
			i = i + 2
		else
			local k = s:sub(i + 1, i + 1)
			if not ESC[k] then
				lit[#lit + 1] = c
				i = i + 1
			else
				local d = s:sub(i + 2, i + 2)
				local arg = tonumber(d)
				flush()
				out[#out + 1] = {esc = k, arg = arg}
				i = i + (arg and 3 or 2)
			end
		end
	end
	flush()
	return out
end

-- The parsed forms of `ev` and `asm`, built on first use and kept.  A whole
-- target parsed up front costs more than the table itself; most files reach
-- only a few alternatives.
function md.steps(a)
	local s = a.steps
	if not s then
		s = md.ev(a.ev)
		a.steps = s
	end
	return s
end

function md.parts(a)
	local p = a.parts
	if not p then
		p = md.template(a.asm or "")
		a.parts = p
	end
	return p
end

-- Compile one target description.  Every alternative is checked here, so a
-- malformed table fails at load rather than at the first tree that hits it.
-- The checked forms of ev and asm are dropped; md.steps and md.parts rebuild
-- them when a tree actually reaches the alternative.
function md.target(spec)
	assert(spec.name and spec.ptrsize and spec.nreg, "target lacks name/ptrsize/nreg")
	assert(spec.regname and spec.addr and spec.suffix, "target lacks regname/addr/suffix")
	for ctx, ops in pairs(spec.code) do
		for op, alts in pairs(ops) do
			for i, a in ipairs(alts) do
				local where = spec.name .. "." .. ctx .. "." .. op .. "[" .. i .. "]"
				local ok, err = pcall(function()
					a.s1 = md.shape(a[1])
					a.s2 = a[2] and md.shape(a[2]) or nil
					md.ev(a.ev)
					if type(a.asm) ~= "function" then
						md.template(a.asm or "")
					end
					if a.clob then
						assert(spec.save and spec.restore,
						 "target lacks save/restore")
					end
				end)
				if not ok then
					error(where .. ": " .. tostring(err), 0)
				end
			end
		end
	end
	return spec
end

-- Argument classification, shared by the parser's parameter placement and
-- the target's call.  Each item says whether it is floating point and how
-- wide it is; the answer says where it goes.  Three target facts decide it:
--
--   nfltreg   how many floating point argument registers there are, zero on
--             a target whose ABI carries a double in an ordinary register
--   vafloat   whether a variadic argument may use one of them
--   fltspill  whether a float that finds the float file full falls back to
--             the integer file rather than to the stack
--
-- nfixed is the number of named parameters when the callee is variadic, and
-- nil otherwise.
function md.classify(t, items, nfixed)
	local nflt = t.nfltreg or 0
	local out, gp, fp, stk = {}, 0, 0, 0
	for i, it in ipairs(items) do
		local named = not nfixed or i <= nfixed
		local flt = it.flt and nflt > 0 and (named or t.vafloat)
		local d = {flt = flt, size = it.size}
		if flt and fp < nflt then
			d.reg, fp = fp, fp + 1
		elseif not flt and gp < t.nargreg then
			d.reg, gp = gp, gp + 1
		elseif it.flt and t.fltspill and gp < t.nargreg then
			d.reg, gp, d.flt = gp, gp + 1, false
		else
			d.stk, stk = stk, stk + 1
		end
		out[i] = d
	end
	return out, gp, fp, stk
end

return md
