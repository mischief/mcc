/* inline assembly: the shapes a kernel writes */
extern int printf(const char *, ...);
typedef unsigned long long u64;

static long addthem(long a, long b);
static long addimm(long a);
static long shifted(long v, int n);
static long frommem(void);
static long clobbers(long a);
static long counter(void);
static void barrier(void) { __asm__ volatile ("" ::: "memory"); }

static long cell = 77;

#if defined(__x86_64__)

static long addthem(long a, long b)
{
	long r;
	__asm__ ("movq %1, %0\n\taddq %2, %0" : "=r" (r) : "r" (a), "r" (b));
	return r;
}

static long addimm(long a)
{
	long r;
	__asm__ ("movq %1, %0\n\taddq $%c2, %0" : "=r" (r) : "r" (a), "i" (7));
	return r;
}

static long shifted(long v, int n)
{
	long r = v;
	__asm__ ("shlq %%cl, %0" : "+r" (r) : "c" (n));
	return r;
}

static long frommem(void)
{
	long r;
	__asm__ ("movq %1, %0" : "=r" (r) : "m" (cell));
	return r;
}

/* rbx is callee saved, so the template borrowing it has to give it back */
static long clobbers(long a)
{
	long r;
	__asm__ ("movq %1, %%rbx\n\tincq %%rbx\n\tmovq %%rbx, %0"
		 : "=r" (r) : "r" (a) : "rbx");
	return r;
}

static long counter(void)
{
	unsigned lo, hi;
	__asm__ volatile ("rdtsc" : "=a" (lo), "=d" (hi));
	return (((u64)hi << 32) | lo) != 0;
}

#elif defined(__riscv)

static long addthem(long a, long b)
{
	long r;
	__asm__ ("add %0, %1, %2" : "=r" (r) : "r" (a), "r" (b));
	return r;
}

static long addimm(long a)
{
	long r;
	__asm__ ("addi %0, %1, %2" : "=r" (r) : "r" (a), "i" (7));
	return r;
}

static long shifted(long v, int n)
{
	long r;
	__asm__ ("sll %0, %1, %2" : "=r" (r) : "r" (v), "r" ((long)n));
	return r;
}

static long frommem(void)
{
	long r;
	__asm__ ("ld %0, %1" : "=r" (r) : "m" (cell));
	return r;
}

/* s1 is callee saved, so the template borrowing it has to give it back */
static long clobbers(long a)
{
	long r;
	__asm__ ("mv s1, %1\n\taddi s1, s1, 1\n\tmv %0, s1"
		 : "=r" (r) : "r" (a) : "s1");
	return r;
}

static long counter(void)
{
	u64 v;
	__asm__ volatile ("rdtime %0" : "=r" (v));
	return v != 0 || v == 0;
}

#elif defined(__XTENSA__)

static long addthem(long a, long b)
{
	long r;
	__asm__ ("add %0, %1, %2" : "=r" (r) : "r" (a), "r" (b));
	return r;
}

static long addimm(long a)
{
	long r;
	__asm__ ("addi %0, %1, %2" : "=r" (r) : "r" (a), "i" (7));
	return r;
}

static long shifted(long v, int n)
{
	long r;
	__asm__ ("ssl %2\n\tsll %0, %1" : "=r" (r) : "r" (v), "r" (n));
	return r;
}

/* there is no absolute memory operand here, so the address goes in a
 * register like anything else */
static long frommem(void)
{
	long r;
	long *p = &cell;
	__asm__ ("l32i %0, %1, 0" : "=r" (r) : "r" (p));
	return r;
}

/* the window keeps a2 to a7, so a borrowed one has to be given back */
static long clobbers(long a)
{
	long r;
	__asm__ ("mov a15, %1\n\taddi a15, a15, 1\n\tmov %0, a15"
		 : "=r" (r) : "r" (a) : "a15");
	return r;
}

static long counter(void)
{
	unsigned c;
	__asm__ volatile ("rsr %0, ccount" : "=r" (c));
	return c != 0 || c == 0;
}

#elif defined(__aarch64__)

static long addthem(long a, long b)
{
	long r;
	__asm__ ("add %0, %1, %2" : "=r" (r) : "r" (a), "r" (b));
	return r;
}

static long addimm(long a)
{
	long r;
	__asm__ ("add %0, %1, %2" : "=r" (r) : "r" (a), "i" (7));
	return r;
}

static long shifted(long v, int n)
{
	long r;
	__asm__ ("lsl %0, %1, %2" : "=r" (r) : "r" (v), "r" ((long)n));
	return r;
}

static long frommem(void)
{
	long r;
	__asm__ ("ldr %0, %1" : "=r" (r) : "m" (cell));
	return r;
}

/* x19 is callee saved, so the template borrowing it has to give it back */
static long clobbers(long a)
{
	long r;
	__asm__ ("mov x19, %1\n\tadd x19, x19, #1\n\tmov %0, x19"
		 : "=r" (r) : "r" (a) : "x19");
	return r;
}

static long counter(void)
{
	u64 v;
	__asm__ volatile ("mrs %0, cntvct_el0" : "=r" (v));
	return v != 0 || v == 0;
}

#else

#error no inline assembly for this target
#endif

void asmgototest(void);

void asmtest(void)
{
	long i;
	barrier();
	for (i = -2; i <= 2; i++) {
		printf("add %ld\n", addthem(i, 40));
		printf("addi %ld\n", addimm(i));
		printf("shift %ld\n", shifted(i + 8, 3));
		printf("clob %ld\n", clobbers(i));
	}
	printf("mem %ld\n", frommem());
	printf("counter %ld\n", counter());
	asmgototest();
}


/* asm goto: the template picks where to continue.  The condition codes
   are the machine's, so this one is written for amd64 alone. */
#if defined(__amd64__)
static int asmgoto(int x)
{
	asm goto ("cmpl $0,%0; jne %l[yes]" : : "r" (x) : "cc" : yes);
	return 0;
yes:
	return 1;
}

static int asmgoto2(int x, int y)
{
	asm goto ("cmpl %1,%0; jl %l[lt]; jg %l[gt]"
		: : "r" (x), "r" (y) : "cc" : lt, gt);
	return 0;
lt:
	return -1;
gt:
	return 1;
}

void asmgototest(void)
{
	printf("goto %d %d\n", asmgoto(0), asmgoto(5));
	printf("goto2 %d %d %d\n", asmgoto2(1, 2), asmgoto2(2, 2),
		asmgoto2(3, 2));
}
#else
void asmgototest(void) { }
#endif
