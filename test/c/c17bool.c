/* SPDX-License-Identifier: ISC */
/* Postfix ++ and -- on a _Bool (C17 6.5.2.4) are the compound
 * assignments += 1 and -= 1, and so leave 0 or 1 behind. */
struct s { _Bool f : 1; _Bool g; };

int c17bool(int i)
{
	_Bool b = i & 1, c = 0, *p = &c;
	struct s s = {i & 1, i & 1};
	int r;

	switch (i >> 1) {
	case 0: r = b++; return r * 10 + b;
	case 1: r = b--; return r * 10 + b;
	case 2: r = ++b; return r * 10 + b;
	case 3: r = --b; return r * 10 + b;
	case 4: s.f++; s.g++; return s.f * 10 + s.g;
	case 5: s.f--; s.g--; return s.f * 10 + s.g;
	case 6: c = b; (*p)--; return c;
	default: c = b; (*p)++; return c;
	}
}
