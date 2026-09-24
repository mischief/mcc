/* SPDX-License-Identifier: ISC */
/* The SSE and AVX2 integer intrinsics a byte parser uses, and vectors as
 * values: passed, returned, held in a struct, cast and subscripted.
 */
int printf(const char *, ...);
#include <immintrin.h>

struct chunks { __m128i c[2]; };

static void show(const char *what, __m128i v)
{
	unsigned char b[16];
	int i;

	_mm_storeu_si128((__m128i *)b, v);
	printf("%s", what);
	for (i = 0; i < 16; i++)
		printf(" %02x", b[i]);
	printf("\n");
}

static void show256(const char *what, __m256i v)
{
	show(what, _mm256_castsi256_si128(v));
	show(what, _mm256_extractf128_si256(v, 1));
}

static __m128i pick(int which, __m128i a, __m128i b)
{
	return which ? b : a;
}

void simd(void)
{
	static const unsigned char text[64] =
		"example.com. 3600 IN A 192.0.2.1 ; a comment\n\t\"quoted\"";
	struct chunks ch;
	__m128i a, b, dot, r;
	__m256i w, wd;
	__v16qi q;

	ch.c[0] = _mm_loadu_si128((const __m128i *)text);
	ch.c[1] = _mm_loadu_si128((const __m128i *)(text + 16));
	dot = _mm_set1_epi8('.');
	printf("dots %x %x\n",
	       _mm_movemask_epi8(_mm_cmpeq_epi8(ch.c[0], dot)),
	       _mm_movemask_epi8(_mm_cmpeq_epi8(ch.c[1], dot)));
	a = ch.c[0];
	b = ch.c[1];
	show("and", _mm_and_si128(a, b));
	show("andnot", _mm_andnot_si128(a, b));
	show("or", _mm_or_si128(a, b));
	show("xor", _mm_xor_si128(a, b));
	show("add", _mm_add_epi8(a, b));
	show("sub", _mm_sub_epi8(a, b));
	show("adds", _mm_adds_epu8(a, b));
	show("addsw", _mm_adds_epu16(a, b));
	show("subs", _mm_subs_epi8(a, b));
	show("subsu", _mm_subs_epu8(a, b));
	show("subsw", _mm_subs_epu16(a, b));
	show("shuf", _mm_shuffle_epi8(a, _mm_setr_epi8(15, 14, 13, 12, 11,
		10, 9, 8, 7, 6, 5, 4, 3, 2, 1, (char)0x80)));
	show("set", _mm_set_epi8(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13,
		14, 15, 16));
	show("maddubs", _mm_maddubs_epi16(a, _mm_set1_epi8(3)));
	show("madd", _mm_madd_epi16(a, _mm_setr_epi16(1, -2, 3, -4, 5, -6,
		7, -8)));
	show("packus", _mm_packus_epi16(a, b));
	show("srli32", _mm_srli_epi32(a, 4));
	show("srli64", _mm_srli_epi64(a, 12));
	show("pshufd", _mm_shuffle_epi32(a, _MM_SHUFFLE(0, 1, 2, 3)));
	show("clmul", _mm_clmulepi64_si128(a, b, 0x10));
	show("set32", _mm_set_epi32(1, -2, 3, -4));
	show("set64", _mm_set_epi64x(0x0102030405060708LL, -9));
	show("set1w", _mm_set1_epi16(0x1234));
	show("set1d", _mm_set1_epi32(-7));
	show("zero", _mm_setzero_si128());
	printf("scalars %llx %x %d %lld %d\n",
	       (unsigned long long)_mm_cvtsi128_si64(a),
	       _mm_cvtsi128_si32(b), _mm_extract_epi8(a, 5),
	       (long long)_mm_extract_epi64(b, 1),
	       (int)_mm_popcnt_u64(0xf0f0f0f0f0f0f0f0ULL));
	printf("counts %llu %llu %llu %llu %u %u\n", _lzcnt_u64(0),
	       _lzcnt_u64(0x00f0000000000000ULL), _tzcnt_u64(0),
	       _tzcnt_u64(0x100), _lzcnt_u32(1), _tzcnt_u32(0));
	printf("zeros %d %d\n", _mm_test_all_zeros(a, _mm_setzero_si128()),
	       _mm_test_all_zeros(a, a));
	q = (__v16qi)pick(1, a, b);
	q[3] = 'Z';
	show("pick", (__m128i)q);

	w = _mm256_loadu_si256((const __m256i *)text);
	wd = _mm256_set1_epi8('.');
	printf("wdots %x\n", _mm256_movemask_epi8(_mm256_cmpeq_epi8(w, wd)));
	show256("wand", _mm256_and_si256(w, _mm256_set1_epi32(0x5f5f5f5f)));
	show256("wandnot", _mm256_andnot_si256(w, wd));
	show256("wor", _mm256_or_si256(w, wd));
	show256("wadd", _mm256_add_epi8(w, wd));
	show256("wshuf", _mm256_shuffle_epi8(w, _mm256_setr_epi8(3, 2, 1, 0,
		7, 6, 5, 4, 11, 10, 9, 8, 15, 14, 13, 12, 0, 0, 0, 0, 1, 1, 1,
		1, 2, 2, 2, 2, 3, 3, 3, 3)));
	show256("wmaddubs", _mm256_maddubs_epi16(w, _mm256_set1_epi8(2)));
	show256("wmadd", _mm256_madd_epi16(w, _mm256_set1_epi32(0x00020001)));
	show256("wsrl", _mm256_srli_epi32(w, 3));
	show256("wsrlq", _mm256_srli_epi64(w, 9));
	show256("wset", _mm256_set_epi32(1, 2, 3, 4, 5, 6, 7, 8));
	r = _mm256_extractf128_si256(w, 1);
	show("hi", r);
	_mm256_storeu_si256((__m256i *)&ch, w);
	show("stored", ch.c[1]);
}
