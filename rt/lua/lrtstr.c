/* SPDX-License-Identifier: ISC */
/*
 * The string library.  Patterns are lstrlib.c's matcher, which needs
 * nothing of the interpreter but somewhere to put an error, so it is the
 * same code and answers the same.
 */
#include "lrt.h"

#include <ctype.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BUILTIN(name) static int name(lr_Closure *self, TValue *base, \
				      int nargs)

#define uchar(c) ((unsigned char)(c))

/* a growing buffer ------------------------------------------------------ */

typedef struct {
	char *p;
	size_t n, cap;
} Buf;

static void binit(Buf *b)
{
	b->cap = 64;
	b->n = 0;
	b->p = malloc(b->cap);
}

static void baddl(Buf *b, const char *s, size_t n)
{
	if (b->n + n > b->cap) {
		while (b->n + n > b->cap)
			b->cap *= 2;
		b->p = realloc(b->p, b->cap);
	}
	memcpy(b->p + b->n, s, n);
	b->n += n;
}

static void baddc(Buf *b, int c)
{
	char ch = (char)c;

	baddl(b, &ch, 1);
}

static lr_Str *bresult(Buf *b)
{
	lr_Str *s = lr_newstr(b->p, b->n);

	free(b->p);
	return s;
}

/* arguments ------------------------------------------------------------ */

static const char *fname(lr_Closure *self)
{
	return self && self->name ? self->name : "?";
}

_Noreturn static void argerror(lr_Closure *self, int i, const char *msg)
{
	lr_error("bad argument #%d to '%s' (%s)", i + 1, fname(self), msg);
}

/* The string at base[i]; a number there is made one, in place. */
static lr_Str *checkstr(lr_Closure *self, TValue *base, int nargs, int i)
{
	if (i < nargs && base[i].tt == LR_STR)
		return base[i].v.p;
	if (i < nargs && LR_ISNUM(&base[i])) {
		TValue v;

		lr_setstr(&v, lr_tostr(&base[i]));
		lr_store(&base[i], &v);
		return base[i].v.p;
	}
	char msg[96];

	snprintf(msg, sizeof msg, "string expected, got %s",
		 i < nargs ? lr_objtypename(&base[i]) : "no value");
	argerror(self, i, msg);
}

static lr_Int posrelat(lr_Int pos, size_t len)
{
	if (pos > 0)
		return pos;
	if (pos == 0)
		return 1;
	if (pos < -(lr_Int)len)
		return 1;
	return (lr_Int)len + pos + 1;
}

static lr_Int endpos(lr_Closure *self, TValue *base, int nargs, int i,
		     lr_Int def, size_t len)
{
	lr_Int pos = lr_optint(self, base, nargs, i, def);

	if (pos > (lr_Int)len)
		return (lr_Int)len;
	if (pos >= 0)
		return pos;
	if (pos < -(lr_Int)len)
		return 0;
	return (lr_Int)len + pos + 1;
}

static int retstr(TValue *base, int nargs, lr_Str *s)
{
	TValue v;

	lr_setstr(&v, s);
	return lr_return(base, nargs, &v, 1);
}

static int retint(TValue *base, int nargs, lr_Int i)
{
	TValue v;

	LR_SETINT(&v, i);
	return lr_return(base, nargs, &v, 1);
}

static int retnil(TValue *base, int nargs)
{
	TValue v;

	LR_SETNIL(&v);
	return lr_return(base, nargs, &v, 1);
}

/* simple functions -------------------------------------------------------- */

BUILTIN(s_len)
{
	return retint(base, nargs, checkstr(self, base, nargs, 0)->len);
}

BUILTIN(s_sub)
{
	lr_Str *s = checkstr(self, base, nargs, 0);
	lr_Int i = posrelat(lr_checkint(self, base, nargs, 1), s->len);
	lr_Int j = endpos(self, base, nargs, 2, -1, s->len);

	if (i > j)
		return retstr(base, nargs, lr_newstr("", 0));
	return retstr(base, nargs, lr_newstr(s->s + i - 1, j - i + 1));
}

static int mapcase(lr_Closure *self, TValue *base, int nargs, int up)
{
	lr_Str *s = checkstr(self, base, nargs, 0);
	lr_Str *r = lr_newstr(s->s, s->len);

	for (size_t i = 0; i < r->len; i++)
		r->s[i] = (char)(up ? toupper(uchar(r->s[i]))
				    : tolower(uchar(r->s[i])));
	return retstr(base, nargs, r);
}

