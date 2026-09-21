-- SPDX-License-Identifier: ISC
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
	-- `#` of a macro argument arrives here as several strings in a
	-- row, which is how a kernel writes the licence of an export.
	{"two strings in a row", [[	.ascii	"ab" "cd"]]},
	{"two strings with a comma", [[	.ascii	"ab", "cd"]]},
	{"an empty string beside a NUL", [[	.ascii	"" "\0"]]},
	{"terminated strings with a comma", [[	.asciz	"ab", "cd"]]},
	{"a terminated pair in a row", [[	.asciz	"ab" "cd"]]},
	{"bytes", [[	.byte	1, -1, 255, 0]]},
	{"shorts", [[	.short	1, -1, 65535]]},
	{"longs", [[	.long	1, -1, 305419896]]},
	{"quads", [[	.quad	1, -1, 1234605616436508552]]},
	{"a run of zeros", [[	.zero	7]]},
	{"a hidden name", "\t.globl\tv\n\t.hidden\tv\nv:\n\t.byte\t1"},
	{"a weak name", "\t.weak\tx\nx:\n\t.byte\t1"},
	{"a protected name",
	 "\t.globl\tw\n\t.protected\tw\nw:\n\t.byte\t1"},
	-- Both assemblers pad code with nops when no fill byte is
	-- named, but gas picks one long nop where this one repeats
	-- 0x90, so only a spelled-out fill compares.
	{"alignment after a byte",
	 "\t.byte\t1\n\t.balign\t8,0\n\t.byte\t2"},
	{"alignment with a fill byte",
	 "\t.byte\t1\n\t.balign\t8,0xcc\n\t.byte\t2"},
	{"alignment with a fill byte and a skip limit",
	 "\t.byte\t1\n\t.p2align\t3,0xcc,7\n\t.byte\t2"},
	{"32-bit code", [[
	.code32
	movl	%cr0, %eax
	btrl	$31, %eax
	movl	%eax, %cr0
	pushfl
	popfl
	lgdtl	tbl
	lidtl	tbl
	ljmpl	$0x10, $(2f - .)
2:
	.org	64, 0x90
	.code64
tbl:]]},
	-- `0(%rip)` names nothing: it is a distance from the next
	-- instruction, which is how a kernel asks where it is.  A name
	-- there still goes to the linker.
	{"a distance from the program counter", [[	.text
	lea	0(%rip), %rax
	leaq	8(%rip),%rbx
	movq	-4(%rip),%rcx
	leaq	sym(%rip),%rdx
sym:
	nop]]},
	-- AVX-512 on the narrow registers, which a kernel's blake2s
	-- writes: the four byte prefix, and the two instructions that
	-- have no shorter encoding.
	{"the wide permute", [[	.text
	vpermi2d	%ymm7,%ymm6,%ymm8
	vpermi2d	%xmm7,%xmm6,%xmm8
	vpermi2d	%ymm3,%ymm2,%ymm1]]},
	{"the rotate that takes a count", [[	.text
	vprord	$0x10,%xmm3,%xmm3
	vprold	$0xc,%xmm1,%xmm1
	vprord	$0x7,%ymm9,%ymm10
	vprold	$0x1f,%ymm15,%ymm0]]},
	-- A numeric label reference is a whole name.  `0b` and `1f`
	-- inside `topo_domain_map_0b_1f` are part of the symbol, and
	-- `0b1010` is a number.
	{"a name that reads like two numeric labels", [[	.text
topo_domain_map_0b_1f:
	.byte	0b1010
1:
	.byte	1
	.byte	topo_domain_map_0b_1f - 1b]]},
	-- An argument of a macro is text until the body is built, and
	-- the body may define the label the argument refers to.  The
	-- kernel hands a whole loop, label and branch, to ALTERNATIVE.
	-- The letter on one that takes nothing names an operand size,
	-- which is all that tells `pushfl` from `pushfw`.
	{"the sizes of the bare instructions", [[	.code16
	.text
	pushfl
	popfl
	pushal
	popal
	retl
	retw
	jmpl	*%eax
	jmp	*%ax
	.code32
	pushfl
	pushfw
	retl
	retw
	jmpl	*%eax
	.code64
	ret
	retw]]},
	-- What is in the parentheses may not be a register: a name in
	-- them is an expression with parentheses round it, and the
	-- place is the address it works out to.  openbsd's wake-up and
	-- trampoline code writes `lgdtl (.Lgdt_desc)`.
	{"a name in parentheses is the place it names", [[	.code32
	.text
	lgdtl	(gdt_desc)
	lidtl	(gdt_desc)
	ljmp	*(jmp_target)
	movzbl	(gdt_desc), %eax
	movl	(gdt_desc), %ebx]]},
	-- A size prefix named by what it asks for.  The address size
	-- decides the shape of the address as well as the byte in front
	-- of it: openbsd's wake-up trampoline writes `addr32 lidtl`.
	{"the address and operand size prefixes", [[	.code16
	.text
clean_idt:
	.quad 0
	addr32 lidtl clean_idt
	addr32 lgdtl clean_idt
	addr32 movl %eax, (%ebx)
	.code32
	data16 movl $1, %eax
	.code64
	addr32 movl (%eax), %eax]]},
	-- The three operand float forms.  The size prefix is what tells
	-- a double from a single, and openbsd's mds.S writes vorpd.
	{"the three operand float forms", [[	.text
	vorpd	(%rax),%ymm0,%ymm0
	vorpd	%xmm1,%xmm2,%xmm3
	vandpd	(%rbx),%ymm4,%ymm5
	vxorpd	%ymm6,%ymm7,%ymm8
	vandnps	%xmm9,%xmm10,%xmm11
	vandnpd	(%rcx),%ymm12,%ymm13
	vaddpd	%ymm0,%ymm1,%ymm2
	vsubps	(%rdx),%xmm3,%xmm4
	vmulpd	%ymm5,%ymm6,%ymm7
	vdivps	%xmm8,%xmm9,%xmm10
	vminpd	%ymm11,%ymm12,%ymm13
	vmaxps	%xmm14,%xmm15,%xmm0
	vunpcklpd %ymm1,%ymm2,%ymm3
	vunpckhps %xmm4,%xmm5,%xmm6
	vaddsd	%xmm7,%xmm8,%xmm9
	vmulss	(%rsi),%xmm10,%xmm11]]},
	-- A store that does not keep the line, and the AMD forms, whose
	-- operand the encoding does not carry.  openbsd's mds.S and vmm
	-- write both kinds.
	{"stores that skip the cache, and the AMD group", [[	.text
	movntdq	%xmm0,(%rax)
	movntps	%xmm1,(%rbx)
	movntpd	%xmm2,16(%rcx)
	movntdq	%xmm9,(%r10)
	movnti	%eax,(%rdx)
	movnti	%r8,(%rdx)
	vmload	%rax
	vmsave	%rax
	vmrun	%rax
	vmmcall
	invlpga	%rax, %ecx
	stgi
	clgi]]},
	-- The VMX group, which a hypervisor writes: openbsd's vmm asks
	-- for every one of them.
	{"the virtual machine extensions", [[	.text
	vmxon	(%rdi)
	vmxoff
	vmclear	(%rsi)
	vmptrld	(%rdx)
	vmptrst	(%rcx)
	vmlaunch
	vmresume
	vmcall
	vmread	%rax, %rbx
	vmwrite	%rcx, %rdx
	vmread	%r9, (%r10)
	vmwrite	(%r11), %r12
	invept	(%rdi), %rsi
	invvpid	8(%rdi,%rax,4), %r13]]},
	-- A segment override belongs to the place it makes, whatever
	-- shape that place has.  linux reads `current` as
	-- `movq %gs:current_task, %rax`, and without the prefix the
	-- read lands on the per-cpu template.
	{"a segment override on every shape of place", [[	.text
	.globl	seghere
seghere:
	movq	%gs:seghere, %rax
	movq	%gs:16, %rbx
	movl	%fs:0, %ecx
	movq	%gs:(%rdi), %rdx
	movq	%gs:8(%rdi,%rsi,4), %r8
	addq	%gs:seghere, %rax
	movl	%fs:segthere, %r9d
	movb	%gs:seghere, %al
	.globl	segthere
segthere:
	.quad	0]]},
	-- The segment registers have opcodes of their own, and a
	-- kernel's bios call saves two of them.
	{"pushing a segment register", [[	.code16
	.text
	pushw	%fs
	pushw	%gs
	popw	%gs
	popw	%fs
	pushw	%ds
	pushw	%es
	popw	%es
	popw	%ds
	.code32
	pushl	%fs
	popl	%fs
	push	%ds
	pop	%ds
	.code64
	push	%fs
	pop	%gs]]},
	-- `((gdt)-startup_32)(%ebp)` is one displacement.
	{"a displacement wrapped in parentheses", [[	.code32
	.text
here:
	leal	(there-here)(%ebp), %eax
	leal	((there)-here)(%ebp), %eax
	.fill	200, 1, 0x90
there:
	.long	0]]},
	-- `A - B` with the two in different sections is a distance no
	-- number says, so a relocation carries it and the field holds
	-- four bytes however small the answer turns out to be.
	{"a displacement across two sections", [[	.code32
	.text
here:
	leal	(gdt)-here(%ebp), %eax
	leal	(gdt+8)-here(%ebp,%ecx,2), %edx
	movl	(gdt)-here(%ebp), %esi
	movl	(gdt)-here(%ebp,%ecx,2), %edi
	.code64
	.data
	.byte	0,0,0,0
gdt:
	.quad	0]]},
	-- How far to align is an expression, not only a number.  The
	-- kernel writes `.balign PAGE_SIZE`, which comes through as
	-- `(1 << 12)`.
	{"alignment by an expression", [[	.byte	1
	.balign	(1 << 6), 0
	.byte	2
	.balign	32, 0
	.byte	3
	.p2align (2 + 3), 0
	.byte	4
	.balign	(4 * 16), 0xcc
	.byte	5]]},
	-- `@PLT` says how to reach a name, not what the name is.  musl
	-- writes `call setjmp@PLT`, and a branch to a name this file
	-- does not define asks for the same relocation a call does.
	{"a branch through the table", [[	.text
	.globl	go
go:
	call	setjmp@PLT
	jmp	longjmp@plt
	call	plain
	je	elsewhere
	jmp	far_away
here:
	call	here
	jmp	here]]},
	-- `(%rip)` on its own names the next instruction.
	{"a bare rip operand", [[	.text
	lea	(%rip),%rax
	lea	0(%rip),%rbx
	mov	(%rip),%rcx
	movl	$1,(%rip)]]},
	-- A shift counts by cl and no other register, so that operand
	-- says nothing about how wide the shift is.
	{"a shift counted by cl", [[	.text
	shl	%cl,%rax
	sar	%cl,%rdx
	shl	%cl,%eax
	shr	%cl,%r8
	ror	%cl,%ax
	shl	%cl,%bl
	shld	%cl,%rax,%rbx
	shrd	%cl,%eax,%edx
	shlb	%cl,%al
	shl	$3,%rax
	shl	%rax]]},
	-- An immediate written unsigned stands for the same bits as the
	-- signed one, and the short form holds it.
	{"an immediate written unsigned", [[	.text
	cmp	$0xffffffff,%eax
	cmp	$-1,%eax
	add	$0xffffffff,%edx
	imul	$0xffffffff,%eax,%edx
	and	$0xff,%eax
	and	$0xffff,%ax
	cmp	$0xffffff80,%eax
	cmp	$0xffffff7f,%eax
	add	$0x7f,%ebx
	add	$0x80,%ebx
	or	$0xfff0,%bx
	sub	$-2,%rax
	pushq	$-1]]},
	-- The sections a startup file writes take their flags and their
	-- type from their names.  `.fini` with no flags is not mapped,
	-- and the program dies on the way out calling `_fini`.
	{"the sections a startup file writes", [[	.text
	.section .init
	nop
	.section .fini
	nop
	.section .init_array
	.quad	0
	.section .fini_array
	.quad	0
	.section .preinit_array
	.quad	0
	.section .ctors
	.quad	0
	.section .got
	.quad	0
	.section .plt
	nop
	.text
	nop]]},
	-- A section with no flags of its own takes them from its name,
	-- the way gas does.  The kernel writes
	-- `.section .text..__x86.indirect_thunk` and expects code.
	{"section flags from the name", [[	.text
	.section .text..thunk
	nop
	.section .rodata.cst8
	.byte	0
	.section .data.foo
	.byte	0
	.section .noidea
	.byte	0
	.section .discard.ann,"M",@progbits,8
	.long	0
	.long	1
	.text
	nop]]},
	-- A `.cfi_` directive says how to walk back out of a frame.
	-- This compiler writes none of its own, so one it is given is
	-- read and dropped.
	{"the frame directives", [[	.text
	.cfi_sections .debug_frame
	.cfi_startproc
	nop
	.cfi_def_cfa_offset 16
	.cfi_offset 6, -16
	nop
	.cfi_def_cfa_register 6
	.cfi_def_cfa 7, 8
	.cfi_endproc
	nop]]},
	{"a numeric label inside a macro argument", [[	.text
	.macro	alt old, new
	\old
	\new
	.endm
	.macro	fill reg
	alt "jmp .Lskip_\@", "mov $2, %\reg; 771: dec %\reg; jnz 771b;"
.Lskip_\@:
	.endm
	fill	rax
	fill	rbx]]},
	-- `\\@` counts the expansions before this one, so each body
	-- names its own label.
	{"the macro expansion counter", [[
	.macro	skip
	jmp	.Lskip_\@
	.byte	0xcc
.Lskip_\@:
	.endm
	skip
	skip]]},
	{"a macro parameter another name continues", [[
	.macro	ent lo, lo_len
	.byte	\lo, \lo_len
	.endm
	ent	1, 2]]},
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
	{"the stack instructions in 16-bit code", [[
	.code16
	pushl	%ebp
	popl	%ebp
	push	%bp
	pop	%bp
	pushl	$5
	pushl	$0x12345
	pushw	$5
	pushfl
	popfl
	leave
	leavel
	ret
	retl
	ret	$4
	retl	$8
	enter	$16,$0
	lret	$4
	call	1f
1:	nop]]},
	{"code16gcc is 16-bit code from a 32-bit generator", [[
	.code16gcc
1:	push	%ebp
	pop	%ebp
	push	$5
	push	$0x12345
	pushf
	popf
	pusha
	popa
	call	1b
	jmp	1b
	je	1b
	ret
	ret	$4
	leave
	enter	$0,$0
	iret
	movl	$1,%eax
	loop	1b]]},
	{"previous with nothing before it is ignored", [[
	.text
	.byte	1
	.previous
	.byte	2]]},
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
	{"the five hundred and twelve bit forms", [[
	vpxorq	(%rdi), %zmm0, %zmm0
	vpxorq	%zmm1, %zmm0, %zmm0
	vpxorq	%ymm1, %ymm0, %ymm2
	vpternlogq	$0x96, %zmm3, %zmm2, %zmm1
	vpternlogq	$0x96, %xmm2, %xmm1, %xmm0
	vbroadcasti32x4	(%rax), %zmm5
	vbroadcasti32x4	16(%rax), %zmm5
	vextracti64x4	$1, %zmm0, %ymm1
	vinserti64x4	$1, %ymm2, %zmm3, %zmm4
	vmovdqu8	(%rsi), %zmm7
	vmovdqu8	%zmm7, (%rsi)
	vmovdqa64	64(%rdx), %zmm8
	vmovdqu64	128(%rcx), %zmm2
	vpclmulqdq	$0x10, %zmm1, %zmm2, %zmm3
	vzeroupper]]},
	{"the bit handling group and the wide blends", [[
	andn	%eax, %ebx, %ecx
	andn	%rax, %rbx, %rcx
	andn	(%rsi), %r8, %r9
	shlx	%eax, %ebx, %ecx
	shrx	%rax, (%rbx), %rcx
	sarx	%eax, %ebx, %ecx
	bextr	%eax, %ebx, %ecx
	bzhi	%rax, %rbx, %rcx
	mulx	%eax, %ebx, %ecx
	pdep	%rax, %rbx, %rcx
	pext	%eax, %ebx, %ecx
	vpclmulqdq	$0x10, %ymm1, %ymm2, %ymm3
	vpblendvb	%ymm4, %ymm3, %ymm2, %ymm1
	vpblendvb	%xmm4, (%rax), %xmm2, %xmm1
	vblendvps	%ymm5, %ymm6, %ymm7, %ymm0
	vbroadcasti128	(%rax), %ymm1
	vbroadcastf128	(%rcx), %ymm2
	vpbroadcastd	%xmm3, %ymm4
	vpbroadcastq	(%rdx), %ymm5
	vpmovzxdq	%xmm1, %ymm2
	vpmovsxbw	(%rdi), %ymm3
	vpextrd	$3, %xmm2, 16(%rdi)
	vpextrd	$1, %xmm0, %eax
	vpextrq	$1, %xmm3, %rcx
	vpinsrd	$1, %eax, %xmm2, %xmm0
	vpinsrq	$0, %rsi, %xmm3, %xmm4
	vpinsrw	$2, %eax, %xmm1, %xmm5
	vextractps	$2, %xmm5, %r8d]]},
	{"taking a vector apart, which reads the other way round", [[
	pextrd	$3, %xmm2, 16(%rdi)
	pextrd	$1, %xmm0, %eax
	pextrb	$2, %xmm1, %edx
	pextrq	$1, %xmm3, %rcx
	extractps	$2, %xmm5, %r8d
	pinsrd	$1, %eax, %xmm0
	pinsrd	$2, (%rsi), %xmm4
	pblendvb	%xmm0, %xmm1, %xmm2
	pblendvb	%xmm3, %xmm4
	palignr	$4, %xmm1, %xmm2]]},
	{"the checksum, the carryless multiply and the hash rounds", [[
	crc32b	(%rsi), %eax
	crc32w	(%rsi), %eax
	crc32l	(%rsi), %eax
	crc32q	(%rsi), %rax
	crc32b	%cl, %eax
	crc32q	%rdx, %r8
	pclmulqdq	$0x00, %xmm1, %xmm2
	pclmulqdq	$0x11, %xmm3, %xmm4
	sha1rnds4	$3, %xmm1, %xmm2
	sha1nexte	%xmm1, %xmm2
	sha256msg1	%xmm5, %xmm6
	pmovzxdq	%xmm1, %xmm2
	pmovzxbw	%xmm3, %xmm4
	pmovsxdq	(%rax), %xmm5
	pmovzxwd	%xmm0, %xmm7]]},
	{"the one byte increment outside long mode", [[
	.code32
	decl	%ecx
	incl	%eax
	decw	%bx
	incw	%si
	decl	(%eax)
	incb	%al
	.code16
	decl	%ecx
	incw	%bx
	.code64
	decl	%ecx
	decq	%rax
	incl	%r9d]]},
	{"the high byte registers, which take no prefix", [[
	orb	%ch, 1(%rsp)
	shlb	$3, %ch
	movb	%ah, %bh
	addb	%dh, %al
	movb	%bpl, %sil
	movb	%spl, %dil
	xorb	%ah, %ah]]},
	{"a value too wide for the plain immediate", [[
	movq	$0x0123456789abcdef, %rax
	movq	$0x89abcdef, %rbx
	movq	$-1, %rcx
	movq	$0x7fffffff, %r13
	movq	$0x100000000, %r9
	movl	$0x89abcdef, %edx]]},
	{"a symbol as an immediate", [[
	movq	$target, %rax
	movl	$target, %eax
	movabsq	$target, %rbx
	movq	$target+8, %rcx
	pushq	$target]]},
	{"a branch to a name this file defines", [[
	.globl	hid
	.hidden	hid
	.globl	pub
start:
	jne	hid
	jne	pub
	jmp	pub
	call	hid
	call	pub
	lea	pub(%rip), %rax
hid:
	nop
pub:
	nop]]},
	{"the logical not in an expression", [[
	LSB = 1
	.long	32*!LSB
	.long	32*!!LSB
	.long	!0
	.long	!LSB + 4
	movq	8+32*!LSB(%rdi,%rsi), %rax]]},
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

