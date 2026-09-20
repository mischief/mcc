/* SPDX-License-Identifier: ISC */
/* The retpoline thunk a kernel supplies, so a test program built with
   -mretpoline has one to call.  A real one traps speculation; this one
   only has to get there. */
	.text
	.globl __x86_indirect_thunk_r11
__x86_indirect_thunk_r11:
	jmp	*%r11
	.section .note.GNU-stack,"",@progbits
