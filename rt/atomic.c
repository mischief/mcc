/* SPDX-License-Identifier: 0BSD */
/*
 * The operations <stdatomic.h> is written on.
 *
 * Every one takes the address, the width in bytes and a memory order,
 * so the header can hand over any integer or pointer without knowing
 * which one it is.  A width the machine has no instruction for is a
 * call that does the work plainly: the program asked for something the
 * target cannot do, and answering wrongly and quietly is worse than
 * answering slowly.
 *
 * amd64 has the instructions.  The lock prefix orders the access
 * against every other, so the memory order argument only has to keep
 * the compiler from moving things, which the barrier below does.
 *
 * Nothing here is safe against another processor on a target with no
 * implementation.  Those targets get the plain operation and the
 * compiler barrier, which is what a single processor needs.
 */

typedef unsigned long long u64;

/* A freestanding program links no runtime, so the compiler builds the
   bodies it needs into the object.  AFN is how it makes them its own. */
#ifndef AFN
#define AFN
#endif

#define BARRIER() __asm__ volatile ("" : : : "memory")

#if defined(__amd64__) || defined(__x86_64__)

AFN u64 __mcc_atomic_load(const volatile void *p, int w, int order)
{
	(void)order;
	switch (w) {
	case 1: return *(const volatile unsigned char *)p;
	case 2: return *(const volatile unsigned short *)p;
	case 4: return *(const volatile unsigned int *)p;
	default: return *(const volatile u64 *)p;
	}
}

AFN void __mcc_atomic_store(volatile void *p, u64 v, int w, int order)
{
	(void)order;
	switch (w) {
	case 1:
		__asm__ volatile ("xchgb %b0, %1"
			: "+q"(v), "+m"(*(volatile unsigned char *)p)
			: : "memory");
		break;
	case 2:
		__asm__ volatile ("xchgw %w0, %1"
			: "+r"(v), "+m"(*(volatile unsigned short *)p)
			: : "memory");
		break;
	case 4:
		__asm__ volatile ("xchgl %k0, %1"
			: "+r"(v), "+m"(*(volatile unsigned int *)p)
			: : "memory");
		break;
	default:
		__asm__ volatile ("xchgq %0, %1"
			: "+r"(v), "+m"(*(volatile u64 *)p) : : "memory");
		break;
	}
}

AFN u64 __mcc_atomic_exchange(volatile void *p, u64 v, int w, int order)
{
	(void)order;
	switch (w) {
	case 1:
		__asm__ volatile ("xchgb %b0, %1"
			: "+q"(v), "+m"(*(volatile unsigned char *)p)
			: : "memory");
		break;
	case 2:
		__asm__ volatile ("xchgw %w0, %1"
			: "+r"(v), "+m"(*(volatile unsigned short *)p)
			: : "memory");
		break;
	case 4:
		__asm__ volatile ("xchgl %k0, %1"
			: "+r"(v), "+m"(*(volatile unsigned int *)p)
			: : "memory");
		break;
	default:
		__asm__ volatile ("xchgq %0, %1"
			: "+r"(v), "+m"(*(volatile u64 *)p) : : "memory");
		break;
	}
	return v;
}

AFN u64 __mcc_atomic_fetch_add(volatile void *p, u64 v, int w, int order)
{
	(void)order;
	switch (w) {
	case 1:
		__asm__ volatile ("lock; xaddb %b0, %1"
			: "+q"(v), "+m"(*(volatile unsigned char *)p)
			: : "memory", "cc");
		return v & 0xff;
	case 2:
		__asm__ volatile ("lock; xaddw %w0, %1"
			: "+r"(v), "+m"(*(volatile unsigned short *)p)
			: : "memory", "cc");
		return v & 0xffff;
	case 4:
		__asm__ volatile ("lock; xaddl %k0, %1"
			: "+r"(v), "+m"(*(volatile unsigned int *)p)
			: : "memory", "cc");
		return v & 0xffffffffu;
	default:
		__asm__ volatile ("lock; xaddq %0, %1"
			: "+r"(v), "+m"(*(volatile u64 *)p)
			: : "memory", "cc");
		return v;
	}
}

/*
 * Compare and exchange.  `want` holds what the caller expected; on
 * failure it is written back with what was there, which is what C11
 * asks for.  The answer is whether the store happened.
 */
