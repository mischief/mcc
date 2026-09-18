/*
 * Bring-up for qemu-system-xtensa's sim machine, which starts at the reset
 * vector with the window option off.  Enough to reach main and to leave
 * again: set PS so that windowed calls work, point the stack at the top of
 * RAM, and exit through a simcall.
 */
	.section .reset, "ax"
	.globl	_reset
_reset:
	j	_start

	.section .init, "ax"
	.globl	_start
	.align	4
_start:
	movi	a0, 0
	movi	a2, 0x40020		/* PS.WOE | PS.UM */
	wsr	a2, ps
	rsync
	movi	a2, 0
	wsr	a2, windowbase
	rsync
	movi	a2, 1
	wsr	a2, windowstart
	rsync
	movi	a1, _stack_top
	call4	main
	mov	a3, a6			/* main's return value */
	movi	a2, 1			/* SYS_exit */
	simcall
.Lhang:
	j	.Lhang

/*
 * The window overflow and underflow handlers.  A windowed call that runs
 * out of physical registers traps here, and these spill a frame to, or
 * fill it from, the base save area below its stack pointer.  The six of
 * them sit at fixed offsets from the vector base.
 */
	.section .window, "ax"
	.align	64
	.globl	_WindowOverflow4
_WindowOverflow4:
	s32e	a0, a5, -16
	s32e	a1, a5, -12
	s32e	a2, a5, -8
	s32e	a3, a5, -4
	rfwo

	.align	64
_WindowUnderflow4:
	l32e	a0, a5, -16
	l32e	a1, a5, -12
	l32e	a2, a5, -8
	l32e	a3, a5, -4
	rfwu

	.align	64
_WindowOverflow8:
	s32e	a0, a9, -16
	l32e	a0, a1, -12
	s32e	a1, a9, -12
	s32e	a2, a9, -8
	s32e	a3, a9, -4
	s32e	a4, a0, -32
	s32e	a5, a0, -28
	s32e	a6, a0, -24
	s32e	a7, a0, -20
	rfwo

	.align	64
_WindowUnderflow8:
	l32e	a0, a9, -16
	l32e	a1, a9, -12
	l32e	a2, a9, -8
	l32e	a7, a1, -12
	l32e	a3, a9, -4
	l32e	a4, a7, -32
	l32e	a5, a7, -28
	l32e	a6, a7, -24
	l32e	a7, a7, -20
	rfwu

	.align	64
_WindowOverflow12:
	s32e	a0, a13, -16
	l32e	a0, a1, -12
	s32e	a1, a13, -12
	s32e	a2, a13, -8
	s32e	a3, a13, -4
	s32e	a4, a0, -48
	s32e	a5, a0, -44
	s32e	a6, a0, -40
	s32e	a7, a0, -36
	s32e	a8, a0, -32
	s32e	a9, a0, -28
	s32e	a10, a0, -24
	s32e	a11, a0, -20
	rfwo

	.align	64
_WindowUnderflow12:
	l32e	a0, a13, -16
	l32e	a1, a13, -12
	l32e	a2, a13, -8
	l32e	a11, a1, -12
	l32e	a3, a13, -4
	l32e	a4, a11, -48
	l32e	a5, a11, -44
	l32e	a6, a11, -40
	l32e	a7, a11, -36
	l32e	a8, a11, -32
	l32e	a9, a11, -28
	l32e	a10, a11, -24
	l32e	a11, a11, -20
	rfwu
