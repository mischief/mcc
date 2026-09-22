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
	movq	(%rsp),%r12
	leaq	8(%rsp),%r13
	andq	$-16,%rsp
	/* the constructors, preinit first, each array first to last */
	leaq	__preinit_array_start(%rip),%rbx
1:	leaq	__preinit_array_end(%rip),%rax
	cmpq	%rax,%rbx
	jae	2f
	call	*(%rbx)
	addq	$8,%rbx
	jmp	1b
2:	leaq	__init_array_start(%rip),%rbx
3:	leaq	__init_array_end(%rip),%rax
	cmpq	%rax,%rbx
	jae	4f
	call	*(%rbx)
	addq	$8,%rbx
	jmp	3b
4:	movq	%r12,%rdi
	movq	%r13,%rsi
	call	main
	movq	%rax,%r12
	call	__mcc_fini
	movq	%r12,%rdi
	movl	$60,%eax
	syscall

/* The destructors, last to first: after main returns, and from exit(). */
	.globl	__mcc_fini
__mcc_fini:
	pushq	%rbx
	leaq	__fini_array_end(%rip),%rbx
5:	leaq	__fini_array_start(%rip),%rax
	cmpq	%rax,%rbx
	jbe	6f
	subq	$8,%rbx
	call	*(%rbx)
	jmp	5b
6:	popq	%rbx
	ret

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
	/* exit() runs the destructors; _exit, below, does not */
	movq	%rsi,%r12
	andq	$-16,%rsp
	call	__mcc_fini
	movq	%r12,%rdi
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
