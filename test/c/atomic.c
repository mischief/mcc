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
