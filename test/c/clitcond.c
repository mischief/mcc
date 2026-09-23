/* SPDX-License-Identifier: ISC */
/* A compound literal on the side of && or ?: that does not run is not
 * built.  Its stores went out where it was read, so linux's
 * bio_for_each_bvec read the vector past the end of a bio before the
 * test on the size said there was one. */
extern int printf(const char *, ...);

struct v { long a, b; };
static long tab[4] = {1, 2, 3, 4};
static int reads;

static long get(int i) { reads++; return tab[i]; }

long clitcond(void)
{
	volatile int no = 0, yes = 1;
	struct v x = {0, 0};
	long sum = 0, *p;
	int i;

	if (no && ((x = (struct v){ .a = get(0), .b = 5 }), 1))
		sum += 100;
	if (no && ((x = (struct v){ .a = ({ long t = get(1); t; }) }), 1))
		sum += 200;
	sum += no ? ((struct v){ get(2), 7 }).b : 3;
	p = no ? (long[]){ get(3), 2 } : 0;
	sum += p ? p[1] : 0;
	for (i = 0; i < 4 && ((x = (struct v){ .a = get(i), .b = i }), 1); i++)
		sum += x.a * 10 + x.b;
	sum += yes ? ((struct v){ get(1), 7 }).b : 3;
	sum += *&(int){ (int)get(0) + yes };
	printf("%ld %d\n", sum, reads);
	return 0;
}
