-- Expression trees, target neutral.
--
-- A node is a plain table: op, ty, left, right, plus whatever the op needs
-- (val, sym, off).  `need` is the Sethi-Ullman register count, computed
-- here so the matcher can ask how hard a subtree is without walking it.

local tree = {}

-- Leaves are lvalues or constants; reading one is implicit in how an
-- instruction addresses it, as it was in the 1972 compiler.
tree.ops = {
	CONST = {arity = 0},
	NAME  = {arity = 0},		-- a global, addressed by symbol
	AUTO  = {arity = 0},		-- a local, addressed by frame offset
	INDIR = {arity = 1},
	ADDR  = {arity = 1},
	-- Assembly already written, spliced in where this node is reached.
	-- It came from a statement and so wants the whole machine, which
	-- is what a call wants too.
	TEXT  = {arity = 0},
	-- position independent code reaches a symbol it does not own
	-- through a table the loader fills in
	GOT   = {arity = 1},
	-- GNU alloca: the block comes off the stack and the frame pointer
	-- puts it back, so nothing frees it.
	ALLOCA = {arity = 1},
	NEG   = {arity = 1},
	NOT   = {arity = 1},
	ADD   = {arity = 2, commutes = true},
	SUB   = {arity = 2},
	MUL   = {arity = 2, commutes = true},
	AND   = {arity = 2, commutes = true},
	OR    = {arity = 2, commutes = true},
	XOR   = {arity = 2, commutes = true},
	SHL   = {arity = 2},
	SHR   = {arity = 2},
	DIV   = {arity = 2},
	MOD   = {arity = 2},
	LNOT  = {arity = 1},
	ANDAND = {arity = 2},
	OROR  = {arity = 2},
	CALL  = {arity = 1},		-- left is the callee, args is a list
	POSTADD = {arity = 1},		-- yields the old value, then steps
	CVT   = {arity = 1},		-- widen or narrow
	COPY  = {arity = 2},		-- left and right are addresses, val is a size
	COND  = {arity = 1},		-- left is the test, arms are the values
	SEQ   = {arity = 0},		-- arms, generated in order
	ASGN  = {arity = 2},
	ASM   = {arity = 0},		-- a literal template and its operands
	INREG = {arity = 0},		-- a value already in register regno
	EQ    = {arity = 2, commutes = true, rel = "EQ"},
	NE    = {arity = 2, commutes = true, rel = "NE"},
	LT    = {arity = 2, commutes = true, rel = "GT"},
	LE    = {arity = 2, commutes = true, rel = "GE"},
	GT    = {arity = 2, commutes = true, rel = "LT"},
	GE    = {arity = 2, commutes = true, rel = "LE"},
}

-- Does evaluating this tree change anything?  A compound assignment asks,
-- because it reads its left side and writes it back, and may only evaluate
-- the address once.
local EFFECT = {CALL = true, ASGN = true, POSTADD = true, ALLOCA = true}

function tree.effects(n)
	if not n then return false end
	if EFFECT[n.op] then return true end
	if n.arms then
		for _, a in ipairs(n.arms) do
			if tree.effects(a) then return true end
		end
	end
	if n.args then
		for _, a in ipairs(n.args) do
			if tree.effects(a) then return true end
		end
	end
	return tree.effects(n.left) or tree.effects(n.right)
end

-- Types live in their own module; a tree only needs to ask.
local types = require "types"

function tree.types(target)
	return types.new(target)
end

local function need(n)
	local d = tree.ops[n.op]
	if n.op == "CALL" or n.op == "TEXT" then
		return 1000		-- a call wants the whole machine
	end
	if n.op == "COPY" then
		return 2
	end
	if n.op == "POSTADD" then
		return 3		-- value, address, and a scratch
	end
	if n.op == "COND" then
		local a = math.max(n.arms[1].need, n.arms[2].need)
		return math.max(a, n.left.need)
	end
	if n.op == "SEQ" then
		local m = 0
		for _, a in ipairs(n.arms) do
			if a.need > m then m = a.need end
		end
		return m
	end
	if d.arity == 0 then
		return 0
	end
	if d.arity == 1 then
		return n.left.need == 0 and 1 or n.left.need
	end
	if n.left.need == n.right.need then
		return n.left.need + 1
	end
	return math.max(n.left.need, n.right.need)
end

-- Put the harder operand on the left, so it is evaluated first and holds
-- the lower register.  Relationals swap their sense when flipped.
local function commute(n)
	local d = tree.ops[n.op]
	if not d.commutes or n.right.need <= n.left.need then
		return n
	end
	n.left, n.right = n.right, n.left
	if d.rel then
		n.op = d.rel
	end
	return n
end

-- The arena.  Nodes are reused between statements rather than left to the
-- collector, so a long function costs no more than its widest expression.
local pool, used, peak = {}, 0, 0

function tree.reset()
	used = 0
end

-- A statement marks the arena on the way in and releases it on the way out,
-- so nesting works and a tree built before a block survives it.
function tree.mark()
	return used
end

function tree.release(m)
	used = m
end

function tree.arena()
	return used, peak, #pool
end

local function take()
	used = used + 1
	if used > peak then peak = used end
	local n = pool[used]
	if not n then
		n = {}
		pool[used] = n
	else
		for k in pairs(n) do n[k] = nil end
	end
	return n
end

-- A copy in the arena, for when a node has to be retyped without disturbing
-- the one it was built from.
function tree.clone(n)
	local c = take()
	for k, v in pairs(n) do c[k] = v end
	return c
end

function tree.node(op, ty, left, right, extra)
	local n = take()
	if extra then
		for k, v in pairs(extra) do n[k] = v end
	end
	n.op, n.ty, n.left, n.right = op, ty, left, right
	assert(tree.ops[op], "unknown op " .. tostring(op))
	if tree.ops[op].arity == 2 then
		commute(n)
	end
	n.need = need(n)
	return n
end

function tree.const(ty, v)  return tree.node("CONST", ty, nil, nil, {val = v}) end
function tree.name(ty, s)   return tree.node("NAME",  ty, nil, nil, {sym = s}) end
function tree.auto(ty, off) return tree.node("AUTO",  ty, nil, nil, {off = off}) end

function tree.unary(op, ty, a)     return tree.node(op, ty, a) end
function tree.binary(op, ty, a, b) return tree.node(op, ty, a, b) end

-- Difficulty class, the 1972 dcalc.  The matcher compares it against each
-- alternative's ceiling, so a cheap operand can use a cheap instruction form.
function tree.dcalc(n, nreg)
	if not n then return 0 end
	local op = n.op
	if op == "CALL" then return 24 end
	if op == "CONST" then
		return n.val == 0 and 4 or 8
	elseif op == "NAME" or op == "AUTO" or op == "ADDR" then
		return 12
	elseif op == "GOT" then
		return n.need <= nreg and 20 or 24
	elseif op == "INDIR" then
		if tree.dcalc(n.left, nreg) < 16 then
			return 16
		end
	end
	return n.need <= nreg and 20 or 24
end

function tree.dump(n, ind)
	ind = ind or ""
	if not n then return end
	local extra = ""
	if n.val then extra = " " .. n.val end
	if n.sym then extra = " " .. n.sym end
	if n.off then extra = " " .. n.off end
	print(string.format("%s%s:%s%s (need %d)", ind, n.op, n.ty.name, extra,
		n.need))
	tree.dump(n.left, ind .. "  ")
	tree.dump(n.right, ind .. "  ")
end

return tree
