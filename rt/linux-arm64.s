/* SPDX-License-Identifier: 0BSD */
/*
 * Entry and system calls for a static Linux program on AArch64, in the
 * subset of assembly this compiler's own assembler reads.
 *
 * The kernel leaves argc at the stack pointer and argv just above it.
 *
 * The call numbers the runtime uses are the ones rt/linux-riscv.s answers
 * to, so that one runtime serves every machine; this file translates.
 */
	.text
	.globl	_start
_start:
	ldr	x0,[sp]
	add	x1,sp,#8
	bl	main
	mov	x8,#93
	svc	#0

	.globl	__syscall
__syscall:
	cmp	x0,#64
	b.eq	.Lwrite
	cmp	x0,#93
	b.eq	.Lexit
	mov	x0,#-1
	ret
.Lwrite:
	mov	x8,#64
	mov	x0,x1
	mov	x1,x2
	mov	x2,x3
	svc	#0
	ret
.Lexit:
	mov	x8,#93
	mov	x0,x1
	svc	#0
	ret

	.globl	__exit
__exit:
	mov	x8,#93
	mov	x0,x1
	svc	#0
	ret
	.section	.note.GNU-stack,"",@progbits
