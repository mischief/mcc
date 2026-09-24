/* SPDX-License-Identifier: ISC */
/* Intel intrinsics, as far as this compiler goes.
 *
 * The vector types are values: they pass and return in xmm registers as
 * the ABI says, and `v[i]` reaches an element.  The integer intrinsics a
 * byte-parsing kernel uses are here, each one instruction in inline asm.
 * There is no vector arithmetic in the compiler itself, so `a + b` on two
 * vectors does not compile; the intrinsics do the arithmetic.
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


/* The element views the intrinsics work through.  A cast between two
 * vectors of one size keeps the bits.
 */
typedef char __v16qi __attribute__((vector_size(16)));
typedef short __v8hi __attribute__((vector_size(16)));
typedef int __v4si __attribute__((vector_size(16)));
typedef long long __v2di __attribute__((vector_size(16)));
typedef char __v32qi __attribute__((vector_size(32)));
typedef int __v8si __attribute__((vector_size(32)));
typedef long long __v4di __attribute__((vector_size(32)));

/* Two operands, the first also the result: `op b, a` in AT&T order. */
#define __MCC_SSE2(name, insn)						\
static __inline__ __m128i name(__m128i __a, __m128i __b)		\
{									\
	__asm__(insn " %1, %0" : "+x"(__a) : "x"(__b));			\
	return __a;							\
}

/* The VEX form: three operands, `op b, a, r`. */
#define __MCC_AVX2(name, insn)						\
static __inline__ __m256i name(__m256i __a, __m256i __b)		\
{									\
	__m256i __r;							\
									\
	__asm__(insn " %2, %1, %0" : "=x"(__r) : "x"(__a), "x"(__b));	\
	return __r;							\
}

__MCC_SSE2(_mm_and_si128, "pand")
__MCC_SSE2(_mm_andnot_si128, "pandn")
__MCC_SSE2(_mm_or_si128, "por")
__MCC_SSE2(_mm_xor_si128, "pxor")
__MCC_SSE2(_mm_cmpeq_epi8, "pcmpeqb")
__MCC_SSE2(_mm_cmpeq_epi16, "pcmpeqw")
__MCC_SSE2(_mm_cmpeq_epi32, "pcmpeqd")
__MCC_SSE2(_mm_cmpgt_epi8, "pcmpgtb")
__MCC_SSE2(_mm_add_epi8, "paddb")
__MCC_SSE2(_mm_add_epi16, "paddw")
__MCC_SSE2(_mm_add_epi32, "paddd")
__MCC_SSE2(_mm_add_epi64, "paddq")
__MCC_SSE2(_mm_adds_epu8, "paddusb")
__MCC_SSE2(_mm_adds_epu16, "paddusw")
__MCC_SSE2(_mm_sub_epi8, "psubb")
__MCC_SSE2(_mm_sub_epi16, "psubw")
__MCC_SSE2(_mm_sub_epi32, "psubd")
__MCC_SSE2(_mm_subs_epi8, "psubsb")
__MCC_SSE2(_mm_subs_epu8, "psubusb")
__MCC_SSE2(_mm_subs_epu16, "psubusw")
__MCC_SSE2(_mm_min_epu8, "pminub")
__MCC_SSE2(_mm_max_epu8, "pmaxub")
__MCC_SSE2(_mm_madd_epi16, "pmaddwd")
__MCC_SSE2(_mm_packus_epi16, "packuswb")
__MCC_SSE2(_mm_unpacklo_epi8, "punpcklbw")
__MCC_SSE2(_mm_unpackhi_epi8, "punpckhbw")
__MCC_SSE2(_mm_shuffle_epi8, "pshufb")
__MCC_SSE2(_mm_maddubs_epi16, "pmaddubsw")

__MCC_AVX2(_mm256_and_si256, "vpand")
__MCC_AVX2(_mm256_andnot_si256, "vpandn")
__MCC_AVX2(_mm256_or_si256, "vpor")
__MCC_AVX2(_mm256_xor_si256, "vpxor")
__MCC_AVX2(_mm256_cmpeq_epi8, "vpcmpeqb")
__MCC_AVX2(_mm256_add_epi8, "vpaddb")
__MCC_AVX2(_mm256_sub_epi8, "vpsubb")
__MCC_AVX2(_mm256_shuffle_epi8, "vpshufb")
__MCC_AVX2(_mm256_maddubs_epi16, "vpmaddubsw")
__MCC_AVX2(_mm256_madd_epi16, "vpmaddwd")

static __inline__ int _mm_movemask_epi8(__m128i __a)
{
	int __r;

	__asm__("pmovmskb %1, %0" : "=r"(__r) : "x"(__a));
	return __r;
}

static __inline__ int _mm256_movemask_epi8(__m256i __a)
{
	int __r;

	__asm__("vpmovmskb %1, %0" : "=r"(__r) : "x"(__a));
	return __r;
}

/* Whether a AND mask is all zero bits. */
static __inline__ int _mm_test_all_zeros(__m128i __a, __m128i __mask)
{
	int __z;

	__asm__("ptest %2, %1" : "=@ccz"(__z) : "x"(__mask), "x"(__a));
	return __z;
}

