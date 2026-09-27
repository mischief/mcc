/* SPDX-License-Identifier: ISC */
/* alloca in a call argument, the way gdb writes it:
 * strcpy (alloca (n), s).  The block has to be taken before the call
 * starts to put its arguments on the stack. */
static int calls;

static char *
copy(char *d, const char *s)
{
	char *p = d;

	while ((*p++ = *s++) != 0)
		;
	return d;
}

static int
size(int n)
{
	calls++;
	return n;
}

static int
len3(const char *a, const char *b, const char *c)
{
	int n = 0;

	while (*a++) n++;
	while (*b++) n++;
	while (*c++) n++;
	return n;
}

int
allocarg(int k)
{
	int i, t = 0;

	for (i = 0; i < k; i++)
		t += len3(copy(__builtin_alloca(size(4)), "one"),
		    copy(__builtin_alloca(size(8)),
		    copy(__builtin_alloca(8), "seven")), "xy");
	return t * 100 + calls;
}
