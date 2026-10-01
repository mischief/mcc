/* SPDX-License-Identifier: ISC */
/* The type an enumeration is compatible with (C17 6.7.2.2) is
 * implementation-defined.  gcc picks unsigned int when no value is
 * negative, int when one is, and a 64-bit type past 32 bits. */
enum e { A, B, C, D };
enum s { SA = -1, SB };
enum big { GA = 0xffffffffffLL };
struct bf { enum e e : 2; enum s f : 2; };

static enum e same(enum e x) { return x; }

long long c17enum(int i)
{
	enum e e = (enum e)-1;
	enum s s = (enum s)-1;
	struct bf v = {3, SA};

	switch (i) {
	case 0: return e > 0;
	case 1: return e / 2;
	case 2: return s > 0;
	case 3: return _Generic(e, unsigned: 1, int: 2, default: 3);
	case 4: return _Generic(s, unsigned: 1, int: 2, default: 3);
	case 5: return _Generic(A, unsigned: 1, int: 2, default: 3);
	case 6: return sizeof(enum big) * 10 + sizeof(GA);
	case 7: return v.e * 10 + v.f;
	case 8: return same(D) * -1 > 0;
	default: return (long long)e;
	}
}
