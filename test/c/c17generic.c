/* SPDX-License-Identifier: ISC */
/* _Generic (C17 6.5.1.1) takes the association whose type is compatible
 * with the controlling one.  char, signed char and unsigned char are
 * three types; function types compare their result and parameters; an
 * array of unknown bound matches any bound. */
static int f(int x) { return x; }
static void g(void) {}

int c17generic(int i)
{
	char c = 0;
	signed char sc = 0;
	unsigned char uc = 0;
	int a[3];

	switch (i) {
	case 0: return _Generic(c, signed char: 1, char: 2, unsigned char: 3);
	case 1: return _Generic(sc, char: 2, signed char: 1, unsigned char: 3);
	case 2: return _Generic(uc, char: 2, signed char: 1, default: 3);
	case 3: return _Generic(&c, signed char *: 1, char *: 2, default: 3);
	case 4: return _Generic(f, void (*)(void): 1, int (*)(int): 2);
	case 5: return _Generic(g, int (*)(int): 2, void (*)(void): 1);
	case 6: return _Generic(f, int (*)(double): 1, int (*)(int, int): 2,
		default: 3);
	case 7: return _Generic(&a, int (*)[4]: 1, int (*)[3]: 2);
	case 8: return __builtin_types_compatible_p(char, signed char) * 10 +
		__builtin_types_compatible_p(int[], int[3]);
	default: return __builtin_types_compatible_p(int (*)(int),
		int (*)(char));
	}
}
