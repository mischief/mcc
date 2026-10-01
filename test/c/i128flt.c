/* SPDX-License-Identifier: ISC */
/* A 128-bit integer to and from every float type, rounded once. */

#if defined(__SIZEOF_INT128__)
typedef __int128 s128;
typedef unsigned __int128 u128;

double s2d(s128 x) { return x; }
float u2f(u128 x) { return x; }
double u2d(u128 x) { return x; }
s128 d2s(double x) { return x; }
u128 f2u(float x) { return x; }
s128 f2s(float x) { return x; }
double ks2d(void) { return (double)(((s128)1 << 100) + ((s128)1 << 47) + 1); }
float ks2f(void) { return (float)-(((s128)1 << 100) + ((s128)1 << 76) + 1); }
static s128 kd2s = -1e30;
s128 kfix(void) { return kd2s; }
#if defined(__x86_64__)
long double s2x(s128 x) { return x; }
long double u2x(u128 x) { return x; }
s128 x2s(long double x) { return x; }
u128 x2u(long double x) { return x; }
long double ks2x(void)
{
	return (long double)(((s128)1 << 100) + ((s128)1 << 36) + 1);
}
#endif
#endif
