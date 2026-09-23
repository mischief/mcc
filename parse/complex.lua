-- SPDX-License-Identifier: ISC
-- Complex numbers: the two halves, and the arithmetic the library
-- does for them.

local tree = require "tree"
local P = require "parse.base"
local cf = require "parse.fold"
local isflt = cf.isflt

-- _Complex, as a pair the target already knows how to carry: the type
-- is a record of two members, so a value of one lives in a frame slot
-- and its halves are the two slots inside it.
--
-- `cplxparts` answers the real half, the imaginary half, and the code
-- that has to run before either is read.  A real value has an
-- imaginary half of zero and needs no slot of its own.
function P:cplxparts(e, elem, pre)
	local half = elem.size

	if not e.ty.complex then
		return self:conv(self:rvalue(e), elem),
			self:fconst(0.0, elem)
	end
	local src = e

	if src.op ~= "AUTO" then
		local off = self:alloc(src.ty)

		pre[#pre + 1] = self:assignto(tree.auto(src.ty, off), src)
		src = tree.auto(src.ty, off)
	end
	local se = src.ty.complex
	local re = self:conv(tree.auto(se, src.off), elem)
	local im = self:conv(tree.auto(se, src.off + se.size), elem)

	if se == elem then return re, im end
	-- A conversion between element types needs somewhere to put the
	-- answer, because each half is read twice by the code that uses
	-- it and a conversion is not free.
	local off = self:alloc(self.ty.complex(elem))

	pre[#pre + 1] = self:assignto(tree.auto(elem, off), re)
	pre[#pre + 1] = self:assignto(tree.auto(elem, off + half), im)
	return tree.auto(elem, off), tree.auto(elem, off + half)
end

-- A complex value built out of its two halves, in a slot of its own.
function P:cplxmake(elem, re, im, pre)
	local cty = self.ty.complex(elem)
	local off = self:alloc(cty)

	pre[#pre + 1] = self:assignto(tree.auto(elem, off), re)
	pre[#pre + 1] = self:assignto(tree.auto(elem, off + elem.size), im)
	pre[#pre + 1] = tree.auto(cty, off)
	return tree.node("SEQ", cty, nil, nil, {arms = pre})
end

-- Which element type two operands of an arithmetic operation share.
function P:cplxelem(a, b)
	local ea = a.ty.complex or a.ty
	local eb = b and (b.ty.complex or b.ty) or ea

	if not isflt(ea) then ea = self.ty.f64 end
	if not isflt(eb) then eb = self.ty.f64 end
	return self:usual(ea, eb)
end

-- The multiply and the divide go to the runtime, under the names every
-- other compiler gives them, because the divide needs a test to keep
-- its range and this compiler builds no branches inside an expression.
-- The float and double helpers wear the names every compiler on the
-- platform gives them, because their pair travels the same way in
-- both.  The extended ones do not: the ABI returns that pair on the
-- x87 stack and this compiler hands over a pointer, so they are named
-- apart rather than made to look interchangeable.
local CPLXFN = {MUL = {[4] = "__mulsc3", [8] = "__muldc3",
		       [16] = "__mcc_mulxc3"},
		DIV = {[4] = "__divsc3", [8] = "__divdc3",
		       [16] = "__mcc_divxc3"}}

function P:cplxcall(name, cty, args)
	local wide, wflt = self:widenargs(args)
	local n = tree.node("CALL", cty,
		tree.name(self.ty.func(cty, {}, true), name), nil,
		{args = args, direct = true, wide = wide, wflt = wflt})

	n.retrec = cty
	n.retslot = self:temp(cty)
	return tree.node("SEQ", cty, nil, nil,
		{arms = {n, tree.auto(cty, n.retslot)}})
end

function P:cplxarith(op, a, b)
	local elem = self:cplxelem(a, b)
	local pre = {}
	local ar, ai = self:cplxparts(a, elem, pre)

	if op == "NEG" then
		return self:cplxmake(elem, self:arith("SUB",
			self:fconst(0.0, elem), ar),
			self:arith("SUB", self:fconst(0.0, elem), ai), pre)
	end
	if op == "CONJ" then
		return self:cplxmake(elem, ar,
			self:arith("SUB", self:fconst(0.0, elem), ai), pre)
	end
	local br, bi = self:cplxparts(b, elem, pre)

	if op == "ADD" or op == "SUB" then
		return self:cplxmake(elem, self:arith(op, ar, br),
			self:arith(op, ai, bi), pre)
	end
	if op == "EQ" or op == "NE" then
		local same = tree.binary("ANDAND", self.ty.i32,
			self:test(self:arith("EQ", ar, br)),
			self:test(self:arith("EQ", ai, bi)))

		if op == "NE" then
			same = tree.unary("LNOT", self.ty.i32, same)
		end
		pre[#pre + 1] = same
		return tree.node("SEQ", self.ty.i32, nil, nil, {arms = pre})
	end
	local fn = CPLXFN[op] and CPLXFN[op][elem.size]

	if not fn then
		self:err("_Complex has no " .. op)
		return self:cplxmake(elem, ar, ai, pre)
	end
	local call = self:cplxcall(fn, self.ty.complex(elem),
		{ar, ai, br, bi})

	if #pre == 0 then return call end
	pre[#pre + 1] = call
	return tree.node("SEQ", call.ty, nil, nil, {arms = pre})
end

return {}
