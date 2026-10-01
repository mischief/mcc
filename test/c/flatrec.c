/* SPDX-License-Identifier: ISC */
/* Which small records RISC-V hands over in float registers: a float
   beside an integer does, but a float beside a pointer, and a union,
   travel as integers. */

struct FP { float f; void *p; };
struct FL { float f; long l; };
union UD { double d; };
union UI { int i; double d; };
struct DF { double d; float f; };

long gflat(struct FP, struct FL, union UD, union UI, struct DF, double);

long flat(struct FP a, struct FL b, union UD c, union UI d, struct DF e,
	  double x)
{
	return (long)a.f + (long)a.p * 10 + (long)b.f * 100 + b.l * 1000 +
	       (long)c.d * 10000 + d.i * 100000L + (long)e.d * 1000000L +
	       (long)e.f * 10000000L + (long)x * 100000000L;
}

long callgcc(long k)
{
	struct FP a = {1, (void *)2};
	struct FL b = {3, 4};
	union UD c = {5};
	union UI d = {6};
	struct DF e = {7, 8};

	a.f = k;
	return gflat(a, b, c, d, e, 9);
}
