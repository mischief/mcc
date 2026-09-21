/* SPDX-License-Identifier: ISC */
/* C11 atomics, which on a single processor only have to be in order */
#include <stdatomic.h>

static atomic_ullong big;
static atomic_int n;
static _Atomic unsigned short s;
static _Atomic(long) paren;
static atomic_flag fl = ATOMIC_FLAG_INIT;

long loads(void)
{
	atomic_store_explicit(&big, 7, memory_order_release);
	return (long)atomic_load_explicit(&big, memory_order_acquire);
}

long adds(void)
{
	long a = (long)atomic_fetch_add_explicit(&big, 3,
		memory_order_relaxed);

	a = a * 1000;
	return a + (long)atomic_load(&big);
}

long swaps(void)
{
	return (long)atomic_exchange(&big, 100);
}

long signed_adds(void)
{
	long a;

	atomic_store(&n, -5);
	a = atomic_fetch_add(&n, 2);
	a = a * 1000 + atomic_load(&n) * 10;
	return a + atomic_fetch_sub(&n, 1);
}

long narrow(void)
{
	long a;

	atomic_store(&s, 60000);
	a = (long)(unsigned)atomic_fetch_add(&s, 10) * 100000;
	return a + (long)(unsigned)atomic_load(&s);
}

long compares(void)
{
	unsigned long long e = 100;
	long r = atomic_compare_exchange_strong(&big, &e, 42) ? 1 : 0;

	r = r * 1000 + (long)e;
	e = 1;
	r = r * 10 + (atomic_compare_exchange_strong(&big, &e, 7) ? 1 : 0);
	r = r * 1000 + (long)e;
	return r + (long)atomic_load(&big);
}

long flags(void)
{
	long a = atomic_flag_test_and_set(&fl) ? 1 : 0;

	a = a * 10 + (atomic_flag_test_and_set(&fl) ? 1 : 0);

	atomic_flag_clear(&fl);
	return a * 10 + (atomic_flag_test_and_set(&fl) ? 1 : 0);
}

long bits(void)
{
	long a;

	atomic_store(&n, 0xf0);
	a = atomic_fetch_or(&n, 0x0f);
	a = a * 1000 + atomic_load(&n);
	a = a * 1000 + atomic_fetch_and(&n, 0xf0);
	a = a * 1000 + atomic_load(&n);

	a = a * 10 + atomic_fetch_xor(&n, 0xff);
	a = a * 1000;
	return a + atomic_load(&n);
}

long parens(void)
{
	long a;

	atomic_store(&paren, -9);
	atomic_thread_fence(memory_order_seq_cst);
	a = atomic_load(&paren) * 10;
	return a + (atomic_is_lock_free(&big) ? 1 : 0);
}

/* The `__sync_` family, which is older than C11 atomics and is what a
 * driver written before them uses.  Each answers in the type the
 * pointer points at, and each is sequentially consistent.
 */
static int sy;
static unsigned long long sw;
static short sn;

long syncs(void)
{
	long a = 0;

	sy = 5; a = a * 100 + __sync_fetch_and_add(&sy, 3);
	a = a * 100 + sy;
	sy = 5; a = a * 100 + __sync_add_and_fetch(&sy, 3);
	sy = 5; a = a * 100 + __sync_fetch_and_sub(&sy, 2);
	sy = 5; a = a * 100 + __sync_sub_and_fetch(&sy, 2);
	sy = 0xf0; a = a * 1000 + __sync_fetch_and_or(&sy, 0x0f);
	sy = 0xff; a = a * 1000 + __sync_and_and_fetch(&sy, 0x0f);
	sy = 0xff; a = a * 1000 + __sync_fetch_and_xor(&sy, 0x0f);
	return a;
}

long syncs2(void)
{
	long a = 0;

	sy = 5; a = a * 100 + __sync_val_compare_and_swap(&sy, 5, 9);
	a = a * 100 + sy;
	sy = 5; a = a * 100 + __sync_val_compare_and_swap(&sy, 4, 9);
	sy = 5; a = a * 10 + __sync_bool_compare_and_swap(&sy, 4, 9);
	sy = 5; a = a * 10 + __sync_bool_compare_and_swap(&sy, 5, 9);
	sy = 5; a = a * 100 + __sync_lock_test_and_set(&sy, 8);
	a = a * 100 + sy;
	sy = 3; __sync_lock_release(&sy);
	a = a * 100 + sy;
	sw = 9; a = a * 100 + (long)__sync_fetch_and_add(&sw, 4ULL);
	a = a * 100 + (long)sw;
	sn = 7; a = a * 100 + __sync_fetch_and_add(&sn, 1);
	a = a * 100 + sn;
	__sync_synchronize();
	return a;
}

