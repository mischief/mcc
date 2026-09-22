/* SPDX-License-Identifier: ISC */
/* __builtin_nan is the positive quiet NaN.  0.0 / 0.0 on x86 gives the
 * negative one, and printf then wrote "-nan" for NAN. */
extern int printf(const char *, ...);

union f { float f; unsigned u; };
union d { double d; unsigned long long u; };

long nansign(void)
{
	union f a = { __builtin_nanf("") };
	union d b = { __builtin_nan("") };
	union d c = { __builtin_nanf("") };
	union f n = { -__builtin_nanf("") };

	printf("%x %llx %llx %x\n", a.u, b.u, c.u, n.u);
	printf("%d %d\n", __builtin_signbit(__builtin_nan("")) != 0,
	       __builtin_isnan(__builtin_nanf("")) != 0);
	return 0;
}
