/* SPDX-License-Identifier: ISC */
/*
 * The coroutine switch for amd64, the same under every System V system:
 *
 *	void lr_coswitch(void **save, void *to)
 *
 * The registers a callee keeps go on the running stack, the stack
 * pointer goes to *save, and the other stack's are taken back off it.
 * The ret returns into whoever switched away from that stack last, or,
 * for a coroutine that has never run, into its entry, which lr_coinit
 * left where the return address would be.
 */
	.text
	.globl	lr_coswitch
	.type	lr_coswitch,@function
lr_coswitch:
	pushq	%rbp
	pushq	%rbx
	pushq	%r12
	pushq	%r13
	pushq	%r14
	pushq	%r15
	movq	%rsp,(%rdi)
	movq	%rsi,%rsp
	popq	%r15
	popq	%r14
	popq	%r13
	popq	%r12
	popq	%rbx
	popq	%rbp
	ret
	.size	lr_coswitch, .-lr_coswitch
	.section	.note.GNU-stack,"",@progbits