BUILTIN(s_upper)
{
	return mapcase(self, base, nargs, 1);
}

BUILTIN(s_lower)
{
	return mapcase(self, base, nargs, 0);
}

BUILTIN(s_reverse)
{
	lr_Str *s = checkstr(self, base, nargs, 0);
	lr_Str *r = lr_newstr(NULL, s->len);

	for (size_t i = 0; i < s->len; i++)
		r->s[i] = s->s[s->len - 1 - i];
	return retstr(base, nargs, r);
}

BUILTIN(s_rep)
{
	lr_Str *s = checkstr(self, base, nargs, 0);
	lr_Int n = lr_checkint(self, base, nargs, 1);
	lr_Str *sep = nargs > 2 && base[2].tt != LR_NIL ?
		checkstr(self, base, nargs, 2) : NULL;
	size_t sl = sep ? sep->len : 0;

	if (n <= 0)
		return retstr(base, nargs, lr_newstr("", 0));
	if ((s->len + sl) * (lr_Unsigned)n / (lr_Unsigned)n != s->len + sl ||
	    (s->len + sl) * (lr_Unsigned)n > ((size_t)1 << 31))
		lr_error("resulting string too large");
	size_t total = s->len * n + sl * (n - 1);
	lr_Str *r = lr_newstr(NULL, total);
	char *p = r->s;

	for (lr_Int i = 0; i < n; i++) {
		memcpy(p, s->s, s->len);
		p += s->len;
		if (sep && i + 1 < n) {
			memcpy(p, sep->s, sl);
			p += sl;
		}
	}
	return retstr(base, nargs, r);
}

BUILTIN(s_byte)
{
	lr_Str *s = checkstr(self, base, nargs, 0);
	lr_Int pi = posrelat(lr_optint(self, base, nargs, 1, 1), s->len);
	lr_Int pe = endpos(self, base, nargs, 2, pi, s->len);

	if (pi > pe)
		return lr_return(base, nargs, NULL, 0);
	if (pe - pi >= 1000000)
		lr_error("string slice too long");
	int n = (int)(pe - pi + 1);
	TValue *out = base + nargs;

	if (out + n >= lr_stackend)
		lr_error("string slice too long");
	for (int k = 0; k < n; k++)
		lr_setint(&out[k], uchar(s->s[pi - 1 + k]));
	lr_clear(base, nargs);
	memmove(base, out, n * sizeof(TValue));
	for (TValue *p = base + n > out ? base + n : out; p < out + n; p++)
		LR_SETNIL(p);
	return n;
}

BUILTIN(s_char)
{
	lr_Str *r = lr_newstr(NULL, nargs);

	for (int i = 0; i < nargs; i++) {
		lr_Int c = lr_checkint(self, base, nargs, i);

		if ((lr_Unsigned)c > 255)
			argerror(self, i, "value out of range");
		r->s[i] = (char)c;
	}
	return retstr(base, nargs, r);
}

/* patterns -------------------------------------------------------------- */

#define MAXCAPTURES 32
#define CAP_UNFINISHED (-1)
#define CAP_POSITION (-2)
#define L_ESC '%'
#define SPECIALS "^$*+?.([%-"
#define MAXCCALLS 200

typedef struct MatchState {
	const char *src_init, *src_end, *p_end;
	int matchdepth;
	int level;
	struct {
		const char *init;
		ptrdiff_t len;
	} capture[MAXCAPTURES];
} MatchState;

static const char *match(MatchState *ms, const char *s, const char *p);

static int check_capture(MatchState *ms, int l)
{
	l -= '1';
	if (l < 0 || l >= ms->level || ms->capture[l].len == CAP_UNFINISHED)
		lr_error("invalid capture index %%%d", l + 1);
	return l;
}

static int capture_to_close(MatchState *ms)
{
	int level = ms->level;

	for (level--; level >= 0; level--)
		if (ms->capture[level].len == CAP_UNFINISHED)
			return level;
	lr_error("invalid pattern capture");
}

