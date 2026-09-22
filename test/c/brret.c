/* SPDX-License-Identifier: ISC */
/* A body built where it was called whose returns are all constants,
 * tested by the caller.  Each return jumps to the arm it picks rather
 * than writing 0 or 1 for the test to read, which is the shape linux's
 * `if (!user_access_begin(p, n)) return` needs: objtool follows every
 * path and a join where one of them opened user access is a report.
 *
 * What has to survive: the effects between the returns, their order,
 * a return inside a statement expression, cleanups on the way out,
 * nesting, `&&`, `||`, `!`, and the same body read for its value.
 */
extern int printf(const char *, ...);

#define inl static inline __attribute__((always_inline))

static char trail[512];
static int ntrail;

static void say(char c)
{
	if (ntrail < (int)sizeof trail - 1)
		trail[ntrail++] = c;
}

inl int ok(int x)
{
	say('o');
	if (x < 0)
		return 0;
	say('k');
	return 1;
}

inl _Bool three(int x)
{
	if (x == 1)
		return 1;
	say('t');
	if (x == 2)
		return 0;
	say('T');
	return x > 100 ? 0 : 1;	/* not a constant: the slot stays */
}

inl int consts(int x)
{
	switch (x) {
	case 0: return 0;
	case 1: return 7;
	case 2: return -1;
	}
	say('c');
	return 0;
}

static void mark(int *p) { say((char)('0' + *p)); }

inl int clean(int x)
{
	int c __attribute__((cleanup(mark))) = x & 7;

	if (x > 3)
		return 1;
	say('n');
	return 0;
}

inl int inner(int x) { if (x & 1) return 1; return 0; }

inl int outer(int x)
{
	if (!inner(x))
		return 0;
	say('i');
	return inner(x >> 1) ? 1 : 0;
}

inl int stexpr(int x)
{
	int v = ({ if (x == 5) return 1; x * 2; });

	say('s');
	if (v > 6)
		return 1;
	return 0;
}

inl int stexpr0(int x)
{
	int v = ({ if (x == 5) return 0; x * 2; });

	say('z');
	if (v > 6)
		return 1;
	return 1;
}

/* After a switch.  With a default, no break out of it and every arm
 * leaving some other way, what follows is unreachable and is dropped;
 * each of these reaches what follows by one road or another, and has
 * to keep it. */
static int sw_break(int x)
{
	switch (x) {
	case 1: return 10;
	case 2: break;
	default: return 30;
	}
	say('b');
	return 20;
}

static int sw_nodefault(int x)
{
	switch (x) {
	case 1: return 10;
	case 2: return 20;
	}
	say('d');
	return 30;
}

static int sw_innerloop(int x)
{
	switch (x) {
	case 1:
		for (;;) {
			if (x++ > 4)
				break;	/* leaves the loop, not the switch */
		}
		say('l');
		return x;
	default:
		return -1;
	}
	return 99;
}

static int sw_goto(int x)
{
	switch (x) {
	case 1: goto out;
	default: return 5;
	}
out:
	say('g');
	return 6;
}

static int loop_sw(int x)
{
	int n = 0;

	for (;;) {
		switch (x & 3) {
		case 0: n += 1; break;	/* leaves the switch only */
		default: n += 2; break;
		}
		if (++x > 9)
			break;
	}
	say('L');
	return n;
}

static int run(int x)
{
	int r = 0;

	if (!ok(x)) { say('!'); r += 1; }
	if (ok(x)) say('Y');
	if (ok(x) && ok(x - 5)) say('&');
	if (ok(x) || ok(x - 50)) say('|');
	if (!!ok(x)) say('2');
	if (three(x)) say('3');
	if (!three(x)) say('4');
	if (consts(x)) say('5');
	if (!consts(x)) say('6');
	if (clean(x)) say('7');
	if (outer(x)) say('8');
	if (!outer(x)) say('9');
	if (stexpr(x)) say('S');
	if (!stexpr(x)) say('s');
	if (stexpr0(x)) say('Z');
	if (!stexpr0(x)) say('0');
	r += ok(x) * 10;
	r += consts(x) * 100;
	r += (ok(x) ? 1000 : 0);
	r += sw_break(x);
	r += sw_nodefault(x);
	r += sw_innerloop(x);
	r += sw_goto(x);
	r += loop_sw(x);
	while (ok(x) && x < 3) { say('w'); x++; }
	say(';');
	return r;
}

long brret(void)
{
	long sum = 0;
	int xs[] = {-3, -1, 0, 1, 2, 3, 4, 5, 6, 7, 11, 150};

	for (unsigned i = 0; i < sizeof xs / sizeof xs[0]; i++)
		sum = sum * 31 + run(xs[i]);
	trail[ntrail] = 0;
	printf("%s\n%ld\n", trail, sum);
	return sum;
}
