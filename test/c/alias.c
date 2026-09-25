/* SPDX-License-Identifier: ISC */
/* A slot the compiler knows holds a constant stops holding it when
   something writes it: through a pointer, in a call, in a body built
   where it was called.  The known value only decides a condition, so
   each answer is read in one.  curl's serial_transfers read a flag the inlined
   create_transfer had set in a loop, and saw the value from before. */
extern int printf(const char *, ...);
extern void *memset(void *, int, unsigned long);

void aliasext(int *p);
void aliasext(int *p) { *p = 1; }

static int *keep;
struct s { int x, y; };

static void viaglobal(void) { *keep = 7; }
static void inloop(int *added)
{
	*added = 0;
	for (;;) {
		*added = 1;
		break;
	}
}
static void incall(int *added) { *added = 0; aliasext(added); }
static void inglobal(int *added) { *added = 0; keep = added; viaglobal(); }
static void sety(struct s *p) { p->y = 4; }

void aliastest(int n)
{
	int a = 5, b = 5, c = 5, d, arr[4];
	int *p = &d;
	struct s st;

	inloop(&a);
	printf("loop %s\n", a ? "set" : "stale");
	incall(&b);
	printf("call %s\n", b ? "set" : "stale");
	inglobal(&c);
	printf("global %s\n", c == 7 ? "set" : "stale");
	d = 0;
	aliasext(p);
	printf("direct call %s\n", d ? "set" : "stale");
	d = 0;
	*p = 3;
	printf("pointer %s\n", d == 3 ? "set" : "stale");
	arr[0] = 1;
	arr[n] = 2;
	printf("array %d\n", arr[0] == 1 ? arr[1] : -1);
	st.y = 0;
	sety(&st);
	printf("member %s\n", st.y == 4 ? "set" : "stale");
	d = 0;
	memset(&d, 0xff, sizeof d);
	printf("memset %s\n", d ? "set" : "stale");
}
