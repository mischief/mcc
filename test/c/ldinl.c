/* SPDX-License-Identifier: ISC */
/* A long double constant through a body built where it is called: the
   return and the argument each keep the constant's whole value. */

static long double one(void) { return 1.5L; }
static long double same(long double x) { return x; }
static long double twice(long double x) { return x + x; }

double ldret(void) { return (double)one(); }
double ldarg(void) { return (double)same(2.25L); }
double ldsum(void) { return (double)twice(-3.5L); }

void ldeff(void)
{
	one() / 0;
}
