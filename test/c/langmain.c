/* SPDX-License-Identifier: ISC */
int replaced(void) { return 2; }
void lang(void);

/* Nothing comes back from this one, and lang.c says so.  Nothing calls
 * it either: what is being tested is what the compiler does with the
 * code after a call to it. */
void langdie(int v);
void langdie(int v) { while (v >= 0) { } }

int main(void) { lang(); return 0; }

#include <stdarg.h>

/* The last named parameter has its address taken by the expansion,
 * and the tokens say only `va_start(ap, last)`.
 */
long pinvsum(long last, ...)
{
	va_list ap;
	long i, a = last;

	va_start(ap, last);
	for (i = 0; i < 4; i++)
		a += va_arg(ap, long) + last + i;
	va_end(ap);
	return a + last;
}
