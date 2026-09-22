/* SPDX-License-Identifier: ISC */
/* A divide whose divisor is itself worked out while the registers are
 * short: the divisor waits on the stack, and the template pops it.  The
 * divide also destroys rax and rdx, and a value live in one is saved
 * around it -- underneath the waiting divisor, or the pop takes the save
 * and divides by that.  linux's poll() estimates its slack this way and
 * died of it. */
extern int printf(const char *, ...);

struct ts { long sec; long nsec; };
struct task { char pad[112]; int prio; };
static struct task *cur;

__attribute__((noinline)) static long est(struct ts *tv)
{
	long slack;
	int divfactor = 1000;

	if (tv->sec < 0)
		return 0;
	if (cur->prio - 120 > 0)
		divfactor = divfactor / 5;
	if (tv->sec > 100000000L / (1000000000L / divfactor))
		return 100000000L;
	slack = tv->nsec / divfactor;
	slack += tv->sec * (1000000000L / divfactor);
	if (slack > 100000000L)
		return 100000000L;
	return slack;
}

__attribute__((noinline)) static long nest(long a, long b, long c, int d)
{
	return a > b / (c / d) ? a % (b / (c % 97 + 1)) : (b % (c / d)) - a;
}

__attribute__((noinline)) static unsigned unest(unsigned a, unsigned b,
	unsigned c, unsigned d)
{
	return (a < b / (c / d)) + a * (b % (c / d + 1)) + (a / (b / d + 1));
}

__attribute__((noinline)) static int inest(int a, int b, int c, int d)
{
	return a - b / (c / d) + (a % (c / (d + 1) + 1)) * (b / (a | 1));
}

long divpress(void)
{
	struct task t = { .prio = 120 };
	struct ts tv = { 0, 50000 }, tv2 = { 3, 77777 };
	long sum = 0;
	int i;

	cur = &t;
	printf("est %ld %ld\n", est(&tv), est(&tv2));
	t.prio = 130;
	printf("est %ld %ld\n", est(&tv), est(&tv2));
	for (i = 1; i < 40; i++) {
		sum += nest(i * 7, 1000003L * i, 99991L + i, i % 5 + 1);
		sum += unest(i * 13u, 4000037u + i, 7919u * i, i % 7 + 1);
		sum += inest(i * 3, 90001 + i, 777 + i * 11, i % 3 + 1);
	}
	printf("sum %ld\n", sum);
	return sum;
}
