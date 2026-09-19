/*
 * C11 atomics.
 *
 * `_Atomic` is a qualifier this compiler reads and drops: an atomic
 * object has the layout of the type under it, and every access goes
 * through the operations below rather than through a load or a store
 * the code generator wrote.  So the qualifier changes nothing and the
 * macros do all the work.
 *
 * Each operation takes the address, the width and a memory order, and
 * carries the value as an unsigned long long.  That covers every
 * integer and every pointer, which is what C11 requires of the atomic
 * types.  An atomic struct is not offered.
 */
#ifndef _STDATOMIC_H
#define _STDATOMIC_H

#include <stddef.h>
#include <stdint.h>

typedef enum {
	memory_order_relaxed,
	memory_order_consume,
	memory_order_acquire,
	memory_order_release,
	memory_order_acq_rel,
	memory_order_seq_cst
} memory_order;

unsigned long long __mcc_atomic_load(const volatile void *, int, int);
void __mcc_atomic_store(volatile void *, unsigned long long, int, int);
unsigned long long __mcc_atomic_exchange(volatile void *,
	unsigned long long, int, int);
unsigned long long __mcc_atomic_fetch_add(volatile void *,
	unsigned long long, int, int);
int __mcc_atomic_cas(volatile void *, void *, unsigned long long, int,
	int);
void __mcc_atomic_fence(int);

typedef _Atomic _Bool		atomic_bool;
typedef _Atomic char		atomic_char;
typedef _Atomic signed char	atomic_schar;
typedef _Atomic unsigned char	atomic_uchar;
typedef _Atomic short		atomic_short;
typedef _Atomic unsigned short	atomic_ushort;
typedef _Atomic int		atomic_int;
typedef _Atomic unsigned int	atomic_uint;
typedef _Atomic long		atomic_long;
typedef _Atomic unsigned long	atomic_ulong;
typedef _Atomic long long	atomic_llong;
typedef _Atomic unsigned long long atomic_ullong;
typedef _Atomic size_t		atomic_size_t;
typedef _Atomic ptrdiff_t	atomic_ptrdiff_t;
typedef _Atomic intptr_t	atomic_intptr_t;
typedef _Atomic uintptr_t	atomic_uintptr_t;
typedef _Atomic intmax_t	atomic_intmax_t;
typedef _Atomic uintmax_t	atomic_uintmax_t;
typedef _Atomic int_least8_t	atomic_int_least8_t;
typedef _Atomic uint_least8_t	atomic_uint_least8_t;
typedef _Atomic int_least16_t	atomic_int_least16_t;
typedef _Atomic uint_least16_t	atomic_uint_least16_t;
typedef _Atomic int_least32_t	atomic_int_least32_t;
typedef _Atomic uint_least32_t	atomic_uint_least32_t;
typedef _Atomic int_least64_t	atomic_int_least64_t;
typedef _Atomic uint_least64_t	atomic_uint_least64_t;
typedef _Atomic int_fast8_t	atomic_int_fast8_t;
typedef _Atomic uint_fast8_t	atomic_uint_fast8_t;
typedef _Atomic int_fast16_t	atomic_int_fast16_t;
typedef _Atomic uint_fast16_t	atomic_uint_fast16_t;
typedef _Atomic int_fast32_t	atomic_int_fast32_t;
typedef _Atomic uint_fast32_t	atomic_uint_fast32_t;
typedef _Atomic int_fast64_t	atomic_int_fast64_t;
typedef _Atomic uint_fast64_t	atomic_uint_fast64_t;
typedef _Atomic wchar_t		atomic_wchar_t;

#define ATOMIC_BOOL_LOCK_FREE		2
#define ATOMIC_CHAR_LOCK_FREE		2
#define ATOMIC_CHAR16_T_LOCK_FREE	2
#define ATOMIC_CHAR32_T_LOCK_FREE	2
#define ATOMIC_WCHAR_T_LOCK_FREE	2
#define ATOMIC_SHORT_LOCK_FREE		2
#define ATOMIC_INT_LOCK_FREE		2
#define ATOMIC_LONG_LOCK_FREE		2
#define ATOMIC_LLONG_LOCK_FREE		2
#define ATOMIC_POINTER_LOCK_FREE	2

#define ATOMIC_VAR_INIT(v)	(v)
#define atomic_init(p, v)	((void)(*(p) = (v)))
#define kill_dependency(y)	(y)

#define atomic_is_lock_free(p)	(sizeof *(p) <= sizeof(long long))

