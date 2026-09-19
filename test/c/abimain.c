/* SPDX-License-Identifier: ISC */
#include <stdio.h>

double dadd(double, double);
float fmix(float, float, float);
double many(double, long, double, double, double, double, double, double,
	    double, double, long, double);
double vsum(long, ...);
double vmix(long, ...);
double callback(double (*)(double, double), double, double);
double libm(double);

static double mul(double a, double b)
{
	return a * b;
}

#if defined(__x86_64__)
#define MSABI __attribute__((ms_abi))
#else
#define MSABI
#endif

double mscall(double (MSABI *)(int, double, int, double),
	      int, double, int, double);
long mswide(long (MSABI *)(long, long, long, long, long, long),
	    long, long, long, long, long, long);

static double MSABI msmix(int a, double b, int c, double d)
{
	return a + b * 10.0 + c * 100.0 + d * 1000.0;
}

static long MSABI mssix(long a, long b, long c, long d, long e, long f)
{
	return ((((a * 10 + b) * 10 + c) * 10 + d) * 10 + e) * 10 + f;
}

/* Narrow answers, with the whole argument left behind above them. */
unsigned short narrowu(long v) { return (unsigned short)v; }
short narrows(long v) { return (short)v; }
unsigned char narrowb(long v) { return (unsigned char)v; }
signed char narrowc(long v) { return (signed char)v; }

long narrowcall(int, long);

int main(void)
{
	long i;

	for (i = -3; i <= 3; i++) {
		printf("dadd %.6f\n", dadd((double)i, 0.5));
		printf("fmix %.6f\n", (double)fmix((float)i, 2.5f, 0.25f));
		printf("callback %.6f\n", callback(mul, (double)i, 1.5));
	}
	printf("many %.6f\n",
	       many(1.5, 2, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5, 9.5, 10.5, 11, 12.5));
	printf("vsum0 %.6f\n", vsum(0));
	printf("vsum3 %.6f\n", vsum(3, 1.5, 2.25, 3.125));
	printf("vsum9 %.6f\n", vsum(9, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0,
				   8.0, 9.0));
	printf("vmix %.6f\n", vmix(3, 1L, 2.0, 3L, 4.0, 5L, 6.0));
	for (i = 1; i <= 4; i++)
		printf("libm %.6f\n", libm((double)i));
	printf("mscall %.6f\n", mscall(msmix, 1, 2.5, 3, 4.5));
	printf("mswide %ld\n", mswide(mssix, 1, 2, 3, 4, 5, 6));
	for (i = 0; i <= 6; i++)
		printf("narrowcall %ld %ld %ld\n", i,
		       narrowcall((int)i, 0x7f8a03L),
		       narrowcall((int)i, -0x7f8a03L));
	return 0;
}
