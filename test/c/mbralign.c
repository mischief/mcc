/* SPDX-License-Identifier: ISC */
/* _Alignas on a member raises that member's alignment, and the
   record's with it. */
#include <stddef.h>

struct A { _Alignas(16) long a; long b; };
struct B { char c; _Alignas(8) char d; short e; };
struct C { char c; _Alignas(long) int i, j; };

long layout(int i)
{
	switch (i) {
	case 0: return sizeof(struct A) * 100 + _Alignof(struct A);
	case 1: return sizeof(struct B) * 100 + _Alignof(struct B);
	case 2: return offsetof(struct B, d) * 100 + offsetof(struct B, e);
	case 3: return sizeof(struct C) * 100 + _Alignof(struct C);
	case 4: return offsetof(struct C, i) * 100 + offsetof(struct C, j);
	}
	return -1;
}
