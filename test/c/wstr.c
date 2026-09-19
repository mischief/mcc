/* wide string literals, and the builtins that ask about a float */

#ifdef __WCHAR_TYPE__
typedef __WCHAR_TYPE__ wchar;
#else
typedef int wchar;
#endif

static wchar wpad[8] = L"hi";
static wchar warr[] = L"abc";
static wchar *wptr = L"xyz";
static wchar *wempty = L"";
#ifdef __CHAR16_TYPE__
typedef __CHAR16_TYPE__ c16;
typedef __CHAR32_TYPE__ c32;
#else
typedef unsigned short c16;
typedef unsigned int c32;
#endif

static c16 u16arr[] = u"mn";
static c32 u32arr[] = U"op";
static char narrow[] = u8"q";

long sizes(void)
{
	return (long)sizeof(wpad) * 1000000 + (long)sizeof(warr) * 10000
	     + (long)sizeof(u16arr) * 100 + (long)sizeof(narrow);
}

long elems(long i)
{
	long m = 0;

	m = m + warr[i & 3] * 1000;
	m = m + wptr[i & 3] * 10;
	m = m + wpad[i & 7];
	return m + (long)*wempty;
}

long joined(void)
{
	static wchar *j = L"a" "b" L"c";

	return (long)sizeof(L"a" "b" L"c") * 1000 + j[0] * 100 + j[1] * 10
	     + j[2];
}

long locals(long i)
{
	const wchar a[] = L"hi";
	wchar b[6] = L"xyz";
	c16 c[] = u"pq";
	char n[] = "ab";
	long m;

	m = (long)sizeof a * 1000000 + (long)sizeof b * 10000
	  + (long)sizeof c * 100 + (long)sizeof n;
	return m * 100 + a[i & 2] % 100 + b[(i + 1) & 5] % 10
	     + c[i & 1] % 10 + n[i & 2] % 10;
}

long others(long i)
{
	return u16arr[i & 1] * 100 + u32arr[i & 1];
}

long classify(double x)
{
	long m = 0;

	if (__builtin_isnan(x)) m = m + 1;
	if (__builtin_isinf(x)) m = m + 2;
	if (__builtin_isfinite(x)) m = m + 4;
	if (__builtin_signbit(x)) m = m + 8;
	if (__builtin_isnormal(x)) m = m + 16;
	return m * 10 + __builtin_isinf_sign(x);
}

long classifyf(float x)
{
	long m = 0;

	if (__builtin_isnan(x)) m = m + 1;
	if (__builtin_isinf(x)) m = m + 2;
	if (__builtin_isfinite(x)) m = m + 4;
	if (__builtin_signbit(x)) m = m + 8;
	if (__builtin_isnormal(x)) m = m + 16;
	return m * 10 + __builtin_isinf_sign(x);
}

long bits(unsigned long v)
{
	return __builtin_popcount((unsigned int)v) * 1000
	     + __builtin_popcountll(v) * 10 + __builtin_parity(v);
}
