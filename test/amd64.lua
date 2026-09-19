-- SPDX-License-Identifier: ISC
-- amd64 code tables.

local H = require "test.harness"
local tree = require "tree"

local t, ty = H.setup("amd64")
local C = tree.const
local bin, un = tree.binary, tree.unary
local function A(typ, i) return tree.auto(typ, t.slot(i)) end
local I = ty.i64

H.check("store constant",
	H.codegen(bin("ASGN", I, A(I, 1), C(I, 5))),
	"\tmovq\t$5,-8(%rbp)")

H.check("increment local",
	H.codegen(bin("ASGN", I, A(I, 1), bin("ADD", I, A(I, 1), C(I, 1)))),
[[
	movq	-8(%rbp),%rax
	addq	$1,%rax
	movq	%rax,-8(%rbp)]])

local function deref(i)
	return un("INDIR", I, A(ty.ptr(I), i))
end
H.check("increment through pointer",
	H.codegen(bin("ASGN", I, deref(2), bin("ADD", I, deref(2), C(I, 1)))),
[[
	movq	-16(%rbp),%rax
	movq	(%rax),%rax
	addq	$1,%rax
	movq	-16(%rbp),%rsi
	movq	%rax,(%rsi)]])

-- the harder operand is evaluated first: a + b*c becomes b*c + a
H.check("commutative flip",
	H.codegen(bin("ADD", I, A(I, 1), bin("MUL", I, A(I, 2), A(I, 3))), "reg"),
[[
	movq	-16(%rbp),%rax
	imulq	-24(%rbp),%rax
	addq	-8(%rbp),%rax]])

-- subtraction cannot flip, so the right operand takes the next register
H.check("second register",
	H.codegen(bin("SUB", I, A(I, 1), bin("MUL", I, A(I, 2), A(I, 3))), "reg"),
[[
	movq	-8(%rbp),%rax
	movq	-16(%rbp),%rsi
	imulq	-24(%rbp),%rsi
	subq	%rsi,%rax]])

-- a narrow load widens, and the pointee's kind picks how
H.check("signed byte load",
	H.codegen(un("INDIR", ty.i8, A(ty.ptr(ty.i8), 2)), "reg"),
[[
	movq	-16(%rbp),%rax
	movsbl	(%rax),%eax]])

H.check("unsigned byte load",
	H.codegen(un("INDIR", ty.u8, A(ty.ptr(ty.u8), 2)), "reg"),
[[
	movq	-16(%rbp),%rax
	movzbl	(%rax),%eax]])

H.check("compare and branch",
	H.branchgen(bin("LT", I, A(I, 1), A(I, 2)), ".Lout"),
[[
	movq	-8(%rbp),%rax
	cmpq	-16(%rbp),%rax
	jl	.Lout]])

H.check("unsigned branch",
	H.branchgen(bin("LT", I, A(ty.u64, 1), A(ty.u64, 2)), ".Lout"),
[[
	movq	-8(%rbp),%rax
	cmpq	-16(%rbp),%rax
	jb	.Lout]])

H.check("divide",
	H.codegen(bin("DIV", I, A(I, 1), A(I, 2)), "reg"),
[[
	movq	-8(%rbp),%rax
	movq	-16(%rbp),%rsi
	movq	%rsi,%r11
	movq	%rax,%rax
	cqto
	idivq	%r11
	movq	%rax,%rax]])

-- rax is live here, so the divide saves and restores it
H.check("divide with a live accumulator",
	H.codegen(bin("SUB", I, A(I, 1), bin("DIV", I, A(I, 2), A(I, 3))), "reg"),
[[
	movq	-8(%rbp),%rax
	movq	-16(%rbp),%rsi
	movq	-24(%rbp),%rdi
	subq	$16,%rsp
	movq	%rax,(%rsp)
	movq	%rdi,%r11
	movq	%rsi,%rax
	cqto
	idivq	%r11
	movq	%rax,%rsi
	movq	(%rsp),%rax
	addq	$16,%rsp
	subq	%rsi,%rax]])

H.check("remainder takes rdx",
	H.codegen(bin("MOD", ty.u64, A(ty.u64, 1), A(ty.u64, 2)), "reg"),
[[
	movq	-8(%rbp),%rax
	movq	-16(%rbp),%rsi
	movq	%rsi,%r11
	movq	%rax,%rax
	xorl	%edx,%edx
	divq	%r11
	movq	%rdx,%rax]])

H.check("variable shift uses cl",
	H.codegen(bin("SHL", I, A(I, 1), A(I, 2)), "reg"),
[[
	movq	-8(%rbp),%rax
	movq	-16(%rbp),%rsi
	movq	%rsi,%rcx
	shlq	%cl,%rax]])

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
	if not H.ok(out:find("subq\t%$16,%%rsp") and out:find("%(%%rsp%)"),
	    "spill to stack") then
		H.tap.diag(out)
	end
end

H.done()