static const char *classend(MatchState *ms, const char *p)
{
	switch (*p++) {
	case L_ESC:
		if (p == ms->p_end)
			lr_error("malformed pattern (ends with '%%')");
		return p + 1;
	case '[':
		if (*p == '^')
			p++;
		do {
			if (p == ms->p_end)
				lr_error("malformed pattern (missing ']')");
			if (*(p++) == L_ESC && p < ms->p_end)
				p++;
		} while (*p != ']');
		return p + 1;
	default:
		return p;
	}
}

static int match_class(int c, int cl)
{
	int res;

	switch (tolower(cl)) {
	case 'a': res = isalpha(c); break;
	case 'c': res = iscntrl(c); break;
	case 'd': res = isdigit(c); break;
	case 'g': res = isgraph(c); break;
	case 'l': res = islower(c); break;
	case 'p': res = ispunct(c); break;
	case 's': res = isspace(c); break;
	case 'u': res = isupper(c); break;
	case 'w': res = isalnum(c); break;
	case 'x': res = isxdigit(c); break;
	default: return cl == c;
	}
	if (isupper(cl))
		res = !res;
	return res;
}

static int matchbracketclass(int c, const char *p, const char *ec)
{
	int sig = 1;

	if (*(p + 1) == '^') {
		sig = 0;
		p++;
	}
	while (++p < ec) {
		if (*p == L_ESC) {
			p++;
			if (match_class(c, uchar(*p)))
				return sig;
		} else if (*(p + 1) == '-' && p + 2 < ec) {
			p += 2;
			if (uchar(*(p - 2)) <= c && c <= uchar(*p))
				return sig;
		} else if (uchar(*p) == c) {
			return sig;
		}
	}
	return !sig;
}

static int singlematch(MatchState *ms, const char *s, const char *p,
		       const char *ep)
{
	if (s >= ms->src_end)
		return 0;
	int c = uchar(*s);

	switch (*p) {
	case '.': return 1;
	case L_ESC: return match_class(c, uchar(*(p + 1)));
	case '[': return matchbracketclass(c, p, ep - 1);
	default: return uchar(*p) == c;
	}
}

static const char *matchbalance(MatchState *ms, const char *s,
				const char *p)
{
	if (p >= ms->p_end - 1)
		lr_error("malformed pattern (missing arguments to '%%b')");
	if (*s != *p)
		return NULL;
	int b = *p, e = *(p + 1), cont = 1;

	while (++s < ms->src_end) {
		if (*s == e) {
			if (--cont == 0)
				return s + 1;
		} else if (*s == b) {
			cont++;
		}
	}
	return NULL;
}

static const char *max_expand(MatchState *ms, const char *s, const char *p,
			      const char *ep)
{
	ptrdiff_t i = 0;

	while (singlematch(ms, s + i, p, ep))
		i++;
	while (i >= 0) {
		const char *res = match(ms, s + i, ep + 1);

		if (res)
			return res;
		i--;
	}
	return NULL;
}

static const char *min_expand(MatchState *ms, const char *s, const char *p,
			      const char *ep)
{
	for (;;) {
		const char *res = match(ms, s, ep + 1);

		if (res)
			return res;
		if (singlematch(ms, s, p, ep))
			s++;
		else
			return NULL;
	}
}

static const char *start_capture(MatchState *ms, const char *s,
				 const char *p, int what)
{
	const char *res;
	int level = ms->level;

	if (level >= MAXCAPTURES)
		lr_error("too many captures");
	ms->capture[level].init = s;
	ms->capture[level].len = what;
	ms->level = level + 1;
	if ((res = match(ms, s, p)) == NULL)
		ms->level--;
	return res;
}

static const char *end_capture(MatchState *ms, const char *s, const char *p)
{
	int l = capture_to_close(ms);
	const char *res;

	ms->capture[l].len = s - ms->capture[l].init;
	if ((res = match(ms, s, p)) == NULL)
		ms->capture[l].len = CAP_UNFINISHED;
	return res;
}

static const char *match_capture(MatchState *ms, const char *s, int l)
{
	size_t len;

	l = check_capture(ms, l);
	len = ms->capture[l].len;
	if ((size_t)(ms->src_end - s) >= len &&
	    memcmp(ms->capture[l].init, s, len) == 0)
		return s + len;
	return NULL;
}

