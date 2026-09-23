/* SPDX-License-Identifier: ISC */
/* A body built where it is called, whose one return settles to a
 * constant, still runs what that return runs.  linux's quota helpers
 * answer 0 and call inode_add_bytes on the way; the call was dropped,
 * so a tmpfs file's block count never rose and went negative on
 * unlink. */
extern int printf(const char *, ...);

static long added;

static void __attribute__((noinline)) bump(long n) { added += n; }

static inline int inner(long n, int flags)
{
	if (!(flags & 2))
		bump(n);
	return 0;
}

static inline int mid(long n) { return inner(n, 1); }
static inline int outer(long n) { return mid(n << 1); }

static int direct(long n) { int err = inner(n, 1); return err ? 5 : 0; }
static int twice(long n) { int err = mid(n); return err ? 5 : 0; }

static int jumps(long n)
{
	int err = -28;

	err = outer(n);
	if (err)
		goto out;
	return 0;
out:
	return err;
}

long inlkeep(void)
{
	int x = direct(1), y = twice(10), z = jumps(100);

	printf("%d %d %d %ld\n", x, y, z, added);
	return 0;
}
