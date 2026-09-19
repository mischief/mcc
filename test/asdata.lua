-- The data directives against gas, a case at a time.
--
-- The instruction tests compare .text only, so a directive that lays
-- down bytes needs its own comparison.
--
--   lua5.4 test/asdata.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local as = require "as"
local dir = (os.getenv("TMPDIR") or "/tmp") .. "/comp-asdata"

os.execute("mkdir -p " .. dir)

local function slurp(path, mode)
	local f = io.open(path, mode or "r")
	if not f then return nil end
	local s = f:read("a")

	f:close()
	return s
end

-- Each case is one line of data in .text, so that one objcopy reaches it.
local CASES = {
	{"a quote in a string", [[	.ascii	"a\"b"]]},
	{"a hash in a string", [[	.ascii	"a#b"]]},
	{"a quote before a hash", [[	.ascii	"!\"#$%&'()*+,-"]]},
	{"an apostrophe in a string", [[	.ascii	"it's"]]},
	{"a semicolon in a string", [[	.ascii	"a;b"]]},
	{"a slash star in a string", [[	.ascii	"a/*b"]]},
	{"the named escapes", [[	.ascii	"a\tb\nc\rd\be\ff\vg\\h"]]},
	{"an octal escape", [[	.ascii	"a\101\0\377b"]]},
	{"a terminated string", [[	.asciz	"a\"b#c"]]},
	{"bytes", [[	.byte	1, -1, 255, 0]]},
	{"shorts", [[	.short	1, -1, 65535]]},
	{"longs", [[	.long	1, -1, 305419896]]},
	{"quads", [[	.quad	1, -1, 1234605616436508552]]},
	{"a run of zeros", [[	.zero	7]]},
	{"a hidden name", "\t.globl\tv\n\t.hidden\tv\nv:\n\t.byte\t1"},
	{"a weak name", "\t.weak\tx\nx:\n\t.byte\t1"},
	{"a protected name",
	 "\t.globl\tw\n\t.protected\tw\nw:\n\t.byte\t1"},
	-- gas pads an executable section with nops unless the fill byte
	-- is spelled out; this assembler always pads with zero.
	{"alignment after a byte",
	 "\t.byte\t1\n\t.balign\t8,0\n\t.byte\t2"},
	{"a macro with parameters", [[
	.macro	pair a, b
	.byte	\a, \b
	.endm
	pair	1, 2
	pair	b=4, a=3]]},
	{"a macro parameter with a default", [[
	.macro	one a, b=9
	.byte	\a, \b
	.endm
	one	1
	one	1, 2]]},
	{"a macro parameter glued to a name", [[
	.macro	glue n
	.byte	0x\n\()0
	.endm
	glue	1
	glue	2]]},
	{"the macro invocation counter", [[
	.macro	tag
	.byte	\@
	.endm
	tag
	tag
	tag]]},
	{"a repeat", [[
	.rept	4
	.byte	7
	.endr]]},
	{"a counter advanced inside a repeat", [[
	.set	i, 0
	.rept	5
	.byte	i * 2
	.set	i, i + 1
	.endr]]},
	{"a conditional", [[
	.if	1
	.byte	1
	.else
	.byte	2
	.endif
	.if	0
	.byte	3
	.else
	.byte	4
	.endif]]},
	{"an else-if chain", [[
	.set	n, 2
	.if	n == 1
	.byte	11
	.elseif	n == 2
	.byte	22
	.else
	.byte	33
	.endif]]},
	{"a defined test", [[
	.set	have, 1
	.ifdef	have
	.byte	1
	.endif
	.ifdef	missing
	.byte	2
	.endif
	.ifndef	missing
	.byte	3
	.endif]]},
	{"comparisons and logic in a condition", [[
	.set	i, 12
	.if	i == 8 || (i >= 10 && i <= 14) || i == 17
	.byte	1
	.else
	.byte	0
	.endif]]},
	-- The shape idt_stubs.S is written in: a table where some entries
	-- differ from the rest, built by counting through a repeat.
	{"a conditional inside a repeat", [[
	.set	i, 0
	.rept	8
	.if	i == 3 || i == 6
	.byte	0xff
	.else
	.byte	i
	.endif
	.set	i, i + 1
	.endr]]},
	{"a macro called from a repeat", [[
	.macro	ent n
	.short	\n
	.endm
	.set	i, 0
	.rept	4
	ent	i + 100
	.set	i, i + 1
	.endr]]},
	{"the distance from here to a label", [[
h1:
	.byte	1
	.long	h1 - .
	.long	(h1) - .
	.long	. - h1]]},
	{"the distance between two labels", [[
h2:
	.byte	1, 2, 3
h3:
	.long	h3 - h2
	.long	(h3) - (h2)]]},
	{"arithmetic around a label distance", [[
h4:
	.byte	0
h5:
	.long	(h5 - h4) * 4 + 1
	.long	((h5 - h4) << 3) | 2]]},
	{"the widths gas spells more than one way", [[
	.word	1
	.int	2
	.value	3
	.hword	4
	.2byte	5
	.4byte	6
	.8byte	7]]},
	{"a sixteen byte value", [[
	.octa	0x1234567890abcdef1122334455667788
	.octa	0xff
	.octa	3]]},
	{"previous goes back to the section before", [[
	.byte	1
	.section .foo,"a"
	.byte	9
	.previous
	.byte	2
	.section .foo,"a"
	.byte	8
	.previous
	.byte	3]]},
	{"a pushed section comes back off the stack", [[
	.byte	1
	.pushsection .bar,"a"
	.byte	9
	.pushsection .baz,"a"
	.byte	8
	.popsection
	.popsection
	.byte	2]]},
	{"an assembler symbol as an immediate", [[
	.set	STACK_SIZE, 4096
	movq	$STACK_SIZE, %rax
	subq	$STACK_SIZE-8, %rsp
	movl	$STACK_SIZE >> 4, %ecx]]},
	{"the flag and return instructions", [[
	clc
	stc
	cmc
	lretq
	sahf
	lahf
	emms]]},
	{"the vector instructions", [[
	punpcklqdq	%xmm1, %xmm2
	punpckhbw	%xmm3, %xmm4
	paddq	%xmm5, %xmm6
	psubd	%xmm7, %xmm8
	pmuludq	%xmm9, %xmm10
	pandn	%xmm11, %xmm12
	unpcklps	%xmm13, %xmm14
	mulpd	%xmm15, %xmm0]]},
	-- How the kernel's ALTERNATIVE macros pass an instruction: the
	-- quotes are the argument's edges, not part of it, and a comma
	-- inside them does not start a new argument.
	{"the wide compare and exchange", [[
	cmpxchg16b	(%rsi)
	cmpxchg8b	(%rdi)
	lock cmpxchg16b	8(%rax)]]},
	{"the bit counting instructions", [[
	tzcnt	%rax, %rbx
	lzcnt	%eax, %ebx
	popcnt	%rcx, %rdx
	lsl	%eax, %ebx]]},
	{"the cache hints", [[
	prefetchnta	(%rsi)
	prefetcht0	(%rsi)
	prefetcht1	8(%rsi)
	prefetchw	(%rdi)
	clflush	(%rsi)
	clflushopt	(%rsi)
	clwb	(%rsi)]]},
	{"the three byte vector opcodes", [[
	pshufb	%xmm1, %xmm2
	pmulld	%xmm3, %xmm4
	ptest	%xmm5, %xmm6]]},
	{"a symbol as an immediate", [[
	movq	$target, %rax
	movl	$target, %eax
	movabsq	$target, %rbx
	movq	$target+8, %rcx
	pushq	$target]]},
	{"a list repeat", [[
	.irp	n, 1, 2, 3
	.byte	\n
	.endr
	.irpc	c, abc
	.ascii	"\c"
	.endr]]},
	{"the read process id and the non temporal store", [[
	rdpid	%rax
	movntil	%eax, (%rdi)
	movntiq	%rax, (%rdi)]]},
	{"the counted forms with a size letter", [[
	popcntl	%eax, %ebx
	popcntq	%rax, %rbx
	tzcntl	%eax, %ebx]]},
	{"the vector shifts", [[
	psrld	$3, %xmm1
	psrld	%xmm2, %xmm1
	psllq	$7, %xmm3
	psrldq	$4, %xmm4
	pslldq	$4, %xmm5]]},
	{"the hashing instructions", [[
	sha1nexte	%xmm1, %xmm2
	sha256msg1	%xmm3, %xmm4
	sha256rnds2	%xmm5, %xmm6]]},
	{"a register with a name of its own", [[
	.set	CTX, %rdi
	.set	INP, %rdx
	movq	4*0(CTX), %rax
	movq	8(CTX,INP,4), %r8
	xor	CTX, INP]]},
	{"macro parameters separated by spaces", [[
	.macro	pair a:req b:req
	.byte	\a, \b
	.endm
	pair	1, 2
	.macro	two x y=7
	.byte	\x, \y
	.endm
	two	3]]},
	{"two statements from one macro argument", [[
	.macro	semi ins
	\ins
	.endm
	semi	"movq %rax, %rdx; nop"]]},
	{"a prefix on a line of its own", [[
	ds clflush (%rax)
	cs nop
	clac
	stac]]},
	{"the vector opcodes that take a pattern byte", [[
	palignr	$4, %xmm1, %xmm2
	pblendw	$2, %xmm3, %xmm4]]},
	{"a shift with the count left out", [[
	shrl	%edx
	sarq	%rbx
	rolb	%cl]]},
	{"the string comparing conditionals", [[
	.macro	m a, b
	.ifc	\a,\b
	.byte	1
	.else
	.byte	2
	.endif
	.ifb	\b
	.byte	3
	.endif
	.ifnb	\a
	.byte	4
	.endif
	.endm
	m	x, x
	m	x, y
	m	z
	.ifeqs	"ab", "ab"
	.byte	5
	.endif
	.ifnes	"ab", "cd"
	.byte	6
	.endif]]},
	{"the debug registers either way round", [[
	movq	%db0, %rax
	movq	%dr7, %rbx
	monitorx
	mwaitx]]},
	{"a macro forgotten and written again", [[
	.macro	m
	.byte	1
	.endm
	m
	.purgem	m
	.macro	m
	.byte	2
	.endm
	m]]},
	{"spaces the preprocessor left in an operand", [[
	movl	target (% rip), %eax
	movq	8 (%rsp), %rbx]]},
	{"a far jump through a place", [[
	ljmpl	*(%rax)
	lcall	*(%rbx)]]},
	-- gas fills the parameters in order and leaves the rest with the
	-- last, so `one 1 + 2` is one argument and `three 10 11 12` is
	-- three.
	{"macro arguments separated by spaces", [[
	.macro	one n
	.byte	\n
	.endm
	one	1 + 2
	one	3+4
	.macro	three a b c
	.byte	\a, \b, \c
	.endm
	three	10 11 12
	three	13, 14, 15
	.macro	UACCESS op src dst
	\op	\src, \dst
	.endm
	UACCESS movzbl (%rax),%edx]]},
	{"a macro default value with spaces in it", [[
	.macro	FRB reg:req nr:req ftr:req ftr2=((1 << 0) << 16 | 5)
	mov	$(\nr/2), \reg
	.long	\ftr
	.long	\ftr2
	.endm
	FRB	%rax, 32, (22*32 + (1*32+ 4))
	FRB	%rbx, 16, 5, 6]]},
	-- gas compares two registers in a condition by which register
	-- they are, which is how a macro asks what it was handed.
	{"a register in a condition", [[
	.macro	H base=%rsp
	.if	\base == %rsp
	.byte	1
	.elseif	\base == %rdx
	.byte	2
	.else
	.error	"bad base"
	.endif
	.endm
	H
	H	base=%rdx]]},
	-- How the kernel writes its interrupt entries: a numeric label
	-- with a space before its colon, and a fill measured from it.
	{"a label with a space before its colon", [[
	.set	IDT_ALIGN, 16
	.set	vector, 32
	.rept	4
0 :
	.byte	0x6a, vector
	jmp	common
	.fill	0b + IDT_ALIGN - ., 1, 0xcc
	vector = vector+1
	.endr
common:
	ret]]},
	{"the thread pointer registers", [[
	rdgsbase	%rax
	rdfsbase	%rbx
	wrgsbase	%rcx
	wrfsbase	%rdx
	rdgsbase	%eax]]},
	-- gas reads a mnemonic to the end of its name, not to the next
	-- space, so a macro may be called with its argument in
	-- parentheses and no space at all.
	{"a macro called with no space before its argument", [[
	.macro	one a
	.byte	\a
	.endm
	one(7)
	one	8
	movl	$5,%eax]]},
	{"the AVX forms the VEX prefix spells", [[
	vpaddd	%xmm1, %xmm2, %xmm3
	vpaddd	%ymm1, %ymm2, %ymm3
	vpxor	%xmm10, %xmm11, %xmm12
	vpor	%ymm13, %ymm14, %ymm15
	vpshufb	%xmm1, %xmm2, %xmm3
	vpshufd	$0x1b, %xmm4, %xmm5
	vpshufd	$0x1b, %ymm4, %ymm5
	vpslld	$7, %xmm1, %xmm2
	vpsrld	$3, %ymm1, %ymm2
	vpsrlq	$5, %xmm1, %xmm2
	vpalignr	$4, %xmm1, %xmm2, %xmm3
	vperm2i128	$0x20, %ymm1, %ymm2, %ymm3
	vextracti128	$1, %ymm5, %xmm6
	vmovdqa	%xmm1, %xmm2
	vmovdqa	(%rdi), %ymm3
	vmovdqa	%ymm3, (%rsi)
	vmovdqu	(%rdi), %xmm4
	vmovdqu	%xmm4, 16(%rsi)
	vpmovzxbd	(%rdi), %ymm1
	vmovd	%eax, %xmm1
	vmovd	%xmm1, %eax
	vzeroupper
	vpaddq	%ymm1, %ymm2, %ymm3]]},
	{"a register named after another register", [[
	.set	CTX, %rdi
	.set	SRND, CTX
	xor	SRND, SRND
	addl	8(%rsp, SRND), %eax]]},
	{"the double shifts", [[
	shld	$7, %eax, %ebx
	shldl	$7, %eax, %ebx
	shrd	$3, %rax, %rbx
	shld	%cl, %eax, %ebx
	shrd	%cl, %rax, %rbx]]},
	-- Hand written assembly rotates a set of register names, so each
	-- has to take the register the one before it held rather than
	-- its name.
	{"a rotated set of register names", [[
	.set	f, %r9d
	.set	g, %r10d
	.macro	ROT
	.set	h, g
	.set	g, f
	.set	f, %r11d
	.endm
	mov	f, %eax
	ROT
	mov	f, %eax
	mov	g, %ebx
	mov	h, %ecx]]},
	{"a rotate that writes elsewhere", [[
	rorx	$6, %eax, %ebx
	rorx	$13, %rax, %rbx]]},
	-- The place is the last parenthesised group: a displacement may
	-- be an expression in parentheses of its own.
	{"a displacement in parentheses", [[
	.set	_XFER, 64
	.set	SRND, %rcx
	addl	(_XFER + 0*32)(%rsp, SRND), %eax
	addl	(_XFER + 1*32)(%rsp), %ebx
	movq	8(%rsp), %rdx
	movq	(%rax,%rbx,4), %rdi]]},
	{"a name where a place was wanted is the address", [[
	testb	$1, target+1
	testb	$2, target
	movl	$3, target]]},
	{"saving the floating point and vector state", [[
	fxsave	(%rax)
	fxsaveq	(%rax)
	fxrstor	(%rbx)
	fxrstorq	(%rbx)
	ldmxcsr	(%rcx)
	stmxcsr	(%rdx)
	xsave	(%rsi)
	xrstor	(%rdi)]]},
	{"saving the whole x87 state", [[
	fnsave	(%rax)
	frstor	(%rbx)
	fnstenv	(%rcx)
	fldenv	(%rdx)
	fnstcw	(%rsi)
	fldcw	(%rdi)]]},
	-- The status word into ax has an encoding of its own, not the
	-- one that writes it to a place.
	{"the x87 status word", [[
	fnstsw	%ax
	fstsw	%ax
	fnstsw	(%rbx)
	fnstcw	(%rcx)]]},
	{"a quoted macro argument", [[
	.macro	alt old, new
	\old
	\new
	.endm
	alt	"movl $1, %eax", "nop"
	alt	"clc", "stc"]]},
	{"an angle bracket macro argument", [[
	.altmacro
	.macro	one a
	.byte	\a
	.endm
	one	<1 + 2>
	one	3]]},
	{"an evaluated macro argument under altmacro", [[
	.altmacro
	.macro	num n
	.byte	\n
	.endm
	.set	i, 5
	num	%i
	num	%i * 3]]},
}

