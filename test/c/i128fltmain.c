/* SPDX-License-Identifier: ISC */
#include <stdio.h>

#if defined(__SIZEOF_INT128__)
typedef __int128 s128;
typedef unsigned __int128 u128;

double s2d(s128), u2d(u128), ks2d(void);
float u2f(u128), ks2f(void);
s128 d2s(double), f2s(float), kfix(void), kfix2(void), kfix3(void);
u128 f2u(float);

static void po(u128 x)
{
	printf("%016llx%016llx\n", (unsigned long long)(x >> 64),
	       (unsigned long long)x);
}

#if defined(__x86_64__)
long double s2x(s128), u2x(u128), ks2x(void);
s128 x2s(long double);
u128 x2u(long double);

static void ldbl(void)
{
	s128 v = ((s128)1 << 100) + ((s128)1 << 36) + 1;

	printf("%La %La %La\n", s2x(v), s2x(-v), u2x(~(u128)0));
	printf("%La %La\n", s2x(-1), ks2x());
	po((u128)x2s(-0x1.23456789abcdef02p120L));
	po(x2u(0xf.fffffffffffffffp124L));
	po(x2u(12345.9L));
}
#else
static void ldbl(void) {}
#endif

int main(void)
{
	s128 v = ((s128)1 << 100) + ((s128)1 << 47) + 1;
	s128 w = -(((s128)1 << 90) + ((s128)1 << 26) + 3);
	u128 u = ~(u128)0;
	u128 z = ((u128)1 << 127) | ((u128)1 << 63) | 1;

	printf("%a %a %a %a\n", s2d(v), s2d(w), s2d(0), s2d(-1));
	printf("%a %a %a\n", (double)u2f(u), (double)u2f(z), u2d(z));
	printf("%a %a\n", ks2d(), (double)ks2f());
	po((u128)d2s(-0x1.23456789abcdep100));
	po((u128)d2s(-5.5));
	po(f2u(0x1.fffffep127f));
	po(f2u(3.9f));
	po((u128)f2s(-0x1p126f));
	po((u128)kfix());
	po((u128)kfix2());
	po((u128)kfix3());
	ldbl();
	return 0;
}
#else
int main(void)
{
	return 0;
}
#endif
