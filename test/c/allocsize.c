#include <stdio.h>
/* alloca gives back at least what was asked for.  Rounding the size
 * up is what makes the block big enough; the mask that follows keeps
 * the stack aligned, and the two are different jobs.  Two blocks of
 * the same size must not overlap, whatever the size is modulo the
 * alignment.
 */
static volatile int keep;
static int worst = 1 << 30;

static void two(int n)
{
	char *a = __builtin_alloca((unsigned)n);
	char *b = __builtin_alloca((unsigned)n);
	long gap;
	int i;

	for (i = 0; i < n; i++) a[i] = (char)(i + 1);
	for (i = 0; i < n; i++) b[i] = (char)~(i + 1);
	for (i = 0; i < n; i++) keep += a[i] == (char)(i + 1);
	gap = a - b;
	if (gap < 0) gap = -gap;
	if (gap - n < worst) worst = (int)(gap - n);
}

int main(void)
{
	int n;

	for (n = 1; n <= 48; n++) two(n);
	printf("slack %d\n", worst >= 0 ? 0 : worst);
	return 0;
}