static __inline__ long long _mm_cvtsi128_si64(__m128i __a)
{
	return __a[0];
}

static __inline__ int _mm_cvtsi128_si32(__m128i __a)
{
	return ((__v4si)__a)[0];
}

static __inline__ __m128i _mm_setzero_si128(void)
{
	return (__m128i){0, 0};
}

static __inline__ __m256i _mm256_setzero_si256(void)
{
	return (__m256i){0, 0, 0, 0};
}

static __inline__ __m128i _mm_set1_epi8(char __b)
{
	__v16qi __r;

	for (int __i = 0; __i < 16; __i++)
		__r[__i] = __b;
	return (__m128i)__r;
}

static __inline__ __m128i _mm_set1_epi16(short __w)
{
	__v8hi __r;

	for (int __i = 0; __i < 8; __i++)
		__r[__i] = __w;
	return (__m128i)__r;
}

static __inline__ __m128i _mm_set1_epi32(int __i0)
{
	return (__m128i)(__v4si){__i0, __i0, __i0, __i0};
}

static __inline__ __m128i _mm_set1_epi64x(long long __q)
{
	return (__m128i){__q, __q};
}

static __inline__ __m256i _mm256_set1_epi8(char __b)
{
	__v32qi __r;

	for (int __i = 0; __i < 32; __i++)
		__r[__i] = __b;
	return (__m256i)__r;
}

static __inline__ __m256i _mm256_set1_epi32(int __i0)
{
	return (__m256i)(__v8si){__i0, __i0, __i0, __i0,
				 __i0, __i0, __i0, __i0};
}

static __inline__ __m128i _mm_setr_epi8(char __b0, char __b1, char __b2,
	char __b3, char __b4, char __b5, char __b6, char __b7, char __b8,
	char __b9, char __b10, char __b11, char __b12, char __b13,
	char __b14, char __b15)
{
	return (__m128i)(__v16qi){__b0, __b1, __b2, __b3, __b4, __b5, __b6,
		__b7, __b8, __b9, __b10, __b11, __b12, __b13, __b14, __b15};
}

static __inline__ __m128i _mm_set_epi8(char __b15, char __b14, char __b13,
	char __b12, char __b11, char __b10, char __b9, char __b8, char __b7,
	char __b6, char __b5, char __b4, char __b3, char __b2, char __b1,
	char __b0)
{
	return (__m128i)(__v16qi){__b0, __b1, __b2, __b3, __b4, __b5, __b6,
		__b7, __b8, __b9, __b10, __b11, __b12, __b13, __b14, __b15};
}

static __inline__ __m128i _mm_setr_epi16(short __w0, short __w1,
	short __w2, short __w3, short __w4, short __w5, short __w6,
	short __w7)
{
	return (__m128i)(__v8hi){__w0, __w1, __w2, __w3, __w4, __w5, __w6,
				 __w7};
}

static __inline__ __m128i _mm_set_epi32(int __i3, int __i2, int __i1,
	int __i0)
{
	return (__m128i)(__v4si){__i0, __i1, __i2, __i3};
}

static __inline__ __m128i _mm_set_epi64x(long long __q1, long long __q0)
{
	return (__m128i){__q0, __q1};
}

static __inline__ __m128i _mm_setr_epi64(__m64 __q0, __m64 __q1)
{
	__m128i __r;

	__builtin_memcpy(&__r, &__q0, 8);
	__builtin_memcpy((char *)&__r + 8, &__q1, 8);
	return __r;
}

static __inline__ __m256i _mm256_setr_epi8(char __b0, char __b1,
	char __b2, char __b3, char __b4, char __b5, char __b6, char __b7,
	char __b8, char __b9, char __b10, char __b11, char __b12,
	char __b13, char __b14, char __b15, char __b16, char __b17,
	char __b18, char __b19, char __b20, char __b21, char __b22,
	char __b23, char __b24, char __b25, char __b26, char __b27,
	char __b28, char __b29, char __b30, char __b31)
{
	return (__m256i)(__v32qi){__b0, __b1, __b2, __b3, __b4, __b5, __b6,
		__b7, __b8, __b9, __b10, __b11, __b12, __b13, __b14, __b15,
		__b16, __b17, __b18, __b19, __b20, __b21, __b22, __b23,
		__b24, __b25, __b26, __b27, __b28, __b29, __b30, __b31};
}

static __inline__ __m256i _mm256_set_epi8(char __b31, char __b30,
	char __b29, char __b28, char __b27, char __b26, char __b25,
	char __b24, char __b23, char __b22, char __b21, char __b20,
	char __b19, char __b18, char __b17, char __b16, char __b15,
	char __b14, char __b13, char __b12, char __b11, char __b10,
	char __b9, char __b8, char __b7, char __b6, char __b5, char __b4,
	char __b3, char __b2, char __b1, char __b0)
{
	return (__m256i)(__v32qi){__b0, __b1, __b2, __b3, __b4, __b5, __b6,
		__b7, __b8, __b9, __b10, __b11, __b12, __b13, __b14, __b15,
		__b16, __b17, __b18, __b19, __b20, __b21, __b22, __b23,
		__b24, __b25, __b26, __b27, __b28, __b29, __b30, __b31};
}

