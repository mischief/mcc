/* SPDX-License-Identifier: ISC */
/* A volatile local keeps its value across longjmp.  The qualifier was
 * read and dropped, so such a local sat in a register that longjmp puts
 * back, and a read of it folded to the last number written before the
 * call.  OpenBSD's lib/libc/longjmp calls through pointers. */
extern int printf(const char *, ...);
typedef long jb[64];
extern int _setjmp(long *);
extern void longjmp(long *, int) __attribute__((noreturn));

static jb buf;

static void jump(int v) { longjmp(buf, v); }

static int direct(void)
{
	volatile int n, seen;

	n = 0;
	seen = 0;
	if (_setjmp(buf) != 0)
		seen++;
	if (n < 5) {
		n += 1;
		jump(n);
	}
	return n * 100 + seen;
}

static int viaptr(void)
{
	void (*lj)(int) = jump;
	volatile int i, expect;

	expect = 0;
	i = _setjmp(buf);
	if (i != expect)
		return -1;
	if (expect < 20)
		(*lj)(expect += 2);
	return expect;
}

long volsj(void)
{
	printf("%d %d\n", direct(), viaptr());
	return 0;
}
