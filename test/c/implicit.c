/* SPDX-License-Identifier: ISC */
/* A function nobody declared answers with an int.  That is what C89
 * says, and an int is not the width of a word: the upper half of the
 * register the callee left is not part of the value, so a comparison
 * that reads all of it reads whatever happened to be there.
 *
 * IOCCC 1992/buzzard.2 turns on this and nothing else -- it has no
 * #include at all, and every library call in it is implicit.
 */
extern int printf(const char *, ...);

/* `dirty` is defined in the other file and named nowhere here, so
 * every call to it below is implicit.
 */
static long widths(void)
{
	long a = 0;

	a = a * 10 + (dirty() < 1 ? 0 : 7);
	a = a * 10 + (dirty() == 3 ? 1 : 0);
	a = a * 10 + (dirty() > 0 ? 1 : 0);
	a = a * 1000 + (int)dirty();
	return a;
}

/* The same through a variable, where the conversion is written down
 * rather than implied by a comparison.
 */
static long assigned(void)
{
	int v = dirty();
	long w = dirty();

	return (long)v * 1000 + w;
}

long oldstyle(void);

long implicits(void)
{
	long a = widths();

	printf("implicit %ld %ld\n", a, assigned());
	printf("oldstyle %ld\n", oldstyle());
	return a;
}

/* An old-style definition is not a prototype, however much the
 * declarations after the parameter list say about the types.  So the
 * count is nobody's business: a call that passes more is passing
 * more, and the extra arguments are evaluated and handed over.
 * `f(a)` and `f(int a)` are different declarations; what tells them
 * apart is whether anything in the list said a type, so a typedef
 * name in there makes it a prototype after all.
 */
typedef int myint;

int oldone(a) int a; { return a * 10; }
int oldtwo(a, b) int a; long b; { return a * 100 + (int)b; }
int oldnone() { return 7; }
int protoone(myint a) { return a * 1000; }

static int effects;

static int note(int v) { effects += v; return v; }

long oldstyle(void)
{
	long r = 0;

	effects = 0;
	r = r * 1000 + oldone(3);
	r = r * 1000 + oldone(4, note(5));
	r = r * 1000 + oldtwo(1, 2L);
	r = r * 10 + oldnone(1, 2, 3);
	r = r * 10000 + protoone(2);
	return r * 100 + effects;
}
