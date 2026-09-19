/* SPDX-License-Identifier: ISC */
/* floating point across a foreign ABI: arguments, returns, varargs */
#include <stdarg.h>

double dadd(double a, double b)
{
	return a + b;
}

float fmix(float a, float b, float c)
{
	return a * b - c;
}

/* more doubles than the argument registers hold, mixed with integers */
double many(double a, long b, double c, double d, double e, double f,
	    double g, double h, double i, double j, long k, double l)
{
	return a + (double)b + c + d + e + f + g + h + i + j + (double)k + l;
}

double vsum(long n, ...)
{
	va_list ap;
	double s;
	long i;

	va_start(ap, n);
	s = 0.0;
	for (i = 0; i < n; i++)
		s = s + va_arg(ap, double);
	va_end(ap);
	return s;
}

/* alternating classes, so both counters have to advance independently */
double vmix(long n, ...)
{
	va_list ap;
	double s;
	long i;

	va_start(ap, n);
	s = 0.0;
	for (i = 0; i < n; i++) {
		s = s + (double)va_arg(ap, long);
		s = s * va_arg(ap, double);
	}
	va_end(ap);
	return s;
}

double callback(double (*f)(double, double), double a, double b)
{
	return f(a, b);
}

double libm(double x)
{
	extern double sqrt(double);
	extern double pow(double, double);
	return sqrt(x) + pow(x, 3.0);
}

/* The Microsoft convention, which UEFI firmware speaks.  Four argument
 * registers, the integer and float files stepping together so that an
 * argument's place is its position, and thirty two bytes the caller
 * leaves below the stacked arguments.  The functions called here are
 * the system compiler's, so the two have to agree. */
#if defined(__x86_64__)
#define MSABI __attribute__((ms_abi))
#else
#define MSABI
#endif

double mscall(double (MSABI *f)(int, double, int, double),
	      int a, double b, int c, double d)
{
	return f(a, b, c, d);
}

long mswide(long (MSABI *f)(long, long, long, long, long, long),
	    long a, long b, long c, long d, long e, long g)
{
	return f(a, b, c, d, e, g);
}

/* A narrow answer from a call.  The callee owes only the low bits of
 * one, and the rest of the register is whatever was in it, so the
 * caller is the one that widens.  The callees are the system
 * compiler's and at -O0 they leave the whole argument behind in the
 * answer register, which is the dirt this is looking for. */
unsigned short narrowu(long);
short narrows(long);
unsigned char narrowb(long);
signed char narrowc(long);

long narrowcall(int which, long v)
{
	switch (which) {
	case 0: return (long)narrowu(v);
	case 1: return (long)narrows(v);
	case 2: return (long)narrowb(v);
	case 3: return (long)narrowc(v);
	case 4: return narrowu(v) + 1;
	case 5: return narrows(v) < 0;
	case 6: return (long)(narrowb(v) | 0x100);
	}
	return -1;
}
