/* SPDX-License-Identifier: ISC */
/* A body with no frame of its own still calls with the stack aligned. */

extern volatile int seed;
int probe(int);
float tofloat(int);

int bare(void)
{
	return probe(seed) + 1;
}

float conv(void)
{
	return tofloat(seed);
}

float viart(void)
{
	return (float)seed;
}
