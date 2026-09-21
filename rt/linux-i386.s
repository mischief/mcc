/* SPDX-License-Identifier: 0BSD */
/*
 * Entry and system calls for a static Linux program on i386, in the
 * subset of assembly this compiler's own assembler reads.
 *
 * The kernel leaves argc at the stack pointer and argv just above it.
 * The ABI wants the stack aligned to sixteen where a call is made, so
 * the two words this one pushes come off an aligned pointer eight
 * lower.
 *
 * The call numbers the runtime uses are the ones rt/linux-riscv.s
 * answers to, so that one runtime serves every machine; this file
 * translates.
 */
	.text
	.globl	_start
_start:
	movl	(%esp),%eax
	leal	4(%esp),%edx
	andl	$-16,%esp
	subl	$8,%esp
	pushl	%edx
	pushl	%eax
	call	main
	movl	%eax,%ebx
	movl	$1,%eax
	int	$0x80

/* ebx belongs to the caller, and every system call here wants it. */
	.globl	__syscall
__syscall:
	pushl	%ebx
	movl	8(%esp),%eax
	cmpl	$64,%eax
	je	.Lwrite
	cmpl	$93,%eax
	je	.Lexit
	movl	$-1,%eax
	popl	%ebx
	ret
.Lwrite:
	movl	12(%esp),%ebx
	movl	16(%esp),%ecx
	movl	20(%esp),%edx
	movl	$4,%eax
	int	$0x80
	popl	%ebx
	ret
.Lexit:
	movl	12(%esp),%ebx
	movl	$1,%eax
	int	$0x80
	popl	%ebx
	ret

	.globl	__exit
__exit:
	movl	8(%esp),%ebx
	movl	$1,%eax
	int	$0x80
	ret
	.section	.note.GNU-stack,"",@progbits
