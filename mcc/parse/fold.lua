-- SPDX-License-Identifier: ISC
-- Constant folding, and the small tests on types that go with it.  Every
-- part of the parser uses these, so they live apart from all of them.

local tree = require "mcc.tree"

local function bitcount(op, v, w)
	local bits = w * 8

	if w < 8 then v = v & ((1 << bits) - 1) end
	if op:sub(1, 3) == "ffs" then
		if v == 0 then return 0 end
		local n = 1

		while v & 1 == 0 do v, n = v >> 1, n + 1 end
		return n
	end
	if op:sub(1, 3) == "clz" then
		-- what gcc leaves undefined for zero: the whole width
		local n = 0

		while n < bits and (v >> (bits - 1 - n)) & 1 == 0 do
			n = n + 1
		end
		return n
	end
	if op:sub(1, 3) == "ctz" then
		if v == 0 then return bits end
		local n = 0

		while v & 1 == 0 do v, n = v >> 1, n + 1 end
		return n
	end
	local n = 0

	for _ = 1, bits do
		n = n + (v & 1)
		v = v >> 1
	end
	if op:sub(1, 6) == "parity" then return n & 1 end
	return n
end

-- Constant arithmetic.  Lua's integers are 64 bits, which is exactly the
-- width this has to answer for.
-- Forward: constant folding is defined with the expression parser, and
-- the type rules above it ask whether something is a constant zero.
local fold
-- The same, before the answer is cut down to the type it was worked
-- out in.  `fold` wraps this one.
local foldn

-- A value is only as wide as its type says.  Lua works in 64 bits, so
-- `~0U` comes out as -1 and `~0U >> 1` as every bit but the top one,
-- where C answers 0x7fffffff.  A cast narrows the same way.
local function narrow(v, ty)
	if v == nil or ty == nil then return v end
	local sz = ty.size
	local uns = ty.kind == "uint" or ty.kind == "ptr"

	if not (uns or ty.kind == "int") then return v end
	if not sz or sz <= 0 or sz >= 8 then return v end
	local bits = sz * 8

	v = v & ((1 << bits) - 1)
	if not uns and v & (1 << (bits - 1)) ~= 0 then
		v = v - (1 << bits)
	end
	return v
end

-- The same by another name, for the places where `narrow` is the name
-- of a parameter.
local cutto = narrow

-- A read of a slot may be retyped where it stands, so a value put in
-- its place takes the type of the read.  Without this `t != 4294967295u`
-- with `int t` folds as a signed compare and answers the wrong way.
local function retyped(a, ty)
	local ak = a.ty and a.ty.kind

	if a.ty == ty or ty == nil then return a end
	if not (ak == "int" or ak == "uint") then return a end
	if not (ty.kind == "int" or ty.kind == "uint") then return a end
	if a.op == "CONST" then return tree.const(ty, narrow(a.val, ty)) end
	return tree.unary("CVT", ty, a)
end

-- What a test settles to, which is more than `fold` answers: an
-- operand may decide on its own.  Defined with the statements.
local settle
-- Forward: a pointer into a named object, as a symbol and a byte offset.
local symoff