-- The bytes of a relocated field are zero in both objects, so what
-- the last case proves is the width.  What the linker will put there
-- is `S + A - P`, and that has to match gas name for name.  A data
-- item measured from the spot it sits in asks the same question, and
-- eight bytes of one need a relocation of their own.
do
	local src = dir .. "/pc.s"
	local f = assert(io.open(src, "w"))

	f:write([[
	.text
	.globl	_start
_start:
	.code32
	leal	(gdt)-_start(%ebp), %eax
	leal	(gdt+8)-_start(%ebp,%ecx,2), %edx
	movl	(gdt)-_start(%ebp), %esi
	movl	(gdt)-_start(%ebp,%ecx,2), %edi
	.code64
	.quad	gdt - .
	.quad	gdt - . + 4
	.long	gdt - .
	.data
	.byte	0,0,0,0
gdt:
	.quad	0
]])
	f:close()
	-- What each relocation of .text comes to, one line each.  The
	-- name it points at may be the place itself or the section it
	-- sits in, and either spelling gives the same answer.
	local function relocs(obj)
		local p = io.popen("readelf -r -W " .. obj .. " 2>/dev/null")
		local out, sec = {}, nil

		for l in p:lines() do
			local s2 = l:match("^Relocation section '(%S+)'")

			if s2 then sec = s2 end
			local off, kind, val, add = nil, nil, nil, nil

			if sec == ".rela.text" then
				off, kind, val, add = l:match(
				    "^(%x+)%s+%x+%s+(%S+)%s+(%x+)%s+" ..
				    "%S+%s*%+%s*(%x+)")
			end
			if off then
				out[#out + 1] = ("%d %s %d"):format(
					tonumber(off, 16), kind,
					tonumber(val, 16) + tonumber(add, 16)
						- tonumber(off, 16))
			end
		end
		p:close()
		return table.concat(out, "\n")
	end
	local lua = os.getenv("LUA") or "lua5.4"
	local function run(cmd)
		return os.execute(cmd .. " >/dev/null 2>&1") == true
	end
	local ok = run(("as --64 -o %s/pcg.o %s"):format(dir, src)) and
		run(("MCC_PROG=mas %s %s/../drive.lua -t amd64 -c -o " ..
		     "%s/pcm.o %s"):format(lua, here, dir, src))
	local want = ok and relocs(dir .. "/pcg.o")
	local got = ok and relocs(dir .. "/pcm.o")

	if not ok or want == "" then
		tap.ok(false, "a displacement across two sections resolves")
	elseif not tap.ok(got == want,
	    "a displacement across two sections resolves like gas") then
		tap.diag("ours: " .. got)
		tap.diag("gas:  " .. want)
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