AFN int __mcc_atomic_cas(volatile void *p, void *want, u64 desired, int w,
		     int order)
{
	unsigned char done;
	u64 old;

	(void)order;
	switch (w) {
	case 1:
		old = *(unsigned char *)want;
		__asm__ volatile ("lock; cmpxchgb %b3, %1\n\tsete %0"
			: "=q"(done), "+m"(*(volatile unsigned char *)p),
			  "+a"(old)
			: "q"(desired) : "memory", "cc");
		if (!done) *(unsigned char *)want = (unsigned char)old;
		return done;
	case 2:
		old = *(unsigned short *)want;
		__asm__ volatile ("lock; cmpxchgw %w3, %1\n\tsete %0"
			: "=q"(done), "+m"(*(volatile unsigned short *)p),
			  "+a"(old)
			: "r"(desired) : "memory", "cc");
		if (!done) *(unsigned short *)want = (unsigned short)old;
		return done;
	case 4:
		old = *(unsigned int *)want;
		__asm__ volatile ("lock; cmpxchgl %k3, %1\n\tsete %0"
			: "=q"(done), "+m"(*(volatile unsigned int *)p),
			  "+a"(old)
			: "r"(desired) : "memory", "cc");
		if (!done) *(unsigned int *)want = (unsigned int)old;
		return done;
	default:
		old = *(u64 *)want;
		__asm__ volatile ("lock; cmpxchgq %3, %1\n\tsete %0"
			: "=q"(done), "+m"(*(volatile u64 *)p), "+a"(old)
			: "r"(desired) : "memory", "cc");
		if (!done) *(u64 *)want = old;
		return done;
	}
}

AFN void __mcc_atomic_fence(int order)
{
	(void)order;
	__asm__ volatile ("mfence" : : : "memory");
}

#else

/*
 * No instructions for this target yet: the operation happens, in order,
 * but nothing stops another processor from seeing it half done.
 */
static u64 load(const volatile void *p, int w)
{
	switch (w) {
	case 1: return *(const volatile unsigned char *)p;
	case 2: return *(const volatile unsigned short *)p;
	case 4: return *(const volatile unsigned int *)p;
	default: return *(const volatile u64 *)p;
	}
}

static void store(volatile void *p, u64 v, int w)
{
	switch (w) {
	case 1: *(volatile unsigned char *)p = (unsigned char)v; break;
	case 2: *(volatile unsigned short *)p = (unsigned short)v; break;
	case 4: *(volatile unsigned int *)p = (unsigned int)v; break;
	default: *(volatile u64 *)p = v; break;
	}
}

AFN u64 __mcc_atomic_load(const volatile void *p, int w, int order)
{
	u64 v;

	(void)order;
	BARRIER();
	v = load(p, w);
	BARRIER();
	return v;
}

AFN void __mcc_atomic_store(volatile void *p, u64 v, int w, int order)
{
	(void)order;
	BARRIER();
	store(p, v, w);
	BARRIER();
}

AFN u64 __mcc_atomic_exchange(volatile void *p, u64 v, int w, int order)
{
	u64 old;

	(void)order;
	BARRIER();
	old = load(p, w);
	store(p, v, w);
	BARRIER();
	return old;
}

AFN u64 __mcc_atomic_fetch_add(volatile void *p, u64 v, int w, int order)
{
	u64 old;

	(void)order;
	BARRIER();
	old = load(p, w);
	store(p, old + v, w);
	BARRIER();
	return old;
}

AFN int __mcc_atomic_cas(volatile void *p, void *want, u64 desired, int w,
		     int order)
{
	u64 old, exp;

	(void)order;
	BARRIER();
	old = load(p, w);
	exp = load(want, w);
	if (old != exp) {
		store(want, old, w);
		BARRIER();
		return 0;
	}
	store(p, desired, w);
	BARRIER();
	return 1;
}

AFN void __mcc_atomic_fence(int order)
{
	(void)order;
	BARRIER();
}

#endif

/*
 * And, or, exclusive or, and the negated and, which the `__sync_`
 * builtins ask for and no machine here has one instruction for at
 * every width.  A compare and exchange until it takes is what every
 * compiler runtime does with these.
 */
