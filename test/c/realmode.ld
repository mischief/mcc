ENTRY(_boot)
SECTIONS
{
	. = 0x7c00;
	.boot : { *(.boot) }
	. = 0x7e00;
	.text : { *(.text*) }
	.rodata : { *(.rodata*) }
	.data : { *(.data*) }
	.bss : { *(.bss*) *(COMMON) }
	_end = .;
}