static const char *match(MatchState *ms, const char *s, const char *p)
{
	if (ms->matchdepth-- == 0)
		lr_error("pattern too complex");
init:
	if (p != ms->p_end) {
		switch (*p) {
		case '(':
			if (*(p + 1) == ')')
				s = start_capture(ms, s, p + 2, CAP_POSITION);
			else
				s = start_capture(ms, s, p + 1, CAP_UNFINISHED);
			break;
		case ')':
			s = end_capture(ms, s, p + 1);
			break;
		case '$':
			if (p + 1 != ms->p_end)
				goto dflt;
			s = s == ms->src_end ? s : NULL;
			break;
		case L_ESC:
			switch (*(p + 1)) {
			case 'b':
				s = matchbalance(ms, s, p + 2);
				if (s != NULL) {
					p += 4;
					goto init;
				}
				break;
			case 'f': {
				const char *ep;
				char previous;

				p += 2;
				if (*p != '[')
					lr_error("missing '[' after '%%f' in "
						 "pattern");
				ep = classend(ms, p);
				previous = s == ms->src_init ? '\0' : *(s - 1);
				if (!matchbracketclass(uchar(previous), p,
						       ep - 1) &&
				    matchbracketclass(uchar(*s), p, ep - 1)) {
					p = ep;
					goto init;
				}
				s = NULL;
				break;
			}
			case '0': case '1': case '2': case '3': case '4':
			case '5': case '6': case '7': case '8': case '9':
				s = match_capture(ms, s, uchar(*(p + 1)));
				if (s != NULL) {
					p += 2;
					goto init;
				}
				break;
			default:
				goto dflt;
			}
			break;
		default:
dflt: {
			const char *ep = classend(ms, p);

			if (!singlematch(ms, s, p, ep)) {
				if (*ep == '*' || *ep == '?' || *ep == '-') {
					p = ep + 1;
					goto init;
				}
				s = NULL;
			} else {
				switch (*ep) {
				case '?': {
					const char *res = match(ms, s + 1, ep + 1);

					if (res != NULL) {
						s = res;
					} else {
						p = ep + 1;
						goto init;
					}
					break;
				}
				case '+':
					s = max_expand(ms, s + 1, p, ep);
					break;
				case '*':
					s = max_expand(ms, s, p, ep);
					break;
				case '-':
					s = min_expand(ms, s, p, ep);
					break;
				default:
					s++;
					p = ep;
					goto init;
				}
			}
			break;
		}
		}
	}
	ms->matchdepth++;
	return s;
}

/* Capture i, or the whole match when there are none, as a value of
 * count one. */
static void getcapture(MatchState *ms, int i, const char *s, const char *e,
		       TValue *out)
{
	if (i >= ms->level) {
		if (i != 0)
			lr_error("invalid capture index %%%d", i + 1);
		lr_setstr(out, lr_newstr(s, e - s));
		return;
	}
	ptrdiff_t l = ms->capture[i].len;

	if (l == CAP_UNFINISHED)
		lr_error("unfinished capture");
	if (l == CAP_POSITION) {
		LR_SETINT(out, (ms->capture[i].init - ms->src_init) + 1);
		return;
	}
	lr_setstr(out, lr_newstr(ms->capture[i].init, l));
}

/* the captures, or the whole match, into out[]; their count */
static int captures(MatchState *ms, const char *s, const char *e,
		    TValue *out, int wholeifnone)
{
	int n = (ms->level == 0 && wholeifnone) ? 1 : ms->level;

	for (int i = 0; i < n; i++)
		getcapture(ms, i, s, e, &out[i]);
	return n;
}

static void prepstate(MatchState *ms, const char *s, size_t ls,
		      const char *p, size_t lp)
{
	ms->src_init = s;
	ms->src_end = s + ls;
	ms->p_end = p + lp;
}

static void reprepstate(MatchState *ms)
{
	ms->level = 0;
	ms->matchdepth = MAXCCALLS;
}

static int nospecials(const char *p, size_t l)
{
	size_t upto = 0;

	do {
		const char *q = strpbrk(p + upto, SPECIALS);

		if (q)
			return 0;
		upto += strlen(p + upto) + 1;
	} while (upto <= l);
	return 1;
}