-- A line marker from the preprocessor says which line of which file
-- comes next, so an error names the source rather than the text the
-- assembler was handed.
do
	local src = '# 1 "z.S"\n\t.text\n\tnop\n\tbogusinsn\n'
	local ok, err = pcall(as.assemble, src, {arch = "amd64"})

	if not tap.ok(not ok and tostring(err):find("z.S:3", 1, true) ~= nil,
	    "an error names the line the marker gave") then
		tap.diag(tostring(err))
	end
end

local function build(body)
	local src = "\t.text\n" .. body .. "\n"
	local f = assert(io.open(dir .. "/d.s", "w"))

	f:write(src)
	f:close()
	if os.execute(("as --64 -o %s/d.o %s/d.s 2>%s/err")
	    :format(dir, dir, dir)) ~= true then
		return nil, (slurp(dir .. "/err") or ""):gsub("\n.*", "")
	end
	os.execute(("objcopy -O binary --only-section=.text " ..
		"%s/d.o %s/d.bin"):format(dir, dir))
	local want = slurp(dir .. "/d.bin", "rb") or ""
	local ok, a = pcall(as.assemble, src, {arch = "amd64"})

	if not ok then return nil, tostring(a) end
	return a.sec[".text"].bytes, want
end

local function hex(s)
	return (s:gsub(".", function(c)
		return ("%02x"):format(c:byte())
	end))
