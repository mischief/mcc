/* SPDX-License-Identifier: ISC */
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

#define BARRIER() __asm__ volatile ("" : : : "memory")

#if defined(__amd64__) || defined(__x86_64__)

u64 __mcc_atomic_load(const volatile void *p, int w, int order)
{
	(void)order;
	switch (w) {
	case 1: return *(const volatile unsigned char *)p;
	case 2: return *(const volatile unsigned short *)p;
	case 4: return *(const volatile unsigned int *)p;
	default: return *(const volatile u64 *)p;
	}
}

void __mcc_atomic_store(volatile void *p, u64 v, int w, int order)
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

u64 __mcc_atomic_exchange(volatile void *p, u64 v, int w, int order)
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

u64 __mcc_atomic_fetch_add(volatile void *p, u64 v, int w, int order)
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
int __mcc_atomic_cas(volatile void *p, void *want, u64 desired, int w,
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

void __mcc_atomic_fence(int order)
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

u64 __mcc_atomic_load(const volatile void *p, int w, int order)
{
	u64 v;

	(void)order;
	BARRIER();
	v = load(p, w);
	BARRIER();
	return v;
}

void __mcc_atomic_store(volatile void *p, u64 v, int w, int order)
{
	(void)order;
	BARRIER();
	store(p, v, w);
	BARRIER();
}

u64 __mcc_atomic_exchange(volatile void *p, u64 v, int w, int order)
{
	u64 old;

	(void)order;
	BARRIER();
	old = load(p, w);
	store(p, v, w);
	BARRIER();
	return old;
}

u64 __mcc_atomic_fetch_add(volatile void *p, u64 v, int w, int order)
{
	u64 old;

	(void)order;
	BARRIER();
	old = load(p, w);
	store(p, old + v, w);
	BARRIER();
	return old;
}

int __mcc_atomic_cas(volatile void *p, void *want, u64 desired, int w,
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

void __mcc_atomic_fence(int order)
{
	(void)order;
	BARRIER();
}

#endif
