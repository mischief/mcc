#include <stdio.h>
/* The stack is sixteen-byte aligned where a call arrives, which is
 * what -mpreferred-stack-boundary= asks for less of.  What the callee
 * sees is eight past a boundary: the call pushed a return address.
 */
static int worst;
static void note(void)
{
	unsigned long bp;

	/* Every prologue here pushes the frame pointer and then takes
	 * the stack pointer, so %rbp is the stack pointer on entry
	 * less the eight the call pushed.  The ABI wants the stack
	 * sixteen aligned where the call is made, which leaves %rbp
	 * on a boundary.
	 */
	__asm__ volatile("movq %%rbp,%0" : "=r"(bp));
	if ((int)(bp & 15) > worst)
		worst = (int)(bp & 15);
}
static void a(void) { note(); }
static void b(int x) { char pad[13]; pad[0] = (char)x; note(); (void)pad; }
static void c(int x, int y) { long long v[3]; v[0] = x + y; note(); (void)v; }
static void d(int n) { if (n) { char p[7]; p[0]=1; d(n-1); (void)p; } note(); }
static double e(double x) { note(); return x * 2; }
static void f(const char *s, ...) { note(); (void)s; }
struct big { char c[40]; };
static void g(struct big s) { note(); (void)s; }
int main(void)
{
	struct big s;
	int i;

	for (i = 0; i < 40; i++) s.c[i] = (char)i;
	a(); b(1); c(1, 2); d(4); (void)e(1.5); f("x", 1, 2, 3); g(s);
	printf("worst %d\n", worst);
	return 0;
}
