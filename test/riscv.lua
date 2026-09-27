-- SPDX-License-Identifier: ISC
-- riscv64 code tables.  Nothing here can be addressed inside an arithmetic
-- instruction, there are no flags, and register names do not change width.

local H = require "test.harness"
local tree = require "mcc.tree"

local t, ty = H.setup("riscv64")
local C = tree.const
local bin, un = tree.binary, tree.unary
local function A(typ, i) return tree.auto(typ, t.slot(i)) end
local I = ty.i64

H.check("store zero",
	H.codegen(bin("ASGN", I, A(I, 1), C(I, 0))),
	"\tsd\tzero,-24(s0)")

H.check("store constant",
	H.codegen(bin("ASGN", I, A(I, 1), C(I, 5))),
[[
	li	a0,5
	sd	a0,-24(s0)]])

H.check("increment local",
	H.codegen(bin("ASGN", I, A(I, 1), bin("ADD", I, A(I, 1), C(I, 1)))),
[[
	ld	a0,-24(s0)
	addi	a0,a0,1
	sd	a0,-24(s0)]])

-- a constant past the twelve-bit field costs a register
H.check("wide constant",
	H.codegen(bin("ADD", I, A(I, 1), C(I, 100000)), "reg"),
[[
	ld	a0,-24(s0)
	li	a1,100000
	add	a0,a0,a1]])

-- the harder operand is evaluated first
H.check("commutative flip",
	H.codegen(bin("ADD", I, A(I, 1), bin("MUL", I, A(I, 2), A(I, 3))), "reg"),
[[
	ld	a0,-32(s0)
	ld	a1,-40(s0)
	mul	a0,a0,a1
	ld	a1,-24(s0)
	add	a0,a0,a1]])

H.check("byte load",
	H.codegen(un("INDIR", ty.i8, A(ty.ptr(ty.i8), 1)), "reg"),
[[
	ld	a0,-24(s0)
	lb	a0,0(a0)]])

-- a global has to have its address built first
H.check("global load",
	H.codegen(tree.name(I, "counter"), "reg"),
[[
	la	a0,counter
	ld	a0,0(a0)]])

H.check("store to global",
	H.codegen(bin("ASGN", I, tree.name(I, "counter"), C(I, 7))),
[[
	li	a0,7
	la	a1,counter
	sd	a0,0(a1)]])

-- the compare and the jump are one instruction
H.check("compare and branch",
	H.branchgen(bin("LT", I, A(I, 1), A(I, 2)), ".Lout"),
[[
	ld	a0,-24(s0)
	ld	a1,-32(s0)
	blt	a0,a1,.Lout]])

H.check("branch against zero",
	H.branchgen(bin("GT", I, A(I, 1), C(I, 0)), ".Lout"),
[[
	ld	a0,-24(s0)
	blt	zero,a0,.Lout]])

H.check("unsigned branch",
	H.branchgen(bin("LT", I, A(ty.u64, 1), A(ty.u64, 2)), ".Lout"),
[[
	ld	a0,-24(s0)
	ld	a1,-32(s0)
	bltu	a0,a1,.Lout]])

-- a plain value branches on itself, with no compare at all
H.check("branch on a value",
	H.branchgen(A(I, 1), ".Lout"),
[[
	ld	a0,-24(s0)
	bne	a0,zero,.Lout]])

-- no fixed registers here: divide and shift are ordinary instructions
H.check("divide",
	H.codegen(bin("DIV", I, A(I, 1), A(I, 2)), "reg"),
[[
	ld	a0,-24(s0)
	ld	a1,-32(s0)
	div	a0,a0,a1]])

H.check("unsigned remainder",
	H.codegen(bin("MOD", ty.u64, A(ty.u64, 1), A(ty.u64, 2)), "reg"),
[[
	ld	a0,-24(s0)
	ld	a1,-32(s0)
	remu	a0,a0,a1]])

H.check("variable shift",
	H.codegen(bin("SHL", I, A(I, 1), A(I, 2)), "reg"),
[[
	ld	a0,-24(s0)
	ld	a1,-32(s0)
	sll	a0,a0,a1]])

do
	local small = H.narrow()
	local function pair(a, b)
		return bin("ADD", I,
			bin("MUL", I, A(I, a), A(I, b)),
			bin("MUL", I, A(I, a + 1), A(I, b + 1)))
	end
	local deep = bin("SUB", I, A(I, 1),
		bin("ADD", I, pair(2, 3), pair(5, 6)))
	local out = H.codegen(deep, "reg", small)
	if not H.ok(out:find("addi\tsp,sp,%-16") and out:find("0%(sp%)"),
	    "spill to stack") then
		H.tap.diag(out)
	end
end

H.done()