static const char *lmemfind(const char *s1, size_t l1, const char *s2,
			    size_t l2)
{
	if (l2 == 0)
		return s1;
	if (l2 > l1)
		return NULL;
	const char *init;

	l2--;
	l1 = l1 - l2;
	while (l1 > 0 && (init = memchr(s1, *s2, l1)) != NULL) {
		init++;
		if (memcmp(init, s2 + 1, l2) == 0)
			return init - 1;
		l1 -= init - s1;
		s1 = init;
	}
	return NULL;
}

/* Values of count one in out[0..n) become the results. */
static int results(TValue *base, int nargs, TValue *out, int n)
{
	return lr_return(base, nargs, out, n);
}

static int findaux(lr_Closure *self, TValue *base, int nargs, int find)
{
	lr_Str *ss = checkstr(self, base, nargs, 0);
	lr_Str *ps = checkstr(self, base, nargs, 1);
	const char *s = ss->s, *p = ps->s;
	size_t ls = ss->len, lp = ps->len;
	size_t init = posrelat(lr_optint(self, base, nargs, 2, 1), ls) - 1;
	TValue out[MAXCAPTURES + 2];

	if (init > ls)
		return retnil(base, nargs);
	if (find && ((nargs > 3 && !LR_ISFALSE(&base[3])) ||
		     nospecials(p, lp))) {
		const char *s2 = lmemfind(s + init, ls - init, p, lp);

		if (s2) {
			LR_SETINT(&out[0], (s2 - s) + 1);
			LR_SETINT(&out[1], (s2 - s) + lp);
			return results(base, nargs, out, 2);
		}
	} else {
		MatchState ms;
		const char *s1 = s + init;
		int anchor = *p == '^';

		if (anchor) {
			p++;
			lp--;
		}
		prepstate(&ms, s, ls, p, lp);
		do {
			const char *res;

			reprepstate(&ms);
			if ((res = match(&ms, s1, p)) != NULL) {
				if (find) {
					LR_SETINT(&out[0], (s1 - s) + 1);
					LR_SETINT(&out[1], res - s);
					int n = captures(&ms, NULL, NULL,
							 out + 2, 0);

					return results(base, nargs, out, n + 2);
				}
				int n = captures(&ms, s1, res, out, 1);

				return results(base, nargs, out, n);
			}
		} while (s1++ < ms.src_end && !anchor);
	}
	return retnil(base, nargs);
}

BUILTIN(s_find)
{
	return findaux(self, base, nargs, 1);
}

BUILTIN(s_match)
{
	return findaux(self, base, nargs, 0);
}

/* gmatch: the iterator keeps the subject and the pattern alive in its
 * boxes, and where it is in a third. */
typedef struct {
	MatchState ms;
	const char *src, *p, *lastmatch;
} GMatch;

static lr_Box *newbox(TValue *v)
{
	lr_Box *b = lr_newobj(sizeof *b, LR_BOX);

	b->rc = 1;
	b->v = *v;
	return b;
}

BUILTIN(s_gmatchaux)
{
	GMatch *gm = (GMatch *)((lr_Udata *)self->up[2]->v.v.p)->data;
	TValue out[MAXCAPTURES];

	for (const char *src = gm->src; src <= gm->ms.src_end; src++) {
		const char *e;

		reprepstate(&gm->ms);
		if ((e = match(&gm->ms, src, gm->p)) != NULL &&
		    e != gm->lastmatch) {
			gm->src = gm->lastmatch = e;
			int n = captures(&gm->ms, src, e, out, 1);

			return results(base, nargs, out, n);
		}
	}
	return lr_return(base, nargs, NULL, 0);
}

BUILTIN(s_gmatch)
{
	lr_Str *s = checkstr(self, base, nargs, 0);
	lr_Str *p = checkstr(self, base, nargs, 1);
	size_t init = posrelat(lr_optint(self, base, nargs, 2, 1), s->len) - 1;
	lr_Udata *u = lr_newobj(sizeof *u + sizeof(GMatch), LR_UDATA);
	GMatch *gm = (GMatch *)u->data;
	TValue r, uv;

	if (init > s->len)
		init = s->len + 1;
	u->mt = NULL;
	u->len = sizeof *gm;
	u->free = NULL;
	prepstate(&gm->ms, s->s, s->len, p->s, p->len);
	gm->src = s->s + init;
	gm->p = p->s;
	gm->lastmatch = NULL;
	LR_SETNIL(&r);
	lr_Closure *c = lr_closure(&r, s_gmatchaux, 3, "gmatch iterator");

	lr_retain(&base[0]);
	lr_retain(&base[1]);
	c->up[0] = newbox(&base[0]);
	c->up[1] = newbox(&base[1]);
	u->rc = 1;
	LR_SETOBJ(&uv, u, LR_UDATA);
	c->up[2] = newbox(&uv);
	return lr_return(base, nargs, &r, 1);
}

