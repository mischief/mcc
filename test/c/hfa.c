/* SPDX-License-Identifier: ISC */
/* A record of up to four floats of one type, however wide, is a
   homogeneous float aggregate on arm64: it travels in vector
   registers, named or variadic, and a union of them counts too. */

struct D4 { double a, b, c, d; };
struct C2 { double _Complex z[2]; };
union UD { double _Complex a; double _Complex b; };
union U1 { double a; double b; };
struct F3 { float a, b, c; };

double gh(struct D4, struct C2, union UD, union U1, struct F3, int);
double gv(int, ...);

double h(struct D4 a, struct C2 b, union UD c, union U1 d, struct F3 e,
	 int k)
{
	return a.a + a.d * 10 + ((double *)&b.z[1])[1] * 100 +
	       ((double *)&c.a)[1] * 1000 + d.a * 10000 + e.c * 100000 +
	       k * 1000000;
}

struct D4 r4(double x)
{
	struct D4 a = {x, x + 1, x + 2, x + 3};

	return a;
}

double callgcc(int k)
{
	struct D4 a = {1, 2, 3, 4};
	struct C2 b;
	union UD c;
	union U1 d = {5};
	struct F3 e = {6, 7, 8};

	((double *)&b.z[1])[1] = k;
	((double *)&c.a)[0] = 9;
	((double *)&c.a)[1] = 10;
	return gh(a, b, c, d, e, k) + gv(2, e, a);
}
