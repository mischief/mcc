/* SPDX-License-Identifier: ISC */
/* __builtin_classify_type answers gcc's class for the argument's type
 * and does not evaluate it.  OpenBSD's libpthread regress picks a
 * printf format with it, and without it every test failed to link. */
extern int printf(const char *, ...);

struct s { int a; };
union u { int a; };
enum e { A };
static int calls;
static int f(void) { return ++calls; }

long ctype(void)
{
	char c = 0; long l = 0; double d = 0; _Bool b = 0; enum e x = A;
	int *p = 0, arr[3];
	struct s st = {0};
	union u un = {0};

	printf("%d %d %d %d %d %d %d %d %d\n",
	       __builtin_classify_type(0), __builtin_classify_type(""),
	       __builtin_classify_type('x'), __builtin_classify_type(c),
	       __builtin_classify_type(l), __builtin_classify_type(d),
	       __builtin_classify_type(b), __builtin_classify_type(x),
	       __builtin_classify_type(p));
	printf("%d %d %d %d %d\n", __builtin_classify_type(st),
	       __builtin_classify_type(un), __builtin_classify_type(arr),
	       __builtin_classify_type(f()), calls);
	return 0;
}
