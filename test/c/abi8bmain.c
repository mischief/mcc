/* SPDX-License-Identifier: ISC */
#include <stdio.h>

struct Pad { _Alignas(16) char c; };
struct Pad2 { _Alignas(16) short s; char t; };

long pad(struct Pad, int, struct Pad2, long);
long vpad(int, ...);

#ifdef __SIZEOF_INT128__
union W { __int128 i; double d[2]; };

long wide(union W, double);
#endif

int main(void)
{
	struct Pad a = {3}, b = {4};
	struct Pad2 c = {5, 6};

	printf("pad %ld\n", pad(a, 7, c, 8));
	printf("vpad %ld\n", vpad(3, a, 1, b, 2, a, 3));
#ifdef __SIZEOF_INT128__
	{
		union W w;

		w.i = ((__int128)9 << 64) | 2;
		printf("wide %ld\n", wide(w, 4.0));
	}
#endif
	return 0;
}