/* gcc names the library entry point for one of these with the width
 * of the operand on the end, and takes the same spelling as a
 * builtin.  The drm code in openbsd writes it that way:
 * `atomic64_inc_return` expands to `__sync_add_and_fetch_8`.  The
 * width there is the operand's, not the pointer's.
 */
static long long sw64;
static unsigned long long swu64;
static int sw32;
static short sw16;
static signed char sw8;

long syncwidths(void)
{
	long a = 0;

	sw64 = 10;
	a = a * 100 + (long)__sync_add_and_fetch_8(&sw64, 5);
	a = a * 100 + (long)__sync_fetch_and_add_8(&sw64, 5);
	a = a * 100 + (long)__sync_fetch_and_sub_8(&sw64, 3);
	a = a * 100 + (long)__sync_sub_and_fetch_8(&sw64, 2);
	swu64 = 0xf0f0;
	a = a * 100000 + (long)__sync_fetch_and_or_8(&swu64, 0x0f0f);
	a = a * 100000 + (long)__sync_and_and_fetch_8(&swu64, 0xff00);
	a = a * 100000 + (long)__sync_fetch_and_xor_8(&swu64, 0xffff);
	a = a * 1000 + (long)swu64;
	sw32 = 7;
	a = a * 100 + __sync_add_and_fetch_4(&sw32, 3);
	sw16 = 7;
	a = a * 100 + __sync_fetch_and_add_2(&sw16, 3);
	sw8 = 7;
	a = a * 100 + __sync_add_and_fetch_1(&sw8, 3);
	return a;
}

long syncwidths2(void)
{
	long a = 0;

	sw64 = 100;
	a = a * 10 + __sync_bool_compare_and_swap_8(&sw64, 100, 200);
	a = a * 1000 + (long)sw64;
	a = a * 1000 + (long)__sync_val_compare_and_swap_8(&sw64, 200, 300);
	a = a * 1000 + (long)sw64;
	sw64 = 0;
	a = a * 100 + (long)__sync_lock_test_and_set_8(&sw64, 42);
	a = a * 100 + (long)sw64;
	__sync_lock_release_8(&sw64);
	a = a * 100 + (long)sw64;
	return a;
}

/* An operand that is a pointer is worked on as if it were a
 * uintptr_t: the value is not scaled by what the pointer points at.
 * And the operand is read once however many times the answer needs
 * it -- a call in it runs once, and a body built where it was called
 * is built once.
 */
static int syarr[16];
static int *syp;
static int sycalls;

static int sybump(void) { sycalls++; return 2; }

long syncptrs(void)
{
	long a = 0;

	syp = syarr;
	__sync_add_and_fetch(&syp, 1);
	a = a * 100 + (long)((char *)syp - (char *)syarr);
	syp = syarr;
	__sync_fetch_and_add(&syp, 4);
	a = a * 100 + (long)((char *)syp - (char *)syarr);
	syp = syarr + 4;
	__sync_sub_and_fetch(&syp, 8);
	a = a * 100 + (long)((char *)syp - (char *)syarr);
	syp = syarr;
	a = a * 100 + (long)((char *)__sync_add_and_fetch(&syp, 3) -
			     (char *)syarr);
	return a;
}

long synconce(void)
{
	long a = 0;

	sy = 10; sycalls = 0;
	a = a * 100 + __sync_add_and_fetch(&sy, sybump());
	a = a * 10 + sycalls;
	sy = 10; sycalls = 0;
	a = a * 100 + __sync_sub_and_fetch(&sy, sybump());
	a = a * 10 + sycalls;
	sy = 10; sycalls = 0;
	a = a * 100 + __sync_or_and_fetch(&sy, sybump());
	a = a * 10 + sycalls;
	sy = 10; sycalls = 0;
	a = a * 100 + __sync_nand_and_fetch(&sy, sybump());
	a = a * 10 + sycalls;
	return a;
}

/* The `__atomic` family, which is what gcc says to write instead of
 * `__sync`: the memory order is an argument, and the forms without
 * `_n` carry the value by address.
 */
static int av; static long long aw; static short ah; static signed char ac;
static int *app; static int aarr[16];
static int acalls;

static int abump(void) { acalls++; return 2; }

