/* SPDX-License-Identifier: ISC */
/* An array of no elements keeps a record out of the float registers:
   gcc takes no AAPCS64 HFA and no RISC-V float pair from it, whatever
   the element type. */

struct A { char z[0]; double d[3]; };
struct B { double z[0]; double d[3]; };
struct C { float z[0]; double d[2]; };
struct F { char z[0]; float f[2]; };
struct G { struct { int z[0]; } s; double d; };
struct H { int z[0]; double d; };
struct I { int z[0]; double _Complex c; };
struct J { double d; char z[]; };
struct K { int z[0]; float a; float b; };

long gzero(struct A, struct B, struct C, struct F, struct G, double);

long zero(struct A a, struct B b, struct C c, struct F f, struct G g,
	  double x)
{
	return (long)a.d[0] + (long)a.d[2] * 10 + (long)b.d[1] * 100 +
	       (long)c.d[0] * 1000 + (long)c.d[1] * 10000 +
	       (long)f.f[1] * 100000 + (long)g.d * 1000000 +
	       (long)x * 10000000;
}

long callgcc(long k)
{
	struct A a = {.d = {1, 2, 3}};
	struct B b = {.d = {4, 5, 6}};
	struct C c = {.d = {7, 8}};
	struct F f = {.f = {9, 1}};
	struct G g = {.d = 2};

	a.d[0] = k;
	return gzero(a, b, c, f, g, 3);
}

/* On RISC-V gcc still sends a record to the float file when one float
   or complex member fills it, but not with a flexible array. */
long gzero2(struct H, struct I, struct J, struct K, int);

long zero2(struct H h, struct I i, struct J j, struct K k, int x)
{
	return (long)h.d + (long)__real__ i.c * 10 +
	       (long)__imag__ i.c * 100 + (long)j.d * 1000 +
	       (long)k.a * 10000 + (long)k.b * 100000 + x * 1000000L;
}

long callgcc2(long n)
{
	struct H h = {.d = 1};
	struct I i = {.c = 2 + 3 * __extension__ 1.0iF};
	struct J j = {4};
	struct K k = {.a = 5, .b = 6};

	h.d = n;
	return gzero2(h, i, j, k, 7);
}
