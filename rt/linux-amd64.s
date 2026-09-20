/* SPDX-License-Identifier: 0BSD */
/*
 * Entry and system calls for a static Linux program on amd64, in the
 * subset of assembly this compiler's own assembler reads.
 *
 * The kernel leaves argc at the stack pointer and argv just above it, and
 * wants the stack aligned to sixteen before a call.
 *
 * The call numbers the runtime uses are the ones rt/linux-riscv.s answers
 * to, so that one runtime serves every machine; this file translates.
 */
	.text
	.globl	_start
_start:
	movq	(%rsp),%rdi
	leaq	8(%rsp),%rsi
	andq	$-16,%rsp
	call	main
	movq	%rax,%rdi
	movl	$60,%eax
	syscall

	.globl	__syscall
__syscall:
	cmpq	$64,%rdi
	je	.Lwrite
	cmpq	$93,%rdi
	je	.Lexit
	movq	$-1,%rax
	ret
.Lwrite:
	movq	%rsi,%rdi
	movq	%rdx,%rsi
	movq	%rcx,%rdx
	movl	$1,%eax
	syscall
	ret
.Lexit:
	movq	%rsi,%rdi
	movl	$60,%eax
	syscall
	ret

	.globl	__exit
__exit:
	movq	%rsi,%rdi
	movl	$60,%eax
	syscall
	ret
	.section	.note.GNU-stack,"",@progbits
