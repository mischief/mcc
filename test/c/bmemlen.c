/* SPDX-License-Identifier: ISC */
/* A builtin that becomes a library call hands its arguments over as the
 * library declares them.  memcpy's length came from a char field and was
 * read as four bytes, three of them what the stack held: OpenBSD's
 * cache_lookup copied a gigabyte and faulted while mounting root. */
extern int printf(const char *, ...);
typedef unsigned long size_t;
extern void *memcpy(void *, const void *, size_t);

struct nce { void *link[4]; char nlen; char name[31]; };

static int __attribute__((noinline)) dirty(int k)
{
	volatile unsigned char junk[256];
	int i, s = 0;

	for (i = 0; i < 256; i++)
		junk[i] = (unsigned char)(0xa5 + i + k);
	for (i = 0; i < 256; i++)
		s += junk[i];
	return s;
}

static int __attribute__((noinline)) look(long len, const char *src)
{
	struct nce n;
	int i, sum = 0;

	n.nlen = len;
	__builtin_memcpy(n.name, src, n.nlen);
	for (i = 0; i < n.nlen; i++)
		sum = sum * 31 + n.name[i];
	return sum + n.nlen;
}

long bmemlen(void)
{
	int s = dirty(1);
	int a = look(3, "devices");

	s += dirty(2);
	printf("%d %d\n", a, look(5, "console") + (s & 0));
	return 0;
}