end

-- Every mnemonic the table says takes no operands, against gas.  A
-- wrong encoding here is silent: the bytes assemble and do something
-- else.
do
	local src = io.open(here .. "/../as/amd64.lua"):read("a")
	local body = src:match("local BARE = {(.-)\n\t}") or ""
	local names = {}

	for n in body:gmatch("([%w_]+)%s*=%s*{") do
		names[#names + 1] = n
	end
	for n in body:gmatch('%["([%w_]+)"%]%s*=%s*{') do
		names[#names + 1] = n
	end
	local out = {}

	for _, n in ipairs(names) do out[#out + 1] = "\t" .. n end
	local mine, want = build(table.concat(out, "\n"))

	if mine == nil then
		tap.ok(false, "the bare mnemonics: " .. tostring(want))
	elseif not tap.ok(mine == want, ("all %d bare mnemonics match gas")
	    :format(#names)) then
		tap.diag("ours: " .. hex(mine))
		tap.diag("gas:  " .. hex(want))
	end
end

-- The x87 mnemonics that take no operand.  They live in a table of
-- their own, and four of them were each other's encoding: fsubp and
-- fsubrp, fdivp and fdivrp.  Nothing said so, because the bytes
-- assemble and subtract the other way round.
do
	local src = io.open(here .. "/../as/amd64.lua"):read("a")
	local body = src:match("local FNOARG = {(.-)\n}") or ""
	local names = {}

	for n in body:gmatch("([%w_]+)%s*=%s*{") do
		names[#names + 1] = n
	end
	local out = {}

	for _, n in ipairs(names) do out[#out + 1] = "\t" .. n end
	local mine, want = build(table.concat(out, "\n"))

	if mine == nil then
		tap.ok(false, "the bare x87 mnemonics: " .. tostring(want))
	elseif not tap.ok(mine == want,
	    ("all %d bare x87 mnemonics match gas"):format(#names)) then
		tap.diag("ours: " .. hex(mine))
		tap.diag("gas:  " .. hex(want))
	end
end

-- The x87 stack registers, in every order the arithmetic is written.
-- Which register the number is added to depends on which operand is
-- %st, and the answer goes to a different one in each of the three.
do
	local out = {}

	for _, m in ipairs{"fadd", "fmul", "fsub", "fsubr", "fdiv",
			   "fdivr"} do
		out[#out + 1] = ("\t%s\t%%st(1),%%st"):format(m)
		out[#out + 1] = ("\t%s\t%%st,%%st(2)"):format(m)
		out[#out + 1] = ("\t%s\t%%st(3)"):format(m)
		out[#out + 1] = ("\t%sp\t%%st,%%st(1)"):format(m)
		out[#out + 1] = ("\t%sp\t%%st,%%st(2)"):format(m)
		out[#out + 1] = ("\t%sp\t%%st(1)"):format(m)
		out[#out + 1] = ("\t%sp\t%%st(3)"):format(m)
	end
	for _, m in ipairs{"fcomi", "fucomi", "fcomip", "fucomip"} do
		out[#out + 1] = ("\t%s\t%%st(1),%%st"):format(m)
		out[#out + 1] = ("\t%s\t%%st(2)"):format(m)
	end
	for _, m in ipairs{"fld", "fst", "fstp", "fxch", "ffree", "fucom",
			   "fucomp", "fcom", "fcomp"} do
		out[#out + 1] = ("\t%s\t%%st(1)"):format(m)
	end
	for _, m in ipairs{"fldt", "fstpt", "fldl", "fstpl", "flds",
			   "fstps", "fildll", "fistpll", "fildl", "fistpl",
			   "faddl", "fsubl", "fmull", "fdivl", "fcoml",
			   "fnstcw", "fldcw"} do
		out[#out + 1] = ("\t%s\t8(%%rax)"):format(m)
	end
	local mine, want = build(table.concat(out, "\n"))

	if mine == nil then
		tap.ok(false, "the x87 stack forms: " .. tostring(want))
	elseif not tap.ok(mine == want, "the x87 stack forms match gas") then
		tap.diag("ours: " .. hex(mine))
		tap.diag("gas:  " .. hex(want))
	end
end

-- The shape a kernel writes a function's type and length in: no
-- comma before the type, the type spelled STT_FUNC, and the length
-- reached through a symbol given the difference of two labels.
do
	local src = "\t.text\n\t.globl\tf\nf:\n\tnop\n\tret\n" ..
		"\t.type f STT_FUNC\n\t.set .L__sz_f, .-f\n" ..
		"\t.size f, .L__sz_f\n"
	local ok, a = pcall(as.assemble, src, {arch = "amd64"})

	if not tap.ok(ok, "a kernel's way of ending a function") then
		tap.diag(tostring(a))
	else
		local d = a.syms.f

		if not tap.ok(d and d.styp == 2 and d.size == 2,
		    "says what it is and how long it is") then
			tap.diag(("type %s size %s"):format(
				tostring(d and d.styp), tostring(d and d.size)))
		end
	end
end

-- Comparison in an expression, and room that turns on a label
-- further down the file.  A kernel pads an instruction out to the
-- length of the one that may replace it, and writes both with these.
do
	local mine, want = build("\t.byte (5 > 3)\n\t.byte (3 > 5)\n" ..
		"\t.byte -(5 > 3) * 4\n\t.byte 1 < 2\n" ..
		"\t.byte 7 != 3\n\t.byte 4 == 4\n\t.byte 9 <= 9\n")

	if mine == nil then
		tap.ok(false, "comparison: " .. tostring(want))
	elseif not tap.ok(mine == want, "comparison matches gas") then
		tap.diag("ours: " .. hex(mine))
		tap.diag("gas:  " .. hex(want))
	end
end

do
	local mine, want = build("\t.skip (2f - 1f), 0x90\n1:\n" ..
		"\tnop\n\tnop\n\tnop\n2:\n")

	if mine == nil then
		tap.ok(false, "room measured forward: " .. tostring(want))
	elseif not tap.ok(mine == want,
	    "room that turns on a later label matches gas") then
		tap.diag("ours: " .. hex(mine))
		tap.diag("gas:  " .. hex(want))
	end
end

-- A numeric local label named from another section: the kernel's
-- alternatives are a table of `.long 1b - .` in a section of their
-- own, and each one has to name the label it was written beside.
do
	local src = "\t.text\n\tnop\n1:\n\tnop\n" ..
		'\t.pushsection .alt,"a"\n\t.long 1b - .\n\t.popsection\n' ..
		"\tnop\n1:\n\tnop\n" ..
		'\t.pushsection .alt,"a"\n\t.long 1b - .\n\t.popsection\n'
	local ok, a = pcall(as.assemble, src, {arch = "amd64"})

	if not tap.ok(ok, "a local label named from another section") then
		tap.diag(tostring(a))
	else
		local alt, names = nil, {}

		for _, s2 in ipairs(a.order) do
			if s2.name == ".alt" then alt = s2 end
		end
		for _, r in ipairs(alt and alt.relocs or {}) do
			names[#names + 1] = r.sym
		end
		if not tap.ok(#names == 2 and names[1] ~= names[2],
		    "and each one names its own") then
			tap.diag(table.concat(names, " "))
		end
	end
end

-- A number may carry the suffix C gives one: a header hands a
-- constant straight to a template and the assembler sees it whole.
do
	local out = {
		"\tcmpl\t$0x0700a169U,%eax",
		"\tmovl\t$123UL,%eax",
		"\tmovq\t$0xffffffffffffffffULL,%rbx",
		"\tmovl\t$1000000u,%ecx",
		"\taddq\t$16UL,%rsp",
	}
	local mine, want = build(table.concat(out, "\n"))

	if mine == nil then
		tap.ok(false, "a suffixed number: " .. tostring(want))
	elseif not tap.ok(mine == want,
	    "a number with a C suffix matches gas") then
		tap.diag("ours: " .. hex(mine))
		tap.diag("gas:  " .. hex(want))
	end
end

-- A section name may be quoted, and then the flags are the quoted
-- string after it.  The kernel writes `.section ".export_symbol","a"`
-- and a validator reads the flags to decide whether it holds code.
do
	local src = '\t.section ".export_symbol","a"\n' ..
		"\t.quad 1\n\t.previous\n\t.text\n\tnop\n"
	local ok, a = pcall(as.assemble, src, {arch = "amd64"})

	if not tap.ok(ok, "a quoted section name") then
		tap.diag(tostring(a))
	else
		local found

		for _, s2 in ipairs(a.order) do
			if s2.name == ".export_symbol" then found = s2 end
		end
		if not tap.ok(found ~= nil,
		    "keeps its name without the quotes") then
			local nm = {}

			for _, s2 in ipairs(a.order) do
				nm[#nm + 1] = s2.name
			end
			tap.diag(table.concat(nm, " "))
		elseif not tap.ok(found.perm == 4,
		    "and the flags it was given") then
			tap.diag("perm " .. tostring(found.perm))
		end
	end
end

-- A displacement that names an address: the linker fills it in and
-- the addend travels with the relocation.  Per-cpu code writes one.
do
	local out = {
		"\tmovq\tsym(%rdx),%rax",
		"\tmovq\tsym+8(%rdx),%rax",
		"\tmovq\tsym-4(%rdx,%rcx,4),%rbx",
		"\tmovq\tsym(%rdx,%rcx,8),%rbx",
		"\tmovl\tsym(%r13),%eax",
		"\tleaq\tsym(%r12,%rax,2),%rdx",
	}
	local mine, want = build(table.concat(out, "\n"))

	if mine == nil then
		tap.ok(false, "a symbol as a displacement: " ..
			tostring(want))
	elseif not tap.ok(mine == want,
	    "a symbol as a displacement matches gas") then
		tap.diag("ours: " .. hex(mine))
		tap.diag("gas:  " .. hex(want))
	end
end

-- `mov sym@GOTPCREL(%rip), %reg` with nothing to read the table from
-- is `lea sym(%rip), %reg`.  gas writes the relaxable relocation and
-- the linker is what turns one into the other, so this runs the whole
-- way rather than comparing bytes.
do
	local src = dir .. "/gp.s"
	local f = assert(io.open(src, "w"))

	f:write([[
	.text
	.globl	_start
_start:
	movq	target@GOTPCREL(%rip),%rax
	movq	(%rax),%rdi
	movq	$60,%rax
	syscall
	.data
	.globl	target
target:
	.quad	42
]])
	f:close()
	local lua = os.getenv("LUA") or "lua5.4"
	local function run(cmd)
		return os.execute(cmd .. " >/dev/null 2>&1") == true
	end
	local ok = run(("as --64 -o %s/gp.o %s"):format(dir, src)) and
		run(("%s %s/../drive.lua -t amd64 -nostdlib -e _start " ..
		     "-o %s/gp %s/gp.o"):format(lua, here, dir, dir))

	if not ok then
		tap.ok(false, "a relaxed GOT reference")
	else
		local p = io.popen(("%s/gp; echo $?"):format(dir))
		local out = (p:read("a") or ""):gsub("%s+$", "")

		p:close()
		if not tap.ok(out == "42", "a relaxed GOT reference") then
			tap.diag("exit status " .. out .. ", wanted 42")
		end
	end
end

for _, c in ipairs(CASES) do
	local got, want = build(c[2])

	if got == nil then
		tap.ok(false, c[1])
		tap.diag(want)
	elseif not tap.ok(got == want, c[1]) then
		tap.diag("ours: " .. hex(got))
		tap.diag("gas:  " .. hex(want))
	end
end
tap.done()
