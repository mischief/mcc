/* SPDX-License-Identifier: ISC */
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

/* The layout is the compiler's: va_start reaches into it by member
 * name, and a header that never includes this one may still name the
 * type as __builtin_va_list. */
typedef __builtin_va_list va_list;

void *__va_next(void *ap, long size, long flt);

#define va_start(ap, last) __builtin_va_start(ap, last)
#define va_arg(ap, type)   __builtin_va_arg(ap, type)
#define va_end(ap)         ((void)0)
#define va_copy(d, s)      (*(d) = *(s))

#endif
