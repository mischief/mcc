/* SPDX-License-Identifier: ISC */
#include <stdio.h>
#include <stddef.h>

long layout(int);

struct A { _Alignas(16) long a; long b; };
struct B { char c; _Alignas(8) char d; short e; };
struct C { char c; _Alignas(long) int i, j; };

int main(void)
{
	long want[] = {
		sizeof(struct A) * 100 + _Alignof(struct A),
		sizeof(struct B) * 100 + _Alignof(struct B),
		offsetof(struct B, d) * 100 + offsetof(struct B, e),
		sizeof(struct C) * 100 + _Alignof(struct C),
		offsetof(struct C, i) * 100 + offsetof(struct C, j),
	};
	int i;

	for (i = 0; i < 5; i++)
		printf("%d %ld %ld\n", i, layout(i), want[i]);
	return 0;
}
