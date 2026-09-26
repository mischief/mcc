/* SPDX-License-Identifier: ISC */
/* GNU builtins that must compile to code, never to a call into a
   library a program may not link: classifying a float, copysign, the
   typed overflow checks, clang's C11 atomics, the mode attribute, and
   the comparisons that stay quiet for a NaN. */
extern int printf(const char *, ...);

static void fcls(double x)
{
	float f = (float)x;

	printf("d %d%d%d%d%d%d f %d%d%d%d%d%d\n", __builtin_isnan(x),
	    __builtin_isinf(x), __builtin_isfinite(x),
	    __builtin_isinf_sign(x), !!__builtin_signbit(x),
	    __builtin_isnormal(x), __builtin_isnan(f), __builtin_isinf(f),
	    __builtin_isfinite(f), __builtin_isinf_sign(f),
	    !!__builtin_signbit(f), __builtin_isnormal(f));
}

static int calls;

static double once(double v)
{
	calls++;
	return v;
}

static void quiet(double a, double b)
{
	float f = (float)a;

	printf("cmp %d%d%d%d%d%d %d%d\n", __builtin_isgreater(a, b),
	    __builtin_isgreaterequal(a, b), __builtin_isless(a, b),
	    __builtin_islessequal(a, b), __builtin_islessgreater(a, b),
	    __builtin_isunordered(a, b), __builtin_isless(f, b),
	    __builtin_islessgreater(once(a), once(b)));
}

static void signs(double a, double b)
{
	double c = __builtin_copysign(a, b);
	float d = __builtin_copysignf((float)a, (float)b);

	printf("copysign %d %d %d %d\n", (int)(c * 10), !!__builtin_signbit(c),
	    (int)(d * 10), !!__builtin_signbit(d));
}

static void overflows(void)
{
	int r;
	long l;
	long long ll;
	unsigned u;
	unsigned long long ull;

	int o;

	o = __builtin_sadd_overflow(2147483647, 1, &r);
	printf("sadd %d %d\n", o, r);
	o = __builtin_smull_overflow(1L << 20, 1L << 20, &l);
	printf("smull %d\n", o);
	o = __builtin_uaddll_overflow(~0ULL, 2, &ull);
	printf("uaddll %d %llu\n", o, ull);
	o = __builtin_usub_overflow(1, 2, &u);
	printf("usub %d %u\n", o, u);
	o = __builtin_smulll_overflow(-3, 5, &ll);
	printf("smulll %d %lld\n", o, ll);
}

/* gcc has no __c11_atomic builtins; clang and this compiler do.  This
   compiler says it is gcc 8. */
#if defined(__clang__) || __GNUC__ < 9
#define LOAD(p) __c11_atomic_load(p, 5)
#define ADD(p, v) __c11_atomic_fetch_add(p, v, 5)
#define CAS(p, e, d) __c11_atomic_compare_exchange_strong(p, e, d, 5, 5)
#define XCHG(p, v) __c11_atomic_exchange(p, v, 5)
#define STORE(p, v) __c11_atomic_store(p, v, 5)
#else
#define LOAD(p) __atomic_load_n(p, 5)
#define ADD(p, v) __atomic_fetch_add(p, v, 5)
#define CAS(p, e, d) __atomic_compare_exchange_n(p, e, d, 0, 5, 5)
#define XCHG(p, v) __atomic_exchange_n(p, v, 5)
#define STORE(p, v) __atomic_store_n(p, v, 5)
#endif

static void atomics(void)
{
	_Atomic int a = 5;
	int e = 5;

	int x, y;

	x = ADD(&a, 3);
	printf("atomic %d %d ", x, LOAD(&a));
	x = CAS(&a, &e, 9);
	y = XCHG(&a, 1);
	printf("%d %d %d ", x, e, y);
	STORE(&a, 42);
	printf("%d\n", LOAD(&a));
}

typedef int di __attribute__((mode(DI)));
typedef unsigned qi __attribute__((__mode__(__QI__)));
typedef int word __attribute__((mode(word)));
struct moded { int a __attribute__((mode(HI))); char b; };

static float negzero[] = {-0.0, -0.0f};

/* The answer depends on the machine, and both builds run on the same
   one. */
static void cpu(void)
{
#if defined(__x86_64__)
	__builtin_cpu_init();
	printf("cpu %d %d %d %d %d\n", !!__builtin_cpu_supports("sse2"),
	    !!__builtin_cpu_supports("avx2"), !!__builtin_cpu_supports("sha"),
	    !!__builtin_cpu_supports("avx512f"),
	    !!__builtin_cpu_supports("x86-64-v2"));
#endif
}

void gnubitest(void)
{
	static const double v[] = {0.0, -0.0, 1.5, -2.0, 1e-310, 1e300,
	    -1e300};
	int i;

	for (i = 0; i < 7; i++)
		fcls(v[i]);
	fcls(__builtin_inf());
	fcls(-__builtin_inf());
	fcls(__builtin_nan(""));
	quiet(1.0, 2.0);
	quiet(2.0, 1.0);
	quiet(-0.0, 0.0);
	quiet(__builtin_nan(""), 1.0);
	quiet(1.0, __builtin_inf());
	printf("calls %d\n", calls);
	signs(3.0, -0.0);
	signs(-3.0, 1.0);
	overflows();
	atomics();
	printf("mode %d %d %d %d\n", (int)sizeof(di), (int)sizeof(qi),
	    (int)sizeof(word), (int)sizeof(struct moded));
	cpu();
	printf("negzero %d %d\n", !!__builtin_signbit(negzero[0]),
	    !!__builtin_signbit(negzero[1]));
}