static void add_s(MatchState *ms, Buf *b, const char *s, const char *e,
		  lr_Str *repl)
{
	const char *news = repl->s, *p;
	size_t l = repl->len;

	while ((p = memchr(news, L_ESC, l)) != NULL) {
		baddl(b, news, p - news);
		p++;
		if (*p == L_ESC) {
			baddc(b, *p);
		} else if (*p == '0') {
			baddl(b, s, e - s);
		} else if (isdigit(uchar(*p))) {
			TValue cap;
			lr_Str *cs;

			getcapture(ms, *p - '1', s, e, &cap);
			cs = lr_tostr(&cap);
			baddl(b, cs->s, cs->len);
			if (cap.tt != LR_STR)
				lr_free((lr_Obj *)cs);
			lr_release(&cap);
		} else {
			lr_error("invalid use of '%c' in replacement string",
				 L_ESC);
		}
		l -= p + 1 - news;
		news = p + 1;
	}
	baddl(b, news, l);
}

static int add_value(MatchState *ms, Buf *b, const char *s, const char *e,
		     TValue *repl)
{
	TValue r;

	LR_SETNIL(&r);
	if (repl->tt == LR_FN) {
		TValue args[MAXCAPTURES];
		int n = captures(ms, s, e, args, 1);
		TValue *fa = lr_top;

		lr_move(&fa[0], repl);
		for (int i = 0; i < n; i++)
			fa[1 + i] = args[i];
		lr_call(fa, n, 1);
		r = fa[0];
		LR_SETNIL(&fa[0]);
	} else if (repl->tt == LR_TAB) {
		TValue k;

		getcapture(ms, 0, s, e, &k);
		lr_index(&r, repl, &k);
		lr_release(&k);
	} else {
		lr_Str *rs = repl->tt == LR_STR ? repl->v.p : lr_tostr(repl);

		add_s(ms, b, s, e, rs);
		if (repl->tt != LR_STR)
			lr_free((lr_Obj *)rs);
		return 1;
	}
	if (LR_ISFALSE(&r)) {
		lr_release(&r);
		baddl(b, s, e - s);
		return 0;
	}
	if (r.tt != LR_STR && !LR_ISNUM(&r))
		lr_error("invalid replacement value (a %s)", lr_typename(&r));
	lr_Str *rs = lr_tostr(&r);

	baddl(b, rs->s, rs->len);
	if (r.tt != LR_STR)
		lr_free((lr_Obj *)rs);
	lr_release(&r);
	return 1;
}

BUILTIN(s_gsub)
{
	lr_Str *ss = checkstr(self, base, nargs, 0);
	lr_Str *ps = checkstr(self, base, nargs, 1);
	const char *src = ss->s, *p = ps->s, *lastmatch = NULL;
	size_t srcl = ss->len, lp = ps->len;
	TValue *repl = (TValue *)LR_ARG(2);
	int tr = repl->tt;
	lr_Int max_s = lr_optint(self, base, nargs, 3, srcl + 1);
	int anchor = *p == '^';
	lr_Int n = 0;
	int changed = 0;
	MatchState ms;
	Buf b;

	if (!(LR_ISNUM(repl) || tr == LR_STR || tr == LR_FN || tr == LR_TAB)) {
		char msg[96];

		snprintf(msg, sizeof msg,
			 "string/function/table expected, got %s",
			 nargs > 2 ? lr_objtypename(repl) : "no value");
		argerror(self, 2, msg);
	}
	binit(&b);
	if (anchor) {
		p++;
		lp--;
	}
	prepstate(&ms, src, srcl, p, lp);
	while (n < max_s) {
		const char *e;

		reprepstate(&ms);
		if ((e = match(&ms, src, p)) != NULL && e != lastmatch) {
			n++;
			changed = add_value(&ms, &b, src, e, repl) | changed;
			src = lastmatch = e;
		} else if (src < ms.src_end) {
			baddc(&b, *src++);
		} else {
			break;
		}
		if (anchor)
			break;
	}
	TValue out[2];

	if (!changed) {
		free(b.p);
		out[0] = base[0];
		lr_retain(&out[0]);
	} else {
		baddl(&b, src, ms.src_end - src);
		lr_setstr(&out[0], bresult(&b));
	}
	LR_SETINT(&out[1], n);
	return results(base, nargs, out, 2);
}

