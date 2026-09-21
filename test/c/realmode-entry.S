	.code16gcc
	.section .text.entry, "ax"
	.globl _start16
_start16:
	cli
	xorw	%ax, %ax
	movw	%ax, %ds
	movw	%ax, %es
	movw	%ax, %ss
	movl	$0x7000, %esp
	call	main16
1:	hlt
	jmp	1b
