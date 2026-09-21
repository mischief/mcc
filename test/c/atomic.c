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
