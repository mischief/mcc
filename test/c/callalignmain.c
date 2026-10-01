/* SPDX-License-Identifier: ISC */
#include <stdio.h>
#include <stdint.h>

int bare(void);
float conv(void);
float viart(void);
volatile int seed = 3;
static int misaligned;

/* gcc takes the call boundary as given on entry, so it does not move
   an aligned local onto one: a caller that missed shows here. */
#define CHECK() do { \
	char v[16] __attribute__((aligned(16))); \
	char *volatile p = v; \
	if ((uintptr_t)p % 16 != 0) misaligned++; \
} while (0)

int probe(int x)
{
	CHECK();
	return x * 2;
}

float tofloat(int x)
{
	CHECK();
	return (float)x / 2;
}

int main(void)
{
	printf("bare %d\n", bare());
	printf("conv %g\n", conv());
	printf("viart %g\n", viart());
	printf("misaligned %d\n", misaligned);
	return 0;
}
