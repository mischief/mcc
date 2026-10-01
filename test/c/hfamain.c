/* SPDX-License-Identifier: ISC */
#include <stdio.h>
#include <stdarg.h>

struct D4 { double a, b, c, d; };
struct C2 { double _Complex z[2]; };
union UD { double _Complex a; double _Complex b; };
union U1 { double a; double b; };
struct F3 { float a, b, c; };

double h(struct D4, struct C2, union UD, union U1, struct F3, int);
struct D4 r4(double);
double callgcc(int);

double gh(struct D4 a, struct C2 b, union UD c, union U1 d, struct F3 e,
	  int k)
{
	return a.a + a.d * 10 + ((double *)&b.z[1])[1] * 100 +
	       ((double *)&c.a)[1] * 1000 + d.a * 10000 + e.c * 100000 +
	       k * 1000000;
}

double gv(int n, ...)
{
	va_list ap;
	struct F3 e;
	struct D4 a;

	va_start(ap, n);
	e = va_arg(ap, struct F3);
	a = va_arg(ap, struct D4);
	va_end(ap);
	return e.a + e.c * 10 + a.b * 100 + a.d * 1000;
}

int main(void)
{
	struct D4 a = {1, 2, 3, 4};
	struct C2 b;
	union UD c;
	union U1 d = {5};
	struct F3 e = {6, 7, 8};
	int k;

	((double *)&c.a)[0] = 9;
	((double *)&c.a)[1] = 10;
	for (k = 1; k < 3; k++) {
		struct D4 r = r4(k);

		((double *)&b.z[1])[1] = k;
		printf("h %.1f\n", h(a, b, c, d, e, k));
		printf("r4 %.1f %.1f\n", r.a, r.d);
		printf("callgcc %.1f\n", callgcc(k));
	}
	return 0;
}
