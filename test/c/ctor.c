/* SPDX-License-Identifier: ISC */
/* __attribute__((constructor)) and destructor: the functions go in
 * .init_array and .fini_array, the ones with a priority run first and
 * lowest first, the rest in the order they are defined, and the
 * attribute may be on a declaration only.  OpenBSD's regress checks all
 * of this and mcc emitted no array entry at all. */
extern int printf(const char *, ...);

static int order[8], n;

void early(void) __attribute__((constructor));
void late(void) __attribute__((destructor));

static void __attribute__((constructor(101))) first(void)
{
	order[n++] = 1;
}

static void __attribute__((constructor)) second(void)
{
	order[n++] = 2;
}

void early(void)
{
	order[n++] = 3;
}

void late(void)
{
	printf("dtor n=%d\n", n);
}

long ctors(void)
{
	int i;

	printf("ctors ran:");
	for (i = 0; i < n; i++)
		printf(" %d", order[i]);
	printf("\n");
	return n;
}
