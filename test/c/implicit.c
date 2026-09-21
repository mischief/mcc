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

long implicits(void)
{
	long a = widths();

	printf("implicit %ld %ld\n", a, assigned());
	return a;
}