#define atomic_thread_fence(o)	__mcc_atomic_fence(o)
#define atomic_signal_fence(o)	__mcc_atomic_fence(o)

#define atomic_load_explicit(p, o) \
	((__typeof__(*(p)))__mcc_atomic_load((const volatile void *)(p), \
		(int)sizeof *(p), (int)(o)))
#define atomic_load(p)	atomic_load_explicit(p, memory_order_seq_cst)

#define atomic_store_explicit(p, v, o) \
	__mcc_atomic_store((volatile void *)(p), \
		(unsigned long long)(__typeof__(*(p)))(v), \
		(int)sizeof *(p), (int)(o))
#define atomic_store(p, v) \
	atomic_store_explicit(p, v, memory_order_seq_cst)

#define atomic_exchange_explicit(p, v, o) \
	((__typeof__(*(p)))__mcc_atomic_exchange((volatile void *)(p), \
		(unsigned long long)(__typeof__(*(p)))(v), \
		(int)sizeof *(p), (int)(o)))
#define atomic_exchange(p, v) \
	atomic_exchange_explicit(p, v, memory_order_seq_cst)

#define atomic_fetch_add_explicit(p, v, o) \
	((__typeof__(*(p)))__mcc_atomic_fetch_add((volatile void *)(p), \
		(unsigned long long)(v), (int)sizeof *(p), (int)(o)))
#define atomic_fetch_add(p, v) \
	atomic_fetch_add_explicit(p, v, memory_order_seq_cst)

#define atomic_fetch_sub_explicit(p, v, o) \
	((__typeof__(*(p)))__mcc_atomic_fetch_add((volatile void *)(p), \
		-(unsigned long long)(v), (int)sizeof *(p), (int)(o)))
#define atomic_fetch_sub(p, v) \
	atomic_fetch_sub_explicit(p, v, memory_order_seq_cst)

#define atomic_compare_exchange_strong_explicit(p, e, d, so, fo) \
	__mcc_atomic_cas((volatile void *)(p), (void *)(e), \
		(unsigned long long)(__typeof__(*(p)))(d), \
		(int)sizeof *(p), (int)(so))
#define atomic_compare_exchange_weak_explicit(p, e, d, so, fo) \
	atomic_compare_exchange_strong_explicit(p, e, d, so, fo)
#define atomic_compare_exchange_strong(p, e, d) \
	atomic_compare_exchange_strong_explicit(p, e, d, \
		memory_order_seq_cst, memory_order_seq_cst)
#define atomic_compare_exchange_weak(p, e, d) \
	atomic_compare_exchange_strong(p, e, d)

/*
 * The bitwise ones read, change and write again, which is a race with
 * anything that writes the same object between the two.  A machine
 * with the instruction should grow one; the loop below is what is
 * honest until then.
 */
#define __mcc_atomic_rmw(p, v, o, op) \
	(__extension__ ({ \
		__typeof__(*(p)) __o = atomic_load_explicit(p, o); \
		__typeof__(*(p)) __n; \
		do { \
			__n = (__typeof__(*(p)))(__o op (v)); \
		} while (!atomic_compare_exchange_strong_explicit(p, &__o, \
			__n, o, o)); \
		__o; \
	}))

#define atomic_fetch_or_explicit(p, v, o)  __mcc_atomic_rmw(p, v, o, |)
#define atomic_fetch_and_explicit(p, v, o) __mcc_atomic_rmw(p, v, o, &)
#define atomic_fetch_xor_explicit(p, v, o) __mcc_atomic_rmw(p, v, o, ^)
#define atomic_fetch_or(p, v)  atomic_fetch_or_explicit(p, v, \
	memory_order_seq_cst)
#define atomic_fetch_and(p, v) atomic_fetch_and_explicit(p, v, \
	memory_order_seq_cst)
#define atomic_fetch_xor(p, v) atomic_fetch_xor_explicit(p, v, \
	memory_order_seq_cst)

typedef struct { _Atomic _Bool __v; } atomic_flag;

#define ATOMIC_FLAG_INIT	{ 0 }
#define atomic_flag_test_and_set_explicit(p, o) \
	((_Bool)atomic_exchange_explicit(&(p)->__v, 1, o))
#define atomic_flag_test_and_set(p) \
	atomic_flag_test_and_set_explicit(p, memory_order_seq_cst)
#define atomic_flag_clear_explicit(p, o) \
	atomic_store_explicit(&(p)->__v, 0, o)
#define atomic_flag_clear(p) \
	atomic_flag_clear_explicit(p, memory_order_seq_cst)

#endif
