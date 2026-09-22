/* SPDX-License-Identifier: ISC */
/* A goto into the body of a loop nothing reaches from above.  The code
 * before the label is reached again through the loop's back edge, and
 * the test with it; both were dropped as unreachable.  linux's
 * hashlen_string jumps into its do-while that way, and /proc/self came
 * out with the length 8 and could not be found. */
extern int printf(const char *, ...);

__attribute__((noinline)) static unsigned long dw(const unsigned char *s)
{
	unsigned long len = 0, a;

	goto inside;
	do {
		len += 8;
inside:
		a = s[len];
	} while (a != 0);
	return len;
}

__attribute__((noinline)) static unsigned long wh(const unsigned char *s)
{
	unsigned long len = 0;

	goto inside;
	while (s[len] != 0) {
		len += 3;
inside:
		len += 1;
	}
	return len;
}

__attribute__((noinline)) static unsigned long fo(const unsigned char *s)
{
	unsigned long len = 0;

	goto inside;
	for (; s[len] != 0; len += 3) {
inside:
		len += 1;
	}
	return len;
}

/* the kernel's, on one byte at a time */
__attribute__((noinline)) static unsigned long hashlen(const char *name)
{
	unsigned long a = 0, x = 0, len = 0;

	goto inside;
	do {
		x = x * 31 + a;
		len += 1;
inside:
		a = (unsigned char)name[len];
	} while (a != 0);
	return x << 8 | len;
}

long gotoloop(void)
{
	unsigned char b[32] = {7, 0, 0, 0, 0, 0, 0, 0, 0};
	unsigned char c[32] = {1, 1, 1, 1, 1, 1, 1, 1, 1, 0};

	printf("do %lu %lu\n", dw(b), dw(c));
	printf("while %lu for %lu\n", wh(c), fo(c));
	printf("hash %lx %lx %lx\n", hashlen("self"), hashlen("thread-self"),
		hashlen(""));
	return 0;
}
