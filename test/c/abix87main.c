/* SPDX-License-Identifier: ISC */
#include <stdio.h>

struct L { long double x; };
union U { long double a; long double b; };
struct M { long double x; long k; };

long double cpart(int, long double _Complex, int);
long double lrec(int, struct L, union U, struct M, int);
struct L lret(long double);
union U uret(long double);
long callgcc(int);

struct L mkl(long double v)
{
	struct L l = {v * 3};

	return l;
}

long double getl(int a, struct L l, int b, union U u, struct M m)
{
	return a * l.x + b + u.b + m.x * m.k;
}

int main(void)
{
	long double _Complex z;
	struct L l = {2.5L};
	union U u = {0.75L};
	struct M m = {1.25L, 3};
	int k;

	((long double *)&z)[0] = 1.5L;
	((long double *)&z)[1] = -4.0L;
	for (k = 1; k < 4; k++) {
		printf("cpart %d %ld\n", k, (long)(cpart(k, z, 5) * 8));
		printf("lrec %d %ld\n", k, (long)(lrec(k, l, u, m, 9) * 8));
		printf("lret %d %ld\n", k, (long)(lret(k + 0.5L).x * 8));
		printf("uret %d %ld\n", k, (long)(uret(k + 0.5L).b * 8));
		printf("callgcc %d %ld\n", k, callgcc(k));
	}
	return 0;
}