/* format ------------------------------------------------------------------ */

#define FMTFLAGS "-+ #0"

static void addquoted(Buf *b, lr_Str *str)
{
	const char *s = str->s;
	size_t len = str->len;

	baddc(b, '"');
	while (len--) {
		if (*s == '"' || *s == '\\' || *s == '\n') {
			baddc(b, '\\');
			baddc(b, *s);
		} else if (iscntrl(uchar(*s))) {
			char buf[10];

			if (!isdigit(uchar(*(s + 1))))
				snprintf(buf, sizeof buf, "\\%d", (int)uchar(*s));
			else
				snprintf(buf, sizeof buf, "\\%03d",
					 (int)uchar(*s));
			baddl(b, buf, strlen(buf));
		} else {
			baddc(b, *s);
		}
		s++;
	}
	baddc(b, '"');
}

static void quotefloat(Buf *b, lr_Num n)
{
	char buf[128];

	if (n == HUGE_VAL)
		strcpy(buf, "1e9999");
	else if (n == -HUGE_VAL)
		strcpy(buf, "-1e9999");
	else if (n != n)
		strcpy(buf, "(0/0)");
	else
		snprintf(buf, sizeof buf, "%a", n);
	baddl(b, buf, strlen(buf));
}

BUILTIN(s_format)
{
	lr_Str *fs = checkstr(self, base, nargs, 0);
	const char *strfrmt = fs->s, *end = fs->s + fs->len;
	int arg = 0;
	Buf b;

	binit(&b);
	while (strfrmt < end) {
		if (*strfrmt != L_ESC) {
			baddc(&b, *strfrmt++);
			continue;
		}
		if (*++strfrmt == L_ESC) {
			baddc(&b, *strfrmt++);
			continue;
		}
		char form[32], buf[512];
		const char *spec = strfrmt;
		size_t flen;

		if (++arg >= nargs)
			argerror(self, arg, "no value");
		/* flags, width, precision */
		while (*strfrmt && strchr(FMTFLAGS, *strfrmt))
			strfrmt++;
		if (isdigit(uchar(*strfrmt)))
			strfrmt++;
		if (isdigit(uchar(*strfrmt)))
			strfrmt++;
		if (*strfrmt == '.') {
			strfrmt++;
			if (isdigit(uchar(*strfrmt)))
				strfrmt++;
			if (isdigit(uchar(*strfrmt)))
				strfrmt++;
		}
		if (isdigit(uchar(*strfrmt)))
			lr_error("invalid conversion '%%%.*s' to 'format'",
				 (int)(strfrmt - spec + 1), spec);
		flen = strfrmt - spec;
		form[0] = '%';
		memcpy(form + 1, spec, flen);
		form[flen + 1] = 0;
		int conv = *strfrmt++;
		TValue *a = &base[arg];

		switch (conv) {
		case 'c': {
			strcat(form, "c");
			int n = snprintf(buf, sizeof buf, form,
					 (int)lr_checkint(self, base, nargs, arg));

			baddl(&b, buf, n);
			break;
		}
		case 'd': case 'i': {
			lr_Int v = lr_checkint(self, base, nargs, arg);

			strcat(form, "lld");
			int n = snprintf(buf, sizeof buf, form, v);

			baddl(&b, buf, n);
			break;
		}
		case 'u': case 'o': case 'x': case 'X': {
			lr_Int v = lr_checkint(self, base, nargs, arg);
			size_t l = strlen(form);

			form[l] = 'l';
			form[l + 1] = 'l';
			form[l + 2] = (char)conv;
			form[l + 3] = 0;
			int n = snprintf(buf, sizeof buf, form, v);

			baddl(&b, buf, n);
			break;
		}
		case 'a': case 'A': case 'f': case 'F': case 'e': case 'E':
		case 'g': case 'G': {
			lr_Num v = lr_checknum(self, base, nargs, arg);
			size_t l = strlen(form);

			form[l] = (char)conv;
			form[l + 1] = 0;
			int n = snprintf(buf, sizeof buf, form, v);

			baddl(&b, buf, n);
			break;
		}
		case 'p': {
			const void *p = LR_COUNTED(a->tt) || a->tt == LR_LIGHT ?
				a->v.p : NULL;
			size_t l = strlen(form);

			if (!p) {
				form[l] = 's';
				form[l + 1] = 0;
				int n = snprintf(buf, sizeof buf, form, "(null)");

				baddl(&b, buf, n);
				break;
			}
			form[l] = 'p';
			form[l + 1] = 0;
			int n = snprintf(buf, sizeof buf, form, p);

			baddl(&b, buf, n);
			break;
		}
		case 'q': {
			if (flen != 0)
				lr_error("specifier '%%q' cannot have modifiers");
			if (a->tt == LR_STR) {
				addquoted(&b, a->v.p);
			} else if (a->tt == LR_INT) {
				int n = a->v.i == INT64_MIN ?
					snprintf(buf, sizeof buf, "0x%llx",
						 (unsigned long long)a->v.i) :
					snprintf(buf, sizeof buf, "%lld", a->v.i);

				baddl(&b, buf, n);
			} else if (a->tt == LR_FLT) {
				quotefloat(&b, a->v.n);
			} else if (a->tt <= LR_TRUE) {
				TValue s;

				LR_SETNIL(&s);
				lr_tostringmeta(&s, a);
				baddl(&b, ((lr_Str *)s.v.p)->s,
				      ((lr_Str *)s.v.p)->len);
				lr_release(&s);
			} else {
				argerror(self, arg, "value has no literal form");
			}
			break;
		}
		case 's': {
			TValue s;

			LR_SETNIL(&s);
			lr_tostringmeta(&s, a);
			lr_Str *str = s.v.p;

			if (flen == 0) {
				baddl(&b, str->s, str->len);
			} else {
				if (strlen(str->s) != str->len)
					argerror(self, arg, "string contains zeros");
				size_t l = strlen(form);

				form[l] = 's';
				form[l + 1] = 0;
				if (!strchr(form, '.') && str->len >= 100) {
					baddl(&b, str->s, str->len);
				} else {
					int n = snprintf(NULL, 0, form, str->s);
					char *big = malloc(n + 1);

					snprintf(big, n + 1, form, str->s);
					baddl(&b, big, n);
					free(big);
				}
			}
			lr_release(&s);
			break;
		}
		default:
			lr_error("invalid conversion '%%%.*s' to 'format'",
				 (int)(strfrmt - spec), spec);
		}
	}
	return retstr(base, nargs, bresult(&b));
}