local function foldbin(o, a, b, uns)
	local lt = uns and math.ult or function(x, y) return x < y end
	if o == "ADD" then return a + b end
	if o == "SUB" then return a - b end
	if o == "MUL" then return a * b end
	if o == "AND" then return a & b end
	if o == "OR"  then return a | b end
	if o == "XOR" then return a ~ b end
	if o == "SHL" then return a << b end
	if o == "EQ"  then return a == b and 1 or 0 end
	if o == "NE"  then return a ~= b and 1 or 0 end
	if o == "LT"  then return lt(a, b) and 1 or 0 end
	if o == "LE"  then return not lt(b, a) and 1 or 0 end
	if o == "GT"  then return lt(b, a) and 1 or 0 end
	if o == "GE"  then return not lt(a, b) and 1 or 0 end
	-- Lua's >> is logical, and its // is a floor divide, which is what
	-- an arithmetic shift right means.
	if o == "SHR" then
		if uns then return a >> b end
		return b >= 64 and (a < 0 and -1 or 0) or a // (1 << b)
	end
	if b == 0 then return 0 end
	-- Lua has no unsigned divide, and a value past the sign bit is
	-- exactly what a limit like UINT64_MAX is.
	if uns then
		if o ~= "DIV" and o ~= "MOD" then return nil end
		local q

		if b < 0 then
			q = math.ult(a, b) and 0 or 1
		elseif a >= 0 then
			q = a // b
		else
			-- halve, divide, double, then fix the remainder
			q = ((a >> 1) // b) << 1
			if not math.ult(a - q * b, b) then q = q + 1 end
		end
		if o == "DIV" then return q end
		return a - q * b
	end
	if o == "DIV" then
		local q = a // b
		-- C truncates towards zero where Lua floors
		if q < 0 and q * b ~= a then q = q + 1 end
		return q
	end
	if o == "MOD" then return a - foldbin("DIV", a, b, uns) * b end
	return nil
end

local function isptr(t) return t.kind == "ptr" end
local function isrec(t) return t.kind == "struct" or t.kind == "union" end
local function isflt(t) return t.kind == "float" end

-- Which bits a value may have set, when that is written down: a mask
-- says so, a body that answers one carries it, and widening keeps
-- it.  Answers nil when anything else could be in there.
local function bitsof(n, depth)
	if n == nil or (depth or 0) > 8 then return nil end
	if n.mask then return n.mask end
	if n.op == "CVT" and n.left and n.ty and n.left.ty and
	   not isflt(n.ty) and not isflt(n.left.ty) then
		local m = bitsof(n.left, (depth or 0) + 1)
		-- A narrower type keeps the low bits, so the mask still
		-- holds as long as it fits in what is left.
		local bits = 8 * n.ty.size -
			(n.ty.kind == "int" and 1 or 0)

		if m == nil then return nil end
		if bits >= 63 or m < (1 << bits) then return m end
		return nil
	end
	if n.op ~= "AND" then return nil end
	local m = fold(n.right) or fold(n.left)

	if m == nil or m < 0 then return nil end
	return m
end

-- Whether a tree reads a given slot.
local function mentions(n, off, depth)
	if n == nil or (depth or 0) > 24 then return false end
	if n.op == "AUTO" and n.off == off then return true end
	if mentions(n.left, off, (depth or 0) + 1) then return true end
	if mentions(n.right, off, (depth or 0) + 1) then return true end
	if n.arms then
		for _, a in ipairs(n.arms) do
			if mentions(a, off, (depth or 0) + 1) then
				return true
			end
		end
	end
	return false
end

-- A float constant travels as its bit pattern, so integer arithmetic on
-- one gives a wrong answer.  Float folding belongs to floatop, which has
-- already run by the time anything asks here.
local function fltn(n) return n ~= nil and n.ty ~= nil and isflt(n.ty) end

-- A pointer to a fixed place in a named object, as a symbol and a byte
-- offset.  Two of these into the same object subtract to a constant,
-- which is what an assertion in a header asks for.
function symoff(n)
	if not n then return nil end
	if n.op == "CVT" then return symoff(n.left) end
	if n.op == "ADDR" then
		if n.left.op == "NAME" then
			return n.left.sym, n.left.off or 0
		end
		if n.left.op == "INDIR" then return symoff(n.left.left) end
		return nil
	end
	if n.op == "ADD" or n.op == "SUB" then
		local sym, off = symoff(n.left)
		local k = off and fold(n.right)

		if not k then return nil end
		return sym, n.op == "ADD" and off + k or off - k
	end
	return nil
end

function fold(n)
	if not n then return nil end
	return narrow(foldn(n), n.ty)
end

function foldn(n)
	if n.op == "CONST" then return n.val end
	if n.op == "SUB" then
		local sa, oa = symoff(n.left)
		local sb, ob = symoff(n.right)

		if sa and sa == sb then return oa - ob end
	end
	if n.op == "NEG" then
		if fltn(n.left) then return nil end
		local a = fold(n.left)
		return a and -a
	end
	if n.op == "NOT" then
		local a = fold(n.left)
		return a and ~a
	end
	if n.op == "LNOT" then
		if fltn(n.left) then return nil end
		local a = fold(n.left)
		return a and (a == 0 and 1 or 0)
	end
	if n.op == "CVT" then
		if fltn(n) ~= fltn(n.left) then return nil end
		return fold(n.left)
	end
	-- `a ? b : c` is a constant expression when all three are, which is
	-- how a C library writes a table of bits.
	if n.op == "COND" then
		local c = fold(n.left)

		if not c then return nil end
		return fold(n.arms[c ~= 0 and 1 or 2])
	end
	if n.op == "ANDAND" or n.op == "OROR" then
		local x = fold(n.left)

		if not x then return nil end
		if n.op == "ANDAND" and x == 0 then return 0 end
		if n.op == "OROR" and x ~= 0 then return 1 end
		local y = fold(n.right)

		return y and (y ~= 0 and 1 or 0)
	end
	if fltn(n.left) or fltn(n.right) then return nil end
	local a, b = fold(n.left), fold(n.right)
	if not a or not b then return nil end
	-- A comparison answers an int, so its own type says nothing about
	-- how the two sides are read.  The operands carry that.
	local ct = n.ty

	if tree.ops[n.op] and tree.ops[n.op].rel then ct = n.left.ty end
	return foldbin(n.op, a, b, ct and
		(ct.kind == "uint" or ct.kind == "ptr"))
end

-- Every value of `at` reaches `rt` unchanged.
local function reaches(at, rt)
	if at.size < rt.size then
		return rt.kind == "int" or at.kind == "uint"
	end
	return at.size == rt.size and at.kind == rt.kind
end

-- What a test settles to.  `x && 0` is false however `x` turns out,
-- and `x || 1` is true: the operand still runs, and gen:cond writes
-- it, but the arm behind the test is out of reach.
local function settlen(n)
	if n.op == "ANDAND" or n.op == "OROR" then
		local a, b = settle(n.left), settle(n.right)
		-- The value that decides on its own: a nought for `&&`,
		-- anything else for `||`.
		local sc = n.op == "OROR"

		if (a ~= nil and (a ~= 0) == sc) or
		   (b ~= nil and (b ~= 0) == sc) then
			return sc and 1 or 0
		end
		if a and b then return sc and 0 or 1 end
		return nil
	end
	if n.op == "LNOT" then
		local a = settle(n.left)

		return a and (a == 0 and 1 or 0)
	end
	-- The address of a string is never nought, so a string as a
	-- truth value settles to one.  A kernel writes
	-- `(name) ? sizeof(name) - 1 : 0` in a static initialiser and
	-- hands it a literal.
	do
		local a = n

		while a and (a.op == "CVT" or a.op == "ADDR") do
			a = a.left
		end
		if a and a.op == "NAME" and a.sym and
		   a.sym:sub(1, 5) == ".Lstr" then
			return 1
		end
	end
	if n.op == "CVT" and n.left and
	   isflt(n.ty) == isflt(n.left.ty) then
		return settle(n.left)
	end
	-- An operand that decides on its own, whatever the other one
	-- turns out to be.  The kernel writes `x &= IS_ENABLED(...)`.
	if n.op == "AND" or n.op == "MUL" then
		local a, b = settle(n.left), settle(n.right)

		if a == 0 or b == 0 then return 0 end
		if a and b then return foldbin(n.op, a, b,
			n.ty and n.ty.kind == "uint") end
		return nil
	end
	if n.op == "EQ" or n.op == "NE" then
		local a, b = settle(n.left), settle(n.right)

		if a and b then
			return (a == b) == (n.op == "EQ") and 1 or 0
		end
		-- A value behind a mask cannot hold a bit the mask
		-- clears.  The kernel asks `zonenum(f) == ZONE_DEVICE`
		-- with the zone field three bits wide and ZONE_DEVICE
		-- past the end of it, which is how a configuration
		-- switches a whole family of pages off.
		local k, m = a or b, bitsof(a and n.right or n.left)

		if k and m and k & ~m ~= 0 then
			return n.op == "EQ" and 0 or 1
		end
		return nil
	end
	return fold(n)
end

-- A value is only as wide as its type says, here as much as in `fold`:
-- a conversion that settles narrows to what it converts to.
function settle(n)
	if n == nil then return nil end
	return narrow(settlen(n), n.ty)
end

return {
	bitcount = bitcount,
	narrow = narrow,
	cutto = cutto,
	retyped = retyped,
	foldbin = foldbin,
	isptr = isptr,
	isrec = isrec,
	isflt = isflt,
	bitsof = bitsof,
	mentions = mentions,
	fltn = fltn,
	symoff = symoff,
	fold = fold,
	foldn = foldn,
	reaches = reaches,
	settlen = settlen,
	settle = settle,
}
