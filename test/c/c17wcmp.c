/* SPDX-License-Identifier: ISC */
/* A relational or equality operator answers an int (C17 6.5.8, 6.5.9),
 * also when it folds two 64-bit constants on a 32-bit target.  Passed
 * through ... the result has to take the room of an int. */
#include <stdarg.h>

static int second(int n, ...)
{
	va_list ap;
	int r;

	va_start(ap, n);
	r = va_arg(ap, int);
	r = va_arg(ap, int);
	va_end(ap);
	return r;
}

int c17wcmp(int i)
{
	switch (i) {
	case 0: return sizeof(5LL > 0);
	case 1: return sizeof(5ULL == 5);
	case 2: return sizeof(2147483648 > 0);
	case 3: return second(2, 5LL > 0, 7);
	case 4: return second(2, 2147483648 > 0, 0x80000000 > 0);
	case 5: return second(2, -1LL < 0ULL, 9);
	default: return second(2, 5LL != 5, 11);
	}
}
