/* Sector zero: set up a flat-ish real mode, load the rest, jump to C. */
	.code16
	.section .boot, "ax"
	.globl _boot
_boot:
	cli
	xorw	%ax, %ax
	movw	%ax, %ds
	movw	%ax, %es
	movw	%ax, %ss
	movw	$0x7c00, %sp
	sti
	/* read SECTORS sectors starting at LBA 1 to 0x7e00 */
	movw	$0x7e00, %bx
	movb	$0x02, %ah
	movb	$32, %al
	movb	$0, %ch
	movb	$2, %cl
	movb	$0, %dh
	movb	$0x00, %dl
	int	$0x13
	jc	fail
	ljmp	$0, $0x7e00
fail:
	movw	$0x3f8, %dx
	movb	$'E', %al
	outb	%al, %dx
1:	hlt
	jmp	1b
	.org	510
	.byte	0x55, 0xaa
