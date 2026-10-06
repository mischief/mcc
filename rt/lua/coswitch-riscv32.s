/* SPDX-License-Identifier: ISC */
/*
 * The coroutine switch for rv32 under ilp32, which has no float
 * registers to keep:
 *
 *	void lr_coswitch(void **save, void *to)
 *
 * ra and s0-s11 go on the running stack, the stack pointer goes to
 * *save, and the other stack's are taken back off it.  The ret returns
 * through the ra it loaded: for a coroutine that has never run, its
 * entry, which lr_coinit left in that slot.
 */
	.text
	.globl	lr_coswitch
	.type	lr_coswitch,@function
lr_coswitch:
	addi	sp, sp, -64
	sw	ra, 0(sp)
	sw	s0, 4(sp)
	sw	s1, 8(sp)
	sw	s2, 12(sp)
	sw	s3, 16(sp)
	sw	s4, 20(sp)
	sw	s5, 24(sp)
	sw	s6, 28(sp)
	sw	s7, 32(sp)
	sw	s8, 36(sp)
	sw	s9, 40(sp)
	sw	s10, 44(sp)
	sw	s11, 48(sp)
	sw	sp, 0(a0)
	mv	sp, a1
	lw	ra, 0(sp)
	lw	s0, 4(sp)
	lw	s1, 8(sp)
	lw	s2, 12(sp)
	lw	s3, 16(sp)
	lw	s4, 20(sp)
	lw	s5, 24(sp)
	lw	s6, 28(sp)
	lw	s7, 32(sp)
	lw	s8, 36(sp)
	lw	s9, 40(sp)
	lw	s10, 44(sp)
	lw	s11, 48(sp)
	addi	sp, sp, 64
	ret
	.size	lr_coswitch, .-lr_coswitch
	.section	.note.GNU-stack,"",@progbits
