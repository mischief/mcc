/* SPDX-License-Identifier: 0BSD */
/*
 * Entry and system calls for a static Linux program on RISC-V, in the
 * subset of assembly this compiler's own assembler reads.
 *
 * The kernel leaves argc at the stack pointer and argv just above it.
 */
	.text
	.globl	_start
_start:
	.option push
	.option norelax
	la	gp,__global_pointer$
	.option pop
	ld	a0,0(sp)
	addi	a1,sp,8
	call	main
	mv	a1,a0
	li	a0,93
	call	__exit
	.globl	__syscall
__syscall:
	mv	a7,a0
	mv	a0,a1
	mv	a1,a2
	mv	a2,a3
	ecall
	ret
	.globl	__exit
__exit:
	mv	a7,a0
	mv	a0,a1
	ecall
	ret
