/* SPDX-License-Identifier: ISC */
/* The stack protector's runtime, for a program that has no library to
   take it from.  A system that does have one -- OpenBSD's libc and its
   kernel both do -- keeps its own, and this file is left out. */

#include <stdio.h>

/* The value the prologue copies onto the frame.  On OpenBSD the loader
   randomises anything in this section before the program runs. */
long __guard_local __attribute__((section(".openbsd.randomdata")));

void __stack_smash_handler(char func[], int damaged);

void
__stack_smash_handler(char func[], int damaged)
{
	(void)damaged;
	printf("stack overflow in %s\n", func ? func : "?");
	__builtin_trap();
}
