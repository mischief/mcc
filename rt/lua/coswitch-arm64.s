/* SPDX-License-Identifier: ISC */
/*
 * The coroutine switch for arm64, under AAPCS64:
 *
 *	void lr_coswitch(void **save, void *to)
 *
 * x19-x28, the frame pointer, the link register and d8-d15 go on the
 * running stack, the stack pointer goes to *save, and the other stack's
 * are taken back off it.  The ret returns through the x30 it loaded:
 * for a coroutine that has never run, its entry, which lr_coinit left
 * in that slot.
 */
	.text
	.globl	lr_coswitch
	.type	lr_coswitch,%function
lr_coswitch:
	sub	sp, sp, #160
	stp	x19, x20, [sp, #0]
	stp	x21, x22, [sp, #16]
	stp	x23, x24, [sp, #32]
	stp	x25, x26, [sp, #48]
	stp	x27, x28, [sp, #64]
	stp	x29, x30, [sp, #80]
	str	d8, [sp, #96]
	str	d9, [sp, #104]
	str	d10, [sp, #112]
	str	d11, [sp, #120]
	str	d12, [sp, #128]
	str	d13, [sp, #136]
	str	d14, [sp, #144]
	str	d15, [sp, #152]
	mov	x2, sp
	str	x2, [x0]
	mov	sp, x1
	ldp	x19, x20, [sp, #0]
	ldp	x21, x22, [sp, #16]
	ldp	x23, x24, [sp, #32]
	ldp	x25, x26, [sp, #48]
	ldp	x27, x28, [sp, #64]
	ldp	x29, x30, [sp, #80]
	ldr	d8, [sp, #96]
	ldr	d9, [sp, #104]
	ldr	d10, [sp, #112]
	ldr	d11, [sp, #120]
	ldr	d12, [sp, #128]
	ldr	d13, [sp, #136]
	ldr	d14, [sp, #144]
	ldr	d15, [sp, #152]
	add	sp, sp, #160
	ret
	.size	lr_coswitch, .-lr_coswitch
	.section	.note.GNU-stack,"",%progbits
