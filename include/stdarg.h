/*
 * Freestanding header.
 *
 * A variadic function spills its argument registers into a save area in its
 * own frame; the state below walks that area and then the caller's stack.
 * A target with a floating point register file has two save areas and two
 * counts, because the two files are consumed independently.  Only the
 * compiler knows where the areas are, and only the compiler knows which file
 * a type came in, so both va_start and va_arg are builtins.
 */
#ifndef _STDARG_H
#define _STDARG_H

typedef struct {
	long left;		/* integer argument registers still unread */
	long fleft;		/* floating point ones still unread */
	long regs;		/* how many integer ones there were */
	char *reg;		/* the next integer one in the save area */
	char *freg;		/* the next floating point one */
	char *stk;		/* the next one on the caller's stack */
} __va_state;

typedef __va_state va_list[1];

void *__va_next(__va_state *ap, long size, long flt);

#define va_start(ap, last) __builtin_va_start(ap, last)
#define va_arg(ap, type)   __builtin_va_arg(ap, type)
#define va_end(ap)         ((void)0)
#define va_copy(d, s)      (*(d) = *(s))

#endif
