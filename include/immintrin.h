/* Intel intrinsics, as far as this compiler goes.
 *
 * What is here is the shape and the plain instructions: the vector
 * types at their right size and alignment, the fences, the pause and
 * the prefetch.  There are no arithmetic intrinsics -- no _mm_add_ps,
 * no _mm_shuffle_epi8 -- because there is no vector arithmetic in the
 * compiler to lower them onto.  A header that declares a __m128 in a
 * struct or a prototype compiles; code that adds two of them does not.
 *
 * Write the arithmetic as plain C over an array, or as inline asm.
 */
#ifndef _IMMINTRIN_H
#define _IMMINTRIN_H

#if !defined(__x86_64__) && !defined(__i386__)
#error "immintrin.h is for x86 targets"
#endif

typedef int __m64 __attribute__((vector_size(8)));

typedef float __m128 __attribute__((vector_size(16)));
typedef double __m128d __attribute__((vector_size(16)));
typedef long long __m128i __attribute__((vector_size(16)));

typedef float __m256 __attribute__((vector_size(32)));
typedef double __m256d __attribute__((vector_size(32)));
typedef long long __m256i __attribute__((vector_size(32)));

typedef float __m512 __attribute__((vector_size(64)));
typedef double __m512d __attribute__((vector_size(64)));
typedef long long __m512i __attribute__((vector_size(64)));

typedef unsigned char __mmask8;
typedef unsigned short __mmask16;
typedef unsigned int __mmask32;
typedef unsigned long long __mmask64;

/* The unaligned spellings.  Loading through one of these is how the
 * real header reads a vector that is not on its natural boundary.
 */
typedef float __m128_u __attribute__((vector_size(16), aligned(1)));
typedef double __m128d_u __attribute__((vector_size(16), aligned(1)));
typedef long long __m128i_u __attribute__((vector_size(16), aligned(1)));
typedef float __m256_u __attribute__((vector_size(32), aligned(1)));
typedef double __m256d_u __attribute__((vector_size(32), aligned(1)));
typedef long long __m256i_u __attribute__((vector_size(32), aligned(1)));

/* Hint to the core that this is a spin loop, so it can hand the other
 * thread on the same core its turn and leave the memory order alone.
 */
static __inline__ void _mm_pause(void)
{
	__asm__ __volatile__("pause" : : : "memory");
}

static __inline__ void _mm_lfence(void)
{
	__asm__ __volatile__("lfence" : : : "memory");
}

static __inline__ void _mm_sfence(void)
{
	__asm__ __volatile__("sfence" : : : "memory");
}

static __inline__ void _mm_mfence(void)
{
	__asm__ __volatile__("mfence" : : : "memory");
}

static __inline__ void _mm_clflush(void const *p)
{
	__asm__ __volatile__("clflush (%0)" : : "r"(p) : "memory");
}

/* The hint argument the real _mm_prefetch takes has to be a constant,
 * and each value is a different instruction.  Without that folding,
 * ask for the one every level wants and ignore the hint.
 */
#define _MM_HINT_ET0 7
#define _MM_HINT_ET1 6
#define _MM_HINT_T0 3
#define _MM_HINT_T1 2
#define _MM_HINT_T2 1
#define _MM_HINT_NTA 0

#define _mm_prefetch(p, hint) \
	__asm__ __volatile__("prefetcht0 (%0)" : : "r"((void const *)(p)))

static __inline__ unsigned long long __rdtsc(void)
{
	unsigned int lo, hi;

	__asm__ __volatile__("rdtsc" : "=a"(lo), "=d"(hi));
	return ((unsigned long long)hi << 32) | lo;
}

#endif