long atomics1(void)
{
	long a = 0;
	int e, x;

	av = 5;
	a = a * 100 + __atomic_load_n(&av, __ATOMIC_SEQ_CST);
	__atomic_store_n(&av, 9, __ATOMIC_RELEASE);
	a = a * 100 + av;
	a = a * 100 + __atomic_exchange_n(&av, 11, __ATOMIC_ACQ_REL);
	a = a * 100 + av;
	e = 11;
	a = a * 10 + __atomic_compare_exchange_n(&av, &e, 20, 0,
		__ATOMIC_SEQ_CST, __ATOMIC_RELAXED);
	a = a * 100 + e;
	a = a * 100 + av;
	e = 11;
	a = a * 10 + __atomic_compare_exchange_n(&av, &e, 30, 0,
		__ATOMIC_SEQ_CST, __ATOMIC_RELAXED);
	a = a * 100 + e;
	av = 77;
	__atomic_load(&av, &x, __ATOMIC_SEQ_CST);
	a = a * 100 + x;
	x = 88;
	__atomic_store(&av, &x, __ATOMIC_SEQ_CST);
	a = a * 100 + av;
	x = 99;
	__atomic_exchange(&av, &x, &e, __ATOMIC_SEQ_CST);
	a = a * 100 + e;
	a = a * 100 + av;
	e = 99; x = 111;
	a = a * 10 + __atomic_compare_exchange(&av, &e, &x, 0,
		__ATOMIC_SEQ_CST, __ATOMIC_RELAXED);
	a = a * 1000 + av;
	return a;
}

long atomics2(void)
{
	long a = 0;
	long long b;
	int e;

	av = 10;
	a = a * 100 + __atomic_fetch_add(&av, 3, __ATOMIC_SEQ_CST);
	a = a * 100 + __atomic_add_fetch(&av, 3, __ATOMIC_SEQ_CST);
	a = a * 100 + __atomic_fetch_sub(&av, 2, __ATOMIC_SEQ_CST);
	a = a * 100 + __atomic_sub_fetch(&av, 2, __ATOMIC_SEQ_CST);
	av = 0xf0;
	a = a * 1000 + __atomic_fetch_or(&av, 0x0f, __ATOMIC_SEQ_CST);
	a = a * 1000 + __atomic_and_fetch(&av, 0x3c, __ATOMIC_SEQ_CST);
	a = a * 1000 + __atomic_fetch_xor(&av, 0xff, __ATOMIC_SEQ_CST);
	a = a * 1000 + (__atomic_nand_fetch(&av, 0x0f, __ATOMIC_SEQ_CST) & 0xff);
	aw = 1LL << 40;
	b = __atomic_fetch_add(&aw, 7, __ATOMIC_SEQ_CST);
	a = a * 10 + (long)(aw - b);
	ah = 300;
	e = (int)__atomic_add_fetch(&ah, 5, __ATOMIC_SEQ_CST);
	a = a * 1000 + e;
	a = a * 1000 + (int)ah;
	ac = 7;
	e = (int)__atomic_fetch_add(&ac, 5, __ATOMIC_SEQ_CST);
	a = a * 100 + e;
	a = a * 100 + (int)ac;
	return a;
}

long atomics3(void)
{
	long a = 0;
	int e;

	app = aarr;
	__atomic_fetch_add(&app, 4, __ATOMIC_SEQ_CST);
	a = a * 100 + (long)((char *)app - (char *)aarr);
	app = aarr;
	__atomic_add_fetch(&app, 1, __ATOMIC_SEQ_CST);
	a = a * 100 + (long)((char *)app - (char *)aarr);
	av = 0;
	a = a * 10 + __atomic_test_and_set(&av, __ATOMIC_SEQ_CST);
	a = a * 10 + (av != 0);
	a = a * 10 + __atomic_test_and_set(&av, __ATOMIC_SEQ_CST);
	__atomic_clear(&av, __ATOMIC_SEQ_CST);
	a = a * 10 + av;
	__atomic_thread_fence(__ATOMIC_SEQ_CST);
	__atomic_signal_fence(__ATOMIC_SEQ_CST);
	a = a * 10 + __atomic_always_lock_free(1, 0);
	a = a * 10 + __atomic_always_lock_free(2, 0);
	a = a * 10 + __atomic_always_lock_free(4, 0);
	a = a * 10 + __atomic_always_lock_free(8, 0);
	a = a * 10 + __atomic_always_lock_free(16, 0);
	av = 10; acalls = 0;
	e = __atomic_add_fetch(&av, abump(), __ATOMIC_SEQ_CST);
	a = a * 100 + e;
	a = a * 10 + acalls;
	return a;
}
