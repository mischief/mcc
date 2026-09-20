/* SPDX-License-Identifier: ISC */
	.text
	.align 4
f:
	entry	a1,176
	retw
	ret
	nop
	add	a2,a3,a4
	sub	a5,a6,a7
	and	a2,a3,a4
	or	a2,a3,a4
	xor	a2,a3,a4
	neg	a2,a3
	mov	a2,a3
	mull	a2,a3,a4
	quou	a2,a3,a4
	quos	a2,a3,a4
	remu	a2,a3,a4
	rems	a2,a3,a4
	sll	a2,a3
	srl	a2,a4
	sra	a2,a4
	ssr	a5
	ssl	a5
	slli	a2,a3,1
	slli	a2,a3,31
	srli	a2,a3,0
	srli	a2,a3,15
	srai	a2,a3,0
	srai	a2,a3,31
	sext	a2,a3,7
	sext	a2,a3,22
	extui	a2,a3,0,8
	extui	a2,a3,16,16
	l32i	a2,a1,0
	l32i	a2,a1,1020
	s32i	a2,a1,64
	l8ui	a2,a3,255
	s8i	a2,a3,7
	l16ui	a2,a3,510
	l16si	a2,a3,2
	s16i	a2,a3,4
	addi	a2,a3,-128
	addi	a2,a3,127
	movi	a2,0
	movi	a2,-2048
	movi	a2,2047
	callx8	a3
	.align	4
lit:
	.long	0x12345678
g:
	l32r	a2,lit
	beq	a2,a3,g
	bne	a2,a3,g
	blt	a2,a3,g
	bge	a2,a3,g
	bltu	a2,a3,g
	bgeu	a2,a3,g
	beqz	a2,g
	bnez	a2,g
	j	g
	call8	g