/* the library ------------------------------------------------------------- */

static void reg(lr_Table *t, const char *name, lr_Fn fn)
{
	lr_Closure *c = malloc(sizeof *c);
	TValue v;

	c->rc = LR_IMMORTAL;
	c->tt = LR_FN;
	c->nup = 0;
	c->fn = fn;
	c->name = name;
	LR_SETOBJ(&v, c, LR_FN);
	lr_rawsets(t, name, &v);
}

void lr_openstring(lr_Table *g)
{
	lr_Table *s = lr_tnew(0, 32);
	TValue v;

	LR_SETOBJ(&v, s, LR_TAB);
	lr_rawsets(g, "string", &v);
	reg(s, "len", s_len);
	reg(s, "sub", s_sub);
	reg(s, "upper", s_upper);
	reg(s, "lower", s_lower);
	reg(s, "reverse", s_reverse);
	reg(s, "rep", s_rep);
	reg(s, "byte", s_byte);
	reg(s, "char", s_char);
	reg(s, "find", s_find);
	reg(s, "match", s_match);
	reg(s, "gmatch", s_gmatch);
	reg(s, "gsub", s_gsub);
	reg(s, "format", s_format);
	lr_strmt = lr_tnew(0, 4);
	lr_strmt->rc = LR_IMMORTAL;
	lr_rawsets(lr_strmt, "__index", &v);
}