static __inline__ __m256i _mm256_set_epi32(int __i7, int __i6, int __i5,
	int __i4, int __i3, int __i2, int __i1, int __i0)
{
	return (__m256i)(__v8si){__i0, __i1, __i2, __i3, __i4, __i5, __i6,
				 __i7};
}

static __inline__ __m128i _mm_loadu_si128(__m128i_u const *__p)
{
	return *__p;
}

static __inline__ __m128i _mm_load_si128(__m128i const *__p)
{
	return *__p;
}

static __inline__ void _mm_storeu_si128(__m128i_u *__p, __m128i __a)
{
	*__p = __a;
}

static __inline__ void _mm_store_si128(__m128i *__p, __m128i __a)
{
	*__p = __a;
}

static __inline__ __m256i _mm256_loadu_si256(__m256i_u const *__p)
{
	return *__p;
}

static __inline__ void _mm256_storeu_si256(__m256i_u *__p, __m256i __a)
{
	*__p = __a;
}

static __inline__ __m128i _mm256_castsi256_si128(__m256i __a)
{
	__m128i __r;

	__builtin_memcpy(&__r, &__a, 16);
	return __r;
}

static __inline__ unsigned long long _mm_popcnt_u64(unsigned long long __x)
{
	return __builtin_popcountll(__x);
}

static __inline__ int _mm_popcnt_u32(unsigned int __x)
{
	return __builtin_popcount(__x);
}

/* The bit counts that answer the width for zero, as lzcnt and tzcnt
 * do where the bsr and bsf they replace leave the answer undefined.
 */
static __inline__ unsigned long long _lzcnt_u64(unsigned long long __x)
{
	return __x ? __builtin_clzll(__x) : 64;
}

static __inline__ unsigned long long _tzcnt_u64(unsigned long long __x)
{
	return __x ? __builtin_ctzll(__x) : 64;
}

static __inline__ unsigned int _lzcnt_u32(unsigned int __x)
{
	return __x ? __builtin_clz(__x) : 32;
}

static __inline__ unsigned int _tzcnt_u32(unsigned int __x)
{
	return __x ? __builtin_ctz(__x) : 32;
}

/* The forms that take a constant are macros, so that the constant is
 * one when the template sees it.
 */
#define __MCC_SHIFT(insn, a, n) __extension__({			\
	__m128i __s = (a);						\
	__asm__(insn " %1, %0" : "+x"(__s) : "i"(n));			\
	__s; })
#define __MCC_SHIFT256(insn, a, n) __extension__({			\
	__m256i __s = (a), __t;						\
	__asm__(insn " %2, %1, %0" : "=x"(__t) : "x"(__s), "i"(n));	\
	__t; })

#define _mm_srli_epi16(a, n) __MCC_SHIFT("psrlw", a, n)
#define _mm_srli_epi32(a, n) __MCC_SHIFT("psrld", a, n)
#define _mm_srli_epi64(a, n) __MCC_SHIFT("psrlq", a, n)
#define _mm_slli_epi16(a, n) __MCC_SHIFT("psllw", a, n)
#define _mm_slli_epi32(a, n) __MCC_SHIFT("pslld", a, n)
#define _mm_slli_epi64(a, n) __MCC_SHIFT("psllq", a, n)
#define _mm256_srli_epi32(a, n) __MCC_SHIFT256("vpsrld", a, n)
#define _mm256_srli_epi64(a, n) __MCC_SHIFT256("vpsrlq", a, n)

#define _MM_SHUFFLE(z, y, x, w) (((z) << 6) | ((y) << 4) | ((x) << 2) | (w))

#define _mm_shuffle_epi32(a, n) __extension__({			\
	__m128i __s = (a), __t;						\
	__asm__("pshufd %2, %1, %0" : "=x"(__t) : "x"(__s), "i"(n));	\
	__t; })

#define _mm_clmulepi64_si128(a, b, n) __extension__({			\
	__m128i __s = (a), __u = (b);					\
	__asm__("pclmulqdq %2, %1, %0" : "+x"(__s) : "x"(__u), "i"(n));	\
	__s; })

#define _mm_extract_epi8(a, n) \
	((int)(unsigned char)((__v16qi)(a))[(n) & 15])
#define _mm_extract_epi16(a, n) \
	((int)(unsigned short)((__v8hi)(a))[(n) & 7])
#define _mm_extract_epi32(a, n) (((__v4si)(a))[(n) & 3])
#define _mm_extract_epi64(a, n) (((__v2di)(a))[(n) & 1])

#define _mm256_extractf128_si256(a, n) __extension__({		\
	__m256i __s = (a);						\
	__m128i __h;							\
									\
	__builtin_memcpy(&__h, (char *)&__s + 16 * ((n) & 1), 16);	\
	__h; })
#define _mm256_extracti128_si256(a, n) _mm256_extractf128_si256(a, n)

#endif
