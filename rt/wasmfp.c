/* SPDX-License-Identifier: 0BSD */
/*
 * What a float is, for the classify builtins.  The rounding ones need
 * nothing here: wasm has an instruction for each, and the assembler
 * writes it in place of the call.
 */

typedef unsigned long long u64;
typedef unsigned int u32;

static u64 dbits(double x)
{
	union { double d; u64 u; } b;

	b.d = x;
	return b.u;
}

static u32 fbits(float x)
{
	union { float f; u32 u; } b;

	b.f = x;
	return b.u;
}

#define DINF 0xffe0000000000000ULL	/* infinity, shifted past the sign */
#define FINF 0xff000000u

int __disnan(double x) { return (dbits(x) << 1) > DINF; }
int __disinf(double x) { return (dbits(x) << 1) == DINF; }
int __disfin(double x) { return (dbits(x) << 1) < DINF; }
int __disneg(double x) { return (int)(dbits(x) >> 63); }
int __disinfs(double x) { return __disinf(x) ? (__disneg(x) ? -1 : 1) : 0; }
int __disnorm(double x)
{
	u64 e = (dbits(x) >> 52) & 0x7ff;

	return e != 0 && e != 0x7ff;
}

int __fisnan(float x) { return (fbits(x) << 1) > FINF; }
int __fisinf(float x) { return (fbits(x) << 1) == FINF; }
int __fisfin(float x) { return (fbits(x) << 1) < FINF; }
int __fisneg(float x) { return (int)(fbits(x) >> 31); }
int __fisinfs(float x) { return __fisinf(x) ? (__fisneg(x) ? -1 : 1) : 0; }
int __fisnorm(float x)
{
	u32 e = (fbits(x) >> 23) & 0xff;

	return e != 0 && e != 0xff;
}
