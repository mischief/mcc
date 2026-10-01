/* SPDX-License-Identifier: ISC */
/* Character constants (C17 6.4.4.4).  u'' has the type char16_t and U''
 * char32_t, L'' wchar_t; a plain constant of several characters is an
 * int with the bytes in order from the top, as gcc makes it. */
#define WIDE U'\xffffffff'
#define MULTI '\xff\x01\x02\x03'

#if 'ab' == 24930 && 'u' - 'v' < 0 && U'\xffffffff' > 0
int c17pp = 1;
#else
int c17pp = 0;
#endif

int c17sizes(int i)
{
	switch (i) {
	case 0: return sizeof(u'x');
	case 1: return sizeof(U'x');
	case 2: return sizeof(L'x');
	default: return sizeof('x');
	}
}

long long c17chr(int i)
{
	switch (i) {
	case 0: return 'ab';
	case 1: return 'abcd';
	case 2: return '\0a';
	case 3: return MULTI;
	case 4: return WIDE;
	case 5: return u'\x12345';
	case 6: return u'\xffff' * -1;
	case 7: return U'\xffffffff' > 0;
	case 8: return 'a"';
	case 9: return '\\\'';
	default: return c17pp;
	}
}