AFN u64 __mcc_atomic_fetch_bit(volatile void *p, u64 v, int w, int order,
			       int op)
{
	u64 old, neu;

	for (;;) {
		old = __mcc_atomic_load(p, w, order);
		switch (op) {
		case 0: neu = old & v; break;
		case 1: neu = old | v; break;
		case 2: neu = old ^ v; break;
		default: neu = ~(old & v); break;
		}
		if (__mcc_atomic_cas(p, &old, neu, w, order))
			return old;
	}
}

/*
 * The `__sync_` family under the names a compiler runtime gives them.
 * The compiler expands these where it sees the builtin; what is left
 * is a program that wrote the suffixed name itself, and libgcc
 * answers those, so this does too.  Each is sequentially consistent,
 * which is what the family promised before there was a way to ask for
 * less.
 */
#define SEQ 5

#define SYNC_WIDTH(n, T)						\
AFN T __sync_fetch_and_add_##n(volatile void *p, T v)			\
{ return (T)__mcc_atomic_fetch_add(p, (u64)v, n, SEQ); }		\
AFN T __sync_fetch_and_sub_##n(volatile void *p, T v)			\
{ return (T)__mcc_atomic_fetch_add(p, (u64)-(u64)v, n, SEQ); }		\
AFN T __sync_add_and_fetch_##n(volatile void *p, T v)			\
{ return (T)(__mcc_atomic_fetch_add(p, (u64)v, n, SEQ) + (u64)v); }	\
AFN T __sync_sub_and_fetch_##n(volatile void *p, T v)			\
{ return (T)(__mcc_atomic_fetch_add(p, (u64)-(u64)v, n, SEQ) - (u64)v); } \
AFN T __sync_fetch_and_and_##n(volatile void *p, T v)			\
{ return (T)__mcc_atomic_fetch_bit(p, (u64)v, n, SEQ, 0); }		\
AFN T __sync_fetch_and_or_##n(volatile void *p, T v)			\
{ return (T)__mcc_atomic_fetch_bit(p, (u64)v, n, SEQ, 1); }		\
AFN T __sync_fetch_and_xor_##n(volatile void *p, T v)			\
{ return (T)__mcc_atomic_fetch_bit(p, (u64)v, n, SEQ, 2); }		\
AFN T __sync_fetch_and_nand_##n(volatile void *p, T v)			\
{ return (T)__mcc_atomic_fetch_bit(p, (u64)v, n, SEQ, 3); }		\
AFN T __sync_and_and_fetch_##n(volatile void *p, T v)			\
{ return (T)(__mcc_atomic_fetch_bit(p, (u64)v, n, SEQ, 0) & (u64)v); }	\
AFN T __sync_or_and_fetch_##n(volatile void *p, T v)			\
{ return (T)(__mcc_atomic_fetch_bit(p, (u64)v, n, SEQ, 1) | (u64)v); }	\
AFN T __sync_xor_and_fetch_##n(volatile void *p, T v)			\
{ return (T)(__mcc_atomic_fetch_bit(p, (u64)v, n, SEQ, 2) ^ (u64)v); }	\
AFN T __sync_nand_and_fetch_##n(volatile void *p, T v)			\
{ return (T)~(__mcc_atomic_fetch_bit(p, (u64)v, n, SEQ, 3) & (u64)v); }	\
AFN T __sync_lock_test_and_set_##n(volatile void *p, T v)		\
{ return (T)__mcc_atomic_exchange(p, (u64)v, n, SEQ); }			\
AFN void __sync_lock_release_##n(volatile void *p)			\
{ __mcc_atomic_store(p, 0, n, SEQ); }					\
AFN T __sync_val_compare_and_swap_##n(volatile void *p, T old, T neu)	\
{									\
	T want = old;							\
									\
	__mcc_atomic_cas(p, &want, (u64)neu, n, SEQ);			\
	return want;							\
}									\
AFN int __sync_bool_compare_and_swap_##n(volatile void *p, T old, T neu) \
{									\
	T want = old;							\
									\
	return __mcc_atomic_cas(p, &want, (u64)neu, n, SEQ);		\
}

SYNC_WIDTH(1, unsigned char)
SYNC_WIDTH(2, unsigned short)
SYNC_WIDTH(4, unsigned int)
SYNC_WIDTH(8, u64)

AFN void __sync_synchronize(void) { __mcc_atomic_fence(SEQ); }
