/* SPDX-License-Identifier: ISC */
/* `__attribute__((cleanup(f)))` calls f with the object's address when
 * the scope ends, however it ends.  The address is the compiler's to
 * take: nothing in the program writes an `&`, which is what makes this
 * different from any other way an object escapes.
 *
 * linux leans on it hard -- `__free(kfree)`, `guard(mutex)`, the whole
 * cleanup.h family -- so the order, the early exits and the loop cases
 * all have to be right, not just the straight one.
 */
extern int printf(const char *, ...);

static char trail[256];
static int ntrail;

static void say(char c)
{
	if (ntrail < (int)sizeof trail - 1)
		trail[ntrail++] = c;
}

static void mark(int *p) { say((char)('0' + *p)); }
static void markl(long *p) { say((char)('a' + (*p & 15))); }

struct box { int a; int b; };

static void markbox(struct box *b) { say((char)('A' + b->a)); }

static int *gptr;

static void markptr(int **p) { say(*p == gptr ? 'P' : 'p'); }

/* The plain case: one object, one scope. */
static void plain(void)
{
	int x __attribute__((cleanup(mark))) = 1;

	say('[');
	(void)x;
	say(']');
}

/* Several in one scope come back in the reverse of the order they
 * were declared, which is what C++ does and what gcc does here.
 */
static void several(void)
{
	int a __attribute__((cleanup(mark))) = 1;
	int b __attribute__((cleanup(mark))) = 2;
	int c __attribute__((cleanup(mark))) = 3;

	say('[');
	(void)a; (void)b; (void)c;
	say(']');
}

/* A bare nested block is a scope, so what it holds is finished at its
 * closing brace and not at the end of the function.  The marks say
 * which: `[{1}2]` is the scope, `[{}12]` would be the function.
 */
static void nested(void)
{
	int a __attribute__((cleanup(mark))) = 2;

	say('[');
	{
		int b __attribute__((cleanup(mark))) = 1;

		say('{');
		(void)b;
	}
	say('}');
	(void)a;
	say(']');
}

/* Several scopes in one function, one after the other, each with its
 * own.  Each is finished where it ends, so the marks interleave with
 * the body rather than piling up at the return.
 */
static void manyscopes(void)
{
	int outer __attribute__((cleanup(mark))) = 9;

	say('[');
	{
		int a __attribute__((cleanup(mark))) = 1;
		int b __attribute__((cleanup(mark))) = 2;

		say('A');
		(void)a; (void)b;
	}
	say('-');
	{
		int c __attribute__((cleanup(mark))) = 3;

		say('B');
		(void)c;
	}
	say('-');
	{
		{
			int d __attribute__((cleanup(mark))) = 4;

			say('C');
			(void)d;
		}
		say('.');
	}
	(void)outer;
	say(']');
}

/* A return from inside runs them on the way out. */
static int early(int n)
{
	int a __attribute__((cleanup(mark))) = 1;

	say('[');
	if (n) {
		int b __attribute__((cleanup(mark))) = 2;

		say('{');
		if (n > 1)
			return 10;
		say('}');
	}
	say(']');
	return 20;
}

/* A goto out of a scope runs what that scope held. */
static int jumpout(int n)
{
	int a __attribute__((cleanup(mark))) = 1;

	say('[');
	{
		int b __attribute__((cleanup(mark))) = 2;

		say('{');
		if (n)
			goto out;
		say('}');
	}
	say('|');
out:
	say(']');
	return n;
}

/* break and continue leave the body of a loop, so an object declared
 * in it is finished each time round.
 */
static void loops(int n)
{
	int i;

	say('[');
	for (i = 0; i < n; i++) {
		int a __attribute__((cleanup(mark))) = i;

		if (i == 1)
			continue;
		if (i == 3)
			break;
		say('.');
	}
	say(']');
}

/* The object is whatever the declaration says, including a record,
 * and the handler sees what the body last wrote.
 */
static void records(void)
{
	struct box b __attribute__((cleanup(markbox))) = {1, 2};

	say('[');
	b.a = 4;
	say(']');
}

/* A pointer: the handler is passed the address of the pointer, not
 * the pointer.  This is the shape linux frees with.
 */
static int thing;

static void pointers(void)
{
	int *p __attribute__((cleanup(markptr))) = gptr;

	say('[');
	(void)p;
	say(']');
}

/* The handler sees the value at the end, not at the start, even when
 * the object lives in a loop and is written every time round.
 */
static long counter(long n)
{
	long acc = 0;
	long i;

	for (i = 0; i < n; i++) {
		long v __attribute__((cleanup(markl))) = i * 2 + 1;

		acc += v;
	}
	return acc;
}

/* A switch is a scope, and falling out of it finishes what it held. */
static void switches(int n)
{
	say('[');
	switch (n) {
	case 1: {
		int a __attribute__((cleanup(mark))) = 1;

		say('1');
		break;
	}
	case 2: {
		int a __attribute__((cleanup(mark))) = 2;

		say('2');
		/* fall through */
	}
	default: {
		int b __attribute__((cleanup(mark))) = 9;

		say('d');
		break;
	}
	}
	say(']');
}

/* One declaration with several declarators: each gets its own. */
static void together(void)
{
	int a __attribute__((cleanup(mark))) = 1,
	    b __attribute__((cleanup(mark))) = 2;

	say('[');
	(void)a; (void)b;
	say(']');
}

static const char *run(void (*f)(void))
{
	ntrail = 0;
	f();
	trail[ntrail] = '\0';
	return trail;
}

long cleanups(void)
{
	long a = 0;

	gptr = &thing;
	printf("plain %s\n", run(plain));
	printf("several %s\n", run(several));
	printf("nested %s\n", run(nested));
	printf("manyscopes %s\n", run(manyscopes));
	ntrail = 0; a = early(0); trail[ntrail] = '\0';
	printf("early0 %ld %s\n", a, trail);
	ntrail = 0; a = early(1); trail[ntrail] = '\0';
	printf("early1 %ld %s\n", a, trail);
	ntrail = 0; a = early(2); trail[ntrail] = '\0';
	printf("early2 %ld %s\n", a, trail);
	ntrail = 0; a = jumpout(0); trail[ntrail] = '\0';
	printf("jump0 %ld %s\n", a, trail);
	ntrail = 0; a = jumpout(1); trail[ntrail] = '\0';
	printf("jump1 %ld %s\n", a, trail);
	ntrail = 0; loops(5); trail[ntrail] = '\0';
	printf("loops %s\n", trail);
	printf("records %s\n", run(records));
	printf("pointers %s\n", run(pointers));
	ntrail = 0; a = counter(4); trail[ntrail] = '\0';
	printf("counter %ld %s\n", a, trail);
	ntrail = 0; switches(1); trail[ntrail] = '\0';
	printf("switch1 %s\n", trail);
	ntrail = 0; switches(2); trail[ntrail] = '\0';
	printf("switch2 %s\n", trail);
	ntrail = 0; switches(7); trail[ntrail] = '\0';
	printf("switch7 %s\n", trail);
	printf("together %s\n", run(together));
	return a;
}
