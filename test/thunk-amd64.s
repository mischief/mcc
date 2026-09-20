/* SPDX-License-Identifier: ISC */
/* The thunks a kernel supplies, so a test program built to go through
   them has them. A real pair traps speculation; these only have to get
   there. */
	.text
	.globl __x86_indirect_thunk_r11
__x86_indirect_thunk_r11:
	jmp	*%r11
	.globl __x86_return_thunk
__x86_return_thunk:
	ret
	.section .note.GNU-stack,"",@progbits
