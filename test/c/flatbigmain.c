/* SPDX-License-Identifier: ISC */
#include <stdio.h>
#include <stdarg.h>

struct P { char c; float f __attribute__((aligned(16))); };

long big(struct P, int);
long full(float, float, float, float, float, float, float, float,
	  struct P, int);
long vbig(int, ...);
struct P ret(int);
long callgcc(long);

long gbig(struct P a, int b)
{
	return a.c * 100 + (long)a.f * 10 + b;
}

long gfull(float f0, float f1, float f2, float f3, float f4, float f5,
	   float f6, float f7, struct P a, int b)
{
	a.c++;
	return (long)(f0 + f1 + f2 + f3 + f4 + f5 + f6 + f7) * 1000 +
	       a.c * 100 + (long)a.f * 10 + b;
}

struct P gret(int k)
{
	struct P p = {(char)k, 2.0f * k};

	return p;
}

int main(void)
{
	struct P a = {1, 2}, b = {3, 4};
	struct P r;
	long k;

	for (k = 1; k < 3; k++) {
		a.c = (char)k;
		r = ret((int)k + 1);
		printf("big %ld\n", big(a, 5));
		printf("full %ld\n", full(1, 2, 3, 4, 5, 6, 7, 8, a, 9));
		printf("after %d\n", a.c);
		printf("vbig %ld\n", vbig(3, a, b, a));
		printf("ret %d %g\n", r.c, r.f);
		printf("callgcc %ld\n", callgcc(k));
	}
	return 0;
}
