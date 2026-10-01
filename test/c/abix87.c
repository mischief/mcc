/* SPDX-License-Identifier: ISC */
/* The x87 classes of the x86-64 ABI: a long double _Complex or a
   record holding a long double goes in memory as an argument, and a
   record that is one long double comes back in st(0). */

struct L { long double x; };
union U { long double a; long double b; };
struct M { long double x; long k; };

struct L mkl(long double);
long double getl(int, struct L, int, union U, struct M);

long double cpart(int a, long double _Complex z, int b)
{
	return ((long double *)&z)[0] * a + ((long double *)&z)[1] * b;
}

long double lrec(int a, struct L l, union U u, struct M m, int b)
{
	return l.x * a + u.a + m.x * m.k + b;
}

struct L lret(long double v)
{
	struct L l = {v * 2};

	return l;
}

union U uret(long double v)
{
	union U u = {v + 1};

	return u;
}

/* The other way: gcc's callees, called from here. */
long callgcc(int k)
{
	struct L l = mkl(k + 0.25L);
	union U u = {3.5L};
	struct M m = {1.5L, k};

	return (long)(getl(k, l, 7, u, m) * 4);
}
