/* SPDX-License-Identifier: ISC */
#include <stdio.h>

struct A { _Alignas(16) long a; long b; };
struct B { struct A x; long c[3]; };
struct E { };

long locals(long), one(long), two(long), three(long);
long four(long), five(long), six(long), seven(long), eight(long);

/* Only a 64-bit target promises a sixteen-byte aligned frame here. */
void seen(const char *what, const void *p)
{
	if (sizeof(void *) == 8)
		printf("%s %d\n", what, (int)((unsigned long)p & 15));
}

/* Built to use aligned stores to the result. */
__attribute__((optimize("O2"))) struct B mkb(long k)
{
	struct B b = {{k, k}, {k, k, k * 2}};

	return b;
}

__attribute__((optimize("O2")))
struct B mke(float _Complex z, float _Complex y, struct E a, struct E b, struct E c)
{
	struct B r = {{(long)((float *)&z)[0], 2}, {3, 4, 5}};

	return r;
}

int main(void)
{
	long k;

	for (k = 1; k < 3; k++)
	{
		printf("locals %ld %ld\n", k, locals(k));
		printf("one %ld %ld\n", k, one(k));
		printf("two %ld %ld\n", k, two(k));
		printf("three %ld %ld\n", k, three(k));
		printf("four %ld %ld\n", k, four(k));
		printf("five %ld %ld\n", k, five(k));
		printf("six %ld %ld\n", k, six(k));
		printf("seven %ld %ld\n", k, seven(k));
		printf("eight %ld %ld\n", k, eight(k));
	}
	return 0;
}
