/* SPDX-License-Identifier: ISC */
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

struct E { double _Complex z[0]; };
struct R { int v[9]; };
struct Q { int v[7] __attribute__((aligned(16))); };
struct H { int v[300]; };

unsigned cplx(int, unsigned long long, double _Complex, int);
unsigned fcplx(int, float _Complex, int);
unsigned empty(struct Q, int, struct E, int);
unsigned vcplx(int, ...);
unsigned far(struct H, int, int, int, int, int, int, struct R, int);
unsigned vfar(int, ...);
unsigned many(long long, long long, long long, long long, long long,
	      long long, long long, long long, long long, long long,
	      long long, long long, long long, long long);
unsigned callgcc(int);

static unsigned bits(const void *p, int n)
{
	const unsigned char *c = p;
	unsigned h = 0;

	while (n-- > 0)
		h = h * 31 + *c++;
	return h;
}

unsigned gcplx(int a, unsigned long long b, double _Complex c, int d)
{
	return a + (unsigned)b * 3 + bits(&c, sizeof c) * 5 + d * 7;
}

unsigned gempty(struct Q a, int b, struct E c, int d)
{
	return bits(&a, sizeof a.v) + b * 3 + d * 5;
}

unsigned gvcplx(int n, ...)
{
	va_list ap;
	unsigned t = 0;

	va_start(ap, n);
	while (n-- > 0) {
		double d = va_arg(ap, double);
		double _Complex z = va_arg(ap, double _Complex);

		t = t * 7 + bits(&d, sizeof d) + bits(&z, sizeof z) * 3;
	}
	va_end(ap);
	return t;
}

unsigned gmany(long long a, long long b, long long c, long long d,
	       long long e, long long f, long long g, long long h,
	       long long i, long long j, long long k, long long l,
	       long long m, long long n)
{
	return (unsigned)(a + b * 3 + c * 5 + d * 7 + e + f * 3 + g * 5 +
			  h * 7 + i + j * 3 + k * 5 + l * 7 + m + n * 3);
}

int main(void)
{
	double _Complex z;
	float _Complex f;
	struct R r = {{1, 2, 3, 4, 5, 6, 7, 8, 9}};
	struct E e;
	struct Q q = {{1, 2, 3, 4, 5, 6, 7}};
	static struct H h;
	unsigned long long w = 0x4000000000000001ULL;

	memcpy(&z, &w, 8);
	memcpy((char *)&z + 8, &r, 8);
	memcpy(&f, &r, 8);
	printf("cplx %u\n", cplx(1, 2, z, 3));
	printf("fcplx %u\n", fcplx(1, f, 2));
	printf("empty %u\n", empty(q, 4, e, 5));
	printf("vcplx %u\n", vcplx(2, 1.0, z, 2.0, z));
	h.v[299] = 11;
	printf("far %u\n", far(h, 1, 2, 3, 4, 5, 6, r, 7));
	printf("vfar %u\n", vfar(9, 1, 2, 3, 4, 5, 6, 7, 8, 9));
	printf("many %u\n", many(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13,
				  14));
	printf("callgcc %u\n", callgcc(3));
	return 0;
}
