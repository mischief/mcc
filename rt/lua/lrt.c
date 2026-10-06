/* SPDX-License-Identifier: ISC */
/*
 * The core of the runtime: counting, strings, tables, calls, and the
 * operators, with their metamethods.  See lrt.h for the shape of things.
 */
#include "lrt.h"

#include <math.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

const TValue lr_nilvalue;

static void callmm(TValue *dst, const TValue *f, const TValue *a,
		   const TValue *b, int nargs);

#define LR_STACKSIZE (1 << 20)

TValue *lr_stack, *lr_stackend, *lr_top;

static void *xalloc(size_t n)
{
	void *p = malloc(n ? n : 1);

	if (!p) {
		fputs("lua: not enough memory\n", stderr);
		exit(1);
	}
	return p;
}

static void *xcalloc(size_t n, size_t sz)
{
	void *p = calloc(n ? n : 1, sz);

	if (!p) {
		fputs("lua: not enough memory\n", stderr);
		exit(1);
	}
	return p;
}

/* counting ------------------------------------------------------------- */

static void tfree(lr_Table *t);

/* How many objects of each tag are live, for LR_STATS. */
static long nlive[16];

void *lr_newobj(size_t n, int tt)
{
	lr_Obj *o = xalloc(n);

	o->rc = 0;
	o->tt = tt;
	nlive[tt]++;
	return o;
}

void lr_free(lr_Obj *o)
{
	nlive[o->tt]--;
	switch (o->tt) {
	case LR_STR:
		free(o);
		break;
	case LR_TAB:
		tfree((lr_Table *)o);
		break;
	case LR_FN: {
		lr_Closure *c = (lr_Closure *)o;

		for (int i = 0; i < c->nup; i++) {
			lr_Box *b = c->up[i];

			if (b && --b->rc == 0)
				lr_free((lr_Obj *)b);
		}
		free(c);
		break;
	}
	case LR_BOX: {
		lr_Box *b = (lr_Box *)o;

		lr_release(&b->v);
		free(b);
		break;
	}
	case LR_UDATA: {
		lr_Udata *u = (lr_Udata *)o;

		if (u->free)
			u->free(u->data);
		if (u->mt && --u->mt->rc == 0)
			lr_free((lr_Obj *)u->mt);
		free(u);
		break;
	}
	}
}

void lr_move(TValue *dst, const TValue *src)
{
	TValue old = *dst;

	lr_retain(src);
	*dst = *src;
	lr_release(&old);
}

void lr_clear(TValue *from, int n)
{
	for (int i = 0; i < n; i++) {
		TValue old = from[i];

		LR_SETNIL(&from[i]);
		lr_release(&old);
	}
}

void lr_setint(TValue *dst, lr_Int i)
{
	TValue v;

	LR_SETINT(&v, i);
	lr_store(dst, &v);
}

void lr_setbool(TValue *dst, int b)
{
	TValue v;

	LR_SETBOOL(&v, b);
	lr_store(dst, &v);
}

/* errors --------------------------------------------------------------- */

struct lr_jmp *lr_handler;
int lr_curline;
TValue *lr_hiwater;

void lr_line(int line)
{
	lr_curline = line;
}

_Noreturn void lr_errorv(TValue *v)
{
	if (lr_handler) {
		lr_handler->err = *v;
		longjmp(lr_handler->b, 1);
	}
	if (v->tt == LR_STR) {
		fprintf(stderr, "lua: %s\n", ((lr_Str *)v->v.p)->s);
	} else {
		char buf[64];

		lr_tostring_basic(v, buf, sizeof buf);
		fprintf(stderr, "lua: (error object is a %s value)\n",
			lr_typename(v));
	}
	exit(1);
}

_Noreturn void lr_error(const char *fmt, ...)
{
	char buf[512];
	int n = 0;
	va_list ap;
	TValue v;

	if (lr_curline > 0)
		n = snprintf(buf, sizeof buf, "%s:%d: ", lr_chunkname, lr_curline);
	va_start(ap, fmt);
	vsnprintf(buf + n, sizeof buf - n, fmt, ap);
	va_end(ap);
	lr_setstr(&v, lr_cstr(buf));
	lr_errorv(&v);
}

const char *lr_typename(const TValue *v)
{
	switch (v->tt) {
	case LR_NIL: return "nil";
	case LR_FALSE: case LR_TRUE: return "boolean";
	case LR_INT: case LR_FLT: return "number";
	case LR_STR: return "string";
	case LR_TAB: return "table";
	case LR_FN: return "function";
	case LR_LIGHT: case LR_UDATA: return "userdata";
	}
	return "?";
}

/* __name, if the metatable has a string there, else the type */
const char *lr_objtypename(const TValue *v)
{
	const TValue *n = lr_metafield(v, "__name");

	if (n && n->tt == LR_STR)
		return ((lr_Str *)n->v.p)->s;
	return lr_typename(v);
}

_Noreturn void lr_typeerror(const TValue *v, const char *op)
{
	lr_error("attempt to %s a %s value", op, lr_objtypename(v));
}

/* strings -------------------------------------------------------------- */

lr_Str *lr_newstr(const char *s, size_t len)
{
	lr_Str *r = lr_newobj(offsetof(lr_Str, s) + len + 1, LR_STR);

	r->hash = 0;
	r->len = len;
	if (s)
		memcpy(r->s, s, len);
	r->s[len] = 0;
	return r;
}

lr_Str *lr_cstr(const char *s)
{
	return lr_newstr(s, strlen(s));
}

/* A string handed in at count zero takes a count of one here. */
void lr_setstr(TValue *o, lr_Str *s)
{
	s->rc++;
	LR_SETOBJ(o, s, LR_STR);
}

unsigned lr_strhash(lr_Str *s)
{
	if (s->hash == 0) {
		unsigned h = 2166136261u;

		for (size_t i = 0; i < s->len; i++)
			h = (h ^ (unsigned char)s->s[i]) * 16777619u;
		s->hash = h ? h : 1;
	}
	return s->hash;
}

int lr_streq(lr_Str *a, lr_Str *b)
{
	if (a == b)
		return 1;
	if (a->len != b->len)
		return 0;
	if (a->hash && b->hash && a->hash != b->hash)
		return 0;
	return memcmp(a->s, b->s, a->len) == 0;
}

/* numbers -------------------------------------------------------------- */

int lr_numtoint(lr_Num n, lr_Int *out)
{
	if (n >= -9223372036854775808.0 && n < 9223372036854775808.0 &&
	    n == floor(n)) {
		*out = (lr_Int)n;
		return 1;
	}
	return 0;
}

static int isspc(int c)
{
	return c == ' ' || (c >= '\t' && c <= '\r');
}

static int hexval(int c)
{
	if (c >= '0' && c <= '9')
		return c - '0';
	if (c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if (c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

/* lobject.c's l_str2int: a decimal or a hexadecimal integer, wrapping */
static int str2int(const char *s, const char *e, lr_Int *out)
{
	lr_Unsigned a = 0;
	int empty = 1, neg = 0;

	while (s < e && isspc(*s))
		s++;
	if (s < e && (*s == '-' || *s == '+'))
		neg = *s++ == '-';
	if (s + 1 < e && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
		s += 2;
		while (s < e && hexval(*s) >= 0) {
			a = a * 16 + hexval(*s++);
			empty = 0;
		}
	} else {
		int d = 0;

		while (s < e && *s >= '0' && *s <= '9') {
			int c = *s++ - '0';

			if (a >= 922337203685477580ull &&
			    (a > 922337203685477580ull || c > 7 + neg))
				return 0;	/* overflow: it is a float */
			a = a * 10 + c;
			empty = 0;
			d++;
		}
		(void)d;
	}
	while (s < e && isspc(*s))
		s++;
	if (empty || s != e)
		return 0;
	*out = (lr_Int)(neg ? 0ull - a : a);
	return 1;
}

int lr_str2num(const char *s, size_t len, TValue *out)
{
	const char *e = s + len;
	lr_Int i;
	char buf[256], *end;

	if (str2int(s, e, &i)) {
		LR_SETINT(out, i);
		return 1;
	}
	/* strtod takes inf and nan, which Lua does not */
	for (const char *p = s; p < e; p++)
		if (*p == 'n' || *p == 'N' || *p == 'i' || *p == 'I')
			return 0;
	if (len >= sizeof buf || memchr(s, 0, len))
		return 0;
	memcpy(buf, s, len);
	buf[len] = 0;
	double d = strtod(buf, &end);

	if (end == buf)
		return 0;
	while (isspc(*end))
		end++;
	if (*end)
		return 0;
	LR_SETFLT(out, d);
	return 1;
}

int lr_tonumber(const TValue *v, TValue *out)
{
	if (LR_ISNUM(v)) {
		*out = *v;
		return 1;
	}
	if (v->tt == LR_STR) {
		lr_Str *s = v->v.p;

		return lr_str2num(s->s, s->len, out);
	}
	return 0;
}

int lr_tointeger(const TValue *v, lr_Int *out)
{
	TValue n;

	if (v->tt == LR_INT) {
		*out = v->v.i;
		return 1;
	}
	if (!lr_tonumber(v, &n))
		return 0;
	if (n.tt == LR_INT) {
		*out = n.v.i;
		return 1;
	}
	return lr_numtoint(n.v.n, out);
}

static int fmtnum(const TValue *v, char *buf, size_t n)
{
	if (v->tt == LR_INT)
		return snprintf(buf, n, "%lld", v->v.i);
	int len = snprintf(buf, n, "%.14g", v->v.n);

	if (buf[strspn(buf, "-0123456789")] == 0) {
		buf[len++] = '.';
		buf[len++] = '0';
		buf[len] = 0;
	}
	return len;
}

/* What tostring says without looking at metatables. */
int lr_tostring_basic(const TValue *v, char *buf, size_t n)
{
	switch (v->tt) {
	case LR_NIL: return snprintf(buf, n, "nil");
	case LR_FALSE: return snprintf(buf, n, "false");
	case LR_TRUE: return snprintf(buf, n, "true");
	case LR_INT: case LR_FLT: return fmtnum(v, buf, n);
	case LR_STR: return snprintf(buf, n, "%s", ((lr_Str *)v->v.p)->s);
	case LR_FN: return snprintf(buf, n, "function: %p", v->v.p);
	}
	return snprintf(buf, n, "%s: %p", lr_objtypename(v), v->v.p);
}

/* A string for a number or a string, new or retained; nil otherwise. */
lr_Str *lr_tostr(const TValue *v)
{
	char buf[64];

	if (v->tt == LR_STR)
		return v->v.p;
	if (!LR_ISNUM(v))
		return NULL;
	return lr_newstr(buf, fmtnum(v, buf, sizeof buf));
}

/* tables --------------------------------------------------------------- */

lr_Table *lr_tnew(lr_Int narr, lr_Int nhash)
{
	lr_Table *t = lr_newobj(sizeof *t, LR_TAB);

	t->flags = 0;
	t->asize = narr;
	t->arr = narr ? xcalloc(narr, sizeof(TValue)) : NULL;
	t->hcap = 0;
	t->hused = 0;
	t->node = NULL;
	t->mt = NULL;
	if (nhash > 0) {
		lr_Int c = 4;

		while (c * 3 < nhash * 4)
			c *= 2;
		t->hcap = c;
		t->node = xcalloc(c, sizeof(lr_Node));
	}
	return t;
}

static void tfree(lr_Table *t)
{
	for (lr_Int i = 0; i < t->asize; i++)
		lr_release(&t->arr[i]);
	for (lr_Int i = 0; i < t->hcap; i++) {
		lr_release(&t->node[i].key);
		lr_release(&t->node[i].val);
	}
	free(t->arr);
	free(t->node);
	if (t->mt && --t->mt->rc == 0)
		lr_free((lr_Obj *)t->mt);
	free(t);
}

static unsigned mix(lr_Unsigned x)
{
	x ^= x >> 33;
	x *= 0xff51afd7ed558ccdull;
	x ^= x >> 33;
	return (unsigned)x;
}

static unsigned hashkey(const TValue *k)
{
	switch (k->tt) {
	case LR_INT: return mix((lr_Unsigned)k->v.i);
	case LR_FLT: {
		lr_Unsigned b;

		memcpy(&b, &k->v.n, sizeof b);
		return mix(b);
	}
	case LR_STR: return lr_strhash(k->v.p);
	case LR_FALSE: return 1;
	case LR_TRUE: return 2;
	}
	return mix((lr_Unsigned)(uintptr_t)k->v.p);
}

int lr_rawequal(const TValue *a, const TValue *b)
{
	if (a->tt != b->tt) {
		if (a->tt == LR_INT && b->tt == LR_FLT)
			return (lr_Num)a->v.i == b->v.n &&
			       b->v.n >= -9223372036854775808.0 &&
			       b->v.n < 9223372036854775808.0 &&
			       (lr_Int)b->v.n == a->v.i;
		if (a->tt == LR_FLT && b->tt == LR_INT)
			return lr_rawequal(b, a);
		return 0;
	}
	switch (a->tt) {
	case LR_NIL: case LR_FALSE: case LR_TRUE: return 1;
	case LR_INT: return a->v.i == b->v.i;
	case LR_FLT: return a->v.n == b->v.n;
	case LR_STR: return lr_streq(a->v.p, b->v.p);
	}
	return a->v.p == b->v.p;
}

/* Keys only ever meet keys of their own tag here: a float with an
 * integer value was made an integer before it got this far. */
static int keyeq(const TValue *a, const TValue *b)
{
	if (a->tt != b->tt)
		return 0;
	if (a->tt == LR_STR)
		return lr_streq(a->v.p, b->v.p);
	if (a->tt == LR_FLT)
		return a->v.n == b->v.n;
	return a->v.i == b->v.i;
}

/* The node holding k, or NULL. */
static lr_Node *findnode(lr_Table *t, const TValue *k)
{
	if (!t->hcap)
		return NULL;
	lr_Int mask = t->hcap - 1;

	for (lr_Int i = hashkey(k) & mask;; i = (i + 1) & mask) {
		lr_Node *n = &t->node[i];

		if (n->key.tt == LR_NIL)
			return NULL;
		if (keyeq(&n->key, k))
			return n;
	}
}

/* An integer key for a float with an integer value. */
static const TValue *normkey(const TValue *k, TValue *tmp)
{
	lr_Int i;

	if (k->tt == LR_FLT && lr_numtoint(k->v.n, &i)) {
		LR_SETINT(tmp, i);
		return tmp;
	}
	return k;
}

const TValue *lr_rawgeti(lr_Table *t, lr_Int i)
{
	TValue k;

	if ((lr_Unsigned)i - 1 < (lr_Unsigned)t->asize)
		return &t->arr[i - 1];
	LR_SETINT(&k, i);
	lr_Node *n = findnode(t, &k);

	return n ? &n->val : &lr_nilvalue;
}

const TValue *lr_rawget(lr_Table *t, const TValue *k)
{
	TValue tmp;

	k = normkey(k, &tmp);
	if (k->tt == LR_INT)
		return lr_rawgeti(t, k->v.i);
	if (k->tt == LR_NIL)
		return &lr_nilvalue;
	lr_Node *n = findnode(t, k);

	return n ? &n->val : &lr_nilvalue;
}

const TValue *lr_rawgets(lr_Table *t, const char *s)
{
	lr_Str str;
	TValue k;
	size_t len = strlen(s);

	/* a string on the stack, for the lookup only; it has to be one
	 * object, so the long ones go to the heap */
	if (len < sizeof str.s) {
		str.rc = LR_IMMORTAL;
		str.tt = LR_STR;
		str.hash = 0;
		str.len = len;
		memcpy(str.s, s, len + 1);
		LR_SETOBJ(&k, &str, LR_STR);
		return lr_rawget(t, &k);
	}
	lr_Str *h = lr_cstr(s);
	const TValue *r;

	h->rc = 1;
	LR_SETOBJ(&k, h, LR_STR);
	r = lr_rawget(t, &k);
	lr_release(&k);
	return r;
}

static void rehash(lr_Table *t, lr_Int want);

/* Move the hash part's integer keys that now fall in the array part. */
static void migrate(lr_Table *t)
{
	for (lr_Int i = 0; i < t->hcap; i++) {
		lr_Node *n = &t->node[i];

		if (n->key.tt == LR_INT &&
		    (lr_Unsigned)n->key.v.i - 1 < (lr_Unsigned)t->asize &&
		    n->val.tt != LR_NIL) {
			t->arr[n->key.v.i - 1] = n->val;
			LR_SETNIL(&n->val);
			/* the key stays as a tombstone until a rehash */
		}
	}
}

static void growarray(lr_Table *t, lr_Int size)
{
	t->arr = realloc(t->arr, size * sizeof(TValue));
	if (!t->arr)
		lr_error("not enough memory");
	for (lr_Int i = t->asize; i < size; i++)
		LR_SETNIL(&t->arr[i]);
	t->asize = size;
	migrate(t);
}

static void rehash(lr_Table *t, lr_Int want)
{
	lr_Node *old = t->node;
	lr_Int oldcap = t->hcap, live = 0;

	for (lr_Int i = 0; i < oldcap; i++)
		if (old[i].val.tt != LR_NIL)
			live++;
	live += want;
	lr_Int cap = 4;

	while (cap * 3 < live * 4 + 4)
		cap *= 2;
	t->node = xcalloc(cap, sizeof(lr_Node));
	t->hcap = cap;
	t->hused = 0;
	for (lr_Int i = 0; i < oldcap; i++) {
		lr_Node *o = &old[i];

		if (o->val.tt == LR_NIL) {
			lr_release(&o->key);
			continue;
		}
		lr_Int mask = cap - 1, j = hashkey(&o->key) & mask;

		while (t->node[j].key.tt != LR_NIL)
			j = (j + 1) & mask;
		t->node[j] = *o;
		t->hused++;
	}
	free(old);
}

/*
 * Set without metamethods.  The table takes its own count of the key
 * and the value.  Setting nil leaves the key behind, so that next can
 * still find its way from it during a traversal.
 */
void lr_rawset(lr_Table *t, const TValue *k, const TValue *v)
{
	TValue tmp;

	k = normkey(k, &tmp);
	if (k->tt == LR_INT) {
		lr_rawseti(t, k->v.i, v);
		return;
	}
	if (k->tt == LR_NIL)
		lr_error("table index is nil");
	if (k->tt == LR_FLT && k->v.n != k->v.n)
		lr_error("table index is NaN");
	lr_Node *n = findnode(t, k);

	if (n) {
		lr_move(&n->val, v);
		return;
	}
	if (v->tt == LR_NIL)
		return;
	if ((t->hused + 1) * 4 > t->hcap * 3)
		rehash(t, 1);
	lr_Int mask = t->hcap - 1, j = hashkey(k) & mask;

	while (t->node[j].key.tt != LR_NIL)
		j = (j + 1) & mask;
	n = &t->node[j];
	lr_retain(k);
	n->key = *k;
	lr_retain(v);
	n->val = *v;
	t->hused++;
}

void lr_rawseti(lr_Table *t, lr_Int i, const TValue *v)
{
	if ((lr_Unsigned)i - 1 < (lr_Unsigned)t->asize) {
		lr_move(&t->arr[i - 1], v);
		return;
	}
	/* one past the end grows the array, doubling */
	if (i == t->asize + 1 && v->tt != LR_NIL) {
		TValue k;

		LR_SETINT(&k, i);
		lr_Node *n = findnode(t, &k);

		if (n) {
			lr_move(&n->val, v);
			return;
		}
		growarray(t, t->asize ? t->asize * 2 : 4);
		lr_move(&t->arr[i - 1], v);
		return;
	}
	TValue k;

	LR_SETINT(&k, i);
	lr_Node *n = findnode(t, &k);

	if (n) {
		lr_move(&n->val, v);
		return;
	}
	if (v->tt == LR_NIL)
		return;
	if ((t->hused + 1) * 4 > t->hcap * 3)
		rehash(t, 1);
	lr_Int mask = t->hcap - 1, j = hashkey(&k) & mask;

	while (t->node[j].key.tt != LR_NIL)
		j = (j + 1) & mask;
	n = &t->node[j];
	n->key = k;
	lr_retain(v);
	n->val = *v;
	t->hused++;
}

void lr_rawsets(lr_Table *t, const char *s, const TValue *v)
{
	TValue k;

	lr_setstr(&k, lr_cstr(s));
	lr_rawset(t, &k, v);
	lr_release(&k);
}

/* A border: a non-nil t[n] with t[n+1] nil, or 0. */
lr_Int lr_rawlen(lr_Table *t)
{
	lr_Int n = t->asize;

	if (n > 0 && t->arr[n - 1].tt == LR_NIL) {
		lr_Int lo = 0, hi = n;	/* t[lo] non-nil or lo 0, t[hi] nil */

		while (hi - lo > 1) {
			lr_Int m = (lo + hi) / 2;

			if (t->arr[m - 1].tt == LR_NIL)
				hi = m;
			else
				lo = m;
		}
		return lo;
	}
	if (!t->hcap || lr_rawgeti(t, n + 1)->tt == LR_NIL)
		return n;
	lr_Int lo = n + 1, hi = lo * 2;

	while (lr_rawgeti(t, hi)->tt != LR_NIL) {
		lo = hi;
		if (hi > ((lr_Int)1 << 61)) {
			/* pathological: walk linearly */
			lr_Int i = 1;

			while (lr_rawgeti(t, i)->tt != LR_NIL)
				i++;
			return i - 1;
		}
		hi *= 2;
	}
	while (hi - lo > 1) {
		lr_Int m = lo + (hi - lo) / 2;

		if (lr_rawgeti(t, m)->tt == LR_NIL)
			hi = m;
		else
			lo = m;
	}
	return lo;
}

/*
 * The entry after key k, into k and v, borrowed: 0 when there is none.
 * The array part comes first, then the nodes in their order.
 */
int lr_next(lr_Table *t, TValue *k, TValue *v)
{
	lr_Int i = 0;	/* the first position to look at */
	TValue tmp;

	if (k->tt != LR_NIL) {
		const TValue *nk = normkey(k, &tmp);

		if (nk->tt == LR_INT &&
		    (lr_Unsigned)nk->v.i - 1 < (lr_Unsigned)t->asize) {
			i = nk->v.i;
		} else {
			lr_Node *n = findnode(t, nk);

			if (!n)
				lr_error("invalid key to 'next'");
			i = t->asize + (n - t->node) + 1;
		}
	}
	for (; i < t->asize; i++) {
		if (t->arr[i].tt != LR_NIL) {
			LR_SETINT(k, i + 1);
			*v = t->arr[i];
			return 1;
		}
	}
	for (i -= t->asize; i < t->hcap; i++) {
		if (t->node[i].val.tt != LR_NIL) {
			*k = t->node[i].key;
			*v = t->node[i].val;
			return 1;
		}
	}
	return 0;
}

/* metatables ------------------------------------------------------------ */

lr_Table *lr_strmt;

lr_Table *lr_getmt(const TValue *o)
{
	switch (o->tt) {
	case LR_TAB: return ((lr_Table *)o->v.p)->mt;
	case LR_UDATA: return ((lr_Udata *)o->v.p)->mt;
	case LR_STR: return lr_strmt;
	}
	return NULL;
}

const TValue *lr_metafield(const TValue *o, const char *event)
{
	lr_Table *mt = lr_getmt(o);

	if (!mt)
		return NULL;
	const TValue *f = lr_rawgets(mt, event);

	return f->tt == LR_NIL ? NULL : f;
}

/* calls ---------------------------------------------------------------- */

/*
 * Missing parameters become nil and extra arguments go.  The rest of
 * the frame is left as it is: compiled code keeps nothing counted above
 * its locals, and writes every slot before it reads it.
 */
void lr_enter(TValue *base, int nargs, int np, int nslots)
{
	if (base + nslots >= lr_stackend)
		lr_error("stack overflow");
	if (nargs != np) {
		int lo = np < nargs ? np : nargs, hi = np < nargs ? nargs : np;

		lr_clear(base + lo, hi - lo);
	}
	lr_top = base + nslots;
	if (lr_top > lr_hiwater)
		lr_hiwater = lr_top;
}

/*
 * A vararg function moves its fixed parameters above the extra
 * arguments, which stay where they are: base[np..nargs).  The frame
 * starts at the slot this returns.
 */
TValue *lr_venter(TValue *base, int nargs, int np, int nslots)
{
	if (nargs <= np) {
		lr_enter(base, nargs, np, nslots);
		return base;
	}
	TValue *r = base + nargs;

	if (r + nslots >= lr_stackend)
		lr_error("stack overflow");
	lr_clear(r, np);
	for (int i = 0; i < np; i++) {
		r[i] = base[i];
		LR_SETNIL(&base[i]);
	}
	lr_top = r + nslots;
	if (lr_top > lr_hiwater)
		lr_hiwater = lr_top;
	return r;
}

/*
 * Return n values from src: everything else in [lo, hi) is released,
 * and the results move down to lo.
 */
int lr_ret(TValue *lo, TValue *hi, TValue *src, int n)
{
	TValue *end = src + n > hi ? src + n : hi;

	if (n == 1) {
		TValue v = *src;

		src->tt = LR_NIL;
		for (TValue *p = lo; p < end; p++) {
			if (LR_COUNTED(p->tt)) {
				TValue old = *p;

				p->tt = LR_NIL;
				lr_release(&old);
			}
		}
		*lo = v;
		return 1;
	}
	for (TValue *p = lo; p < end; p++) {
		if (p >= src && p < src + n)
			continue;
		if (LR_COUNTED(p->tt)) {
			TValue old = *p;

			p->tt = LR_NIL;
			lr_release(&old);
		}
	}
	if (src != lo) {
		memmove(lo, src, n * sizeof(TValue));
		for (TValue *p = lo + n > src ? lo + n : src; p < src + n; p++)
			p->tt = LR_NIL;
	}
	return n;
}

/* A builtin's return: n values, of count one each, from vals. */
int lr_return(TValue *base, int nargs, TValue *vals, int n)
{
	lr_clear(base, nargs);
	for (int i = 0; i < n; i++)
		base[i] = vals[i];
	return n;
}

/*
 * Call the value at fa with nargs arguments after it.  The results end
 * up at fa, nwant of them, or all of them for -1; the count is returned.
 */
int lr_call(TValue *fa, int nargs, int nwant)
{
	TValue *saved = lr_top;
	int n;

	for (;;) {
		if (fa->tt == LR_FN)
			break;
		const TValue *mm = lr_metafield(fa, "__call");

		if (!mm)
			lr_typeerror(fa, "call");
		if (fa + nargs + 2 >= lr_stackend)
			lr_error("stack overflow");
		memmove(fa + 1, fa, (nargs + 1) * sizeof(TValue));
		lr_retain(mm);
		*fa = *mm;
		nargs++;
	}
	if (lr_top < fa + 1 + nargs)
		lr_top = fa + 1 + nargs;
	if (lr_top > lr_hiwater)
		lr_hiwater = lr_top;
	lr_Closure *c = fa->v.p;

	n = c->fn(c, fa + 1, nargs);
	lr_top = saved;
	if (n == 1 && nwant == 1) {
		fa[0] = fa[1];
		fa[1].tt = LR_NIL;
		if (--c->rc == 0)
			lr_free((lr_Obj *)c);
		return 1;
	}
	lr_release(fa);
	memmove(fa, fa + 1, n * sizeof(TValue));
	LR_SETNIL(&fa[n]);
	if (nwant < 0)
		return n;
	if (n < nwant) {
		for (int i = n; i < nwant; i++)
			LR_SETNIL(&fa[i]);
	} else {
		lr_clear(fa + nwant, n - nwant);
	}
	return nwant;
}

/* Copy the varargs to dst: want of them, or all for -1. */
int lr_varargs(TValue *dst, TValue *src, int nvar, int want)
{
	int n = want < 0 ? nvar : want;

	if (dst + n >= lr_stackend)
		lr_error("stack overflow");
	for (int i = 0; i < n; i++)
		lr_move(&dst[i], i < nvar ? &src[i] : &lr_nilvalue);
	if (dst + n > lr_top)
		lr_top = dst + n;
	if (lr_top > lr_hiwater)
		lr_hiwater = lr_top;
	return n;
}

/* obj:key(...): the method at fa, obj after it */
void lr_self(TValue *fa, TValue *obj, TValue *key)
{
	TValue o = *obj;

	lr_retain(&o);
	lr_index(fa, &o, key);
	lr_store(fa + 1, &o);
}

/* to-be-closed variables ------------------------------------------------- */

/* A value a <close> variable may hold: false, nil, or one with __close. */
void lr_tbc(TValue *v, TValue *name)
{
	if (LR_ISFALSE(v) || lr_metafield(v, "__close"))
		return;
	lr_error("variable '%s' got a non-closable value",
		 ((lr_Str *)name->v.p)->s);
}

void lr_close(TValue *v)
{
	if (LR_ISFALSE(v))
		return;
	const TValue *mm = lr_metafield(v, "__close");

	if (!mm)
		lr_error("metamethod 'close' is missing");
	TValue f = *mm, r;

	lr_retain(&f);
	LR_SETNIL(&r);
	callmm(&r, &f, v, &lr_nilvalue, 2);
	lr_release(&f);
	lr_release(&r);
}

/* closures and boxes --------------------------------------------------- */

lr_Closure *lr_closure(TValue *dst, lr_Fn fn, int nup, const char *name)
{
	lr_Closure *c = lr_newobj(offsetof(lr_Closure, up) +
				  (nup ? nup : 1) * sizeof(lr_Box *), LR_FN);
	TValue v;

	c->nup = nup;
	c->fn = fn;
	c->name = name;
	for (int i = 0; i < nup; i++)
		c->up[i] = NULL;
	c->rc = 1;
	LR_SETOBJ(&v, c, LR_FN);
	lr_store(dst, &v);
	return c;
}

void lr_upfrombox(lr_Closure *c, int i, TValue *box)
{
	lr_Box *b = box->v.p;

	b->rc++;
	c->up[i] = b;
}

/* A box of the closure's own, for a local that is never assigned again. */
void lr_upfromval(lr_Closure *c, int i, TValue *v)
{
	lr_Box *b = lr_newobj(sizeof *b, LR_BOX);

	b->rc = 1;
	lr_retain(v);
	b->v = *v;
	c->up[i] = b;
}

/* The running closure as a value, for a function that names itself. */
void lr_selfvalue(TValue *dst, lr_Closure *c)
{
	TValue v;

	LR_SETOBJ(&v, c, LR_FN);
	lr_move(dst, &v);
}

void lr_upfromup(lr_Closure *c, int i, lr_Closure *from, int j)
{
	lr_Box *b = from->up[j];

	b->rc++;
	c->up[i] = b;
}

void lr_newbox(TValue *dst, TValue *init)
{
	lr_Box *b = lr_newobj(sizeof *b, LR_BOX);
	TValue v;

	b->rc = 1;
	lr_retain(init);
	b->v = *init;
	LR_SETOBJ(&v, b, LR_BOX);
	lr_store(dst, &v);
}

void lr_getbox(TValue *dst, TValue *box)
{
	lr_move(dst, &((lr_Box *)box->v.p)->v);
}

void lr_setbox(TValue *box, TValue *v)
{
	lr_move(&((lr_Box *)box->v.p)->v, v);
}

void lr_getup(TValue *dst, lr_Closure *c, int i)
{
	lr_move(dst, &c->up[i]->v);
}

void lr_setup(lr_Closure *c, int i, TValue *v)
{
	lr_move(&c->up[i]->v, v);
}

/* A global: a field of the _ENV this closure holds as upvalue i. */
void lr_upindex(TValue *dst, lr_Closure *c, int i, TValue *k)
{
	TValue *env = &c->up[i]->v;

	if (env->tt == LR_TAB) {
		lr_Table *h = env->v.p;
		const TValue *v = lr_rawget(h, k);

		if (v->tt != LR_NIL || !h->mt) {
			lr_move(dst, v);
			return;
		}
	}
	lr_index(dst, env, k);
}

void lr_upsetindex(lr_Closure *c, int i, TValue *k, TValue *v)
{
	lr_setindex(&c->up[i]->v, k, v);
}

/* tables from code ------------------------------------------------------ */

void lr_newtable(TValue *dst, int narr, int nhash)
{
	lr_Table *t = lr_tnew(narr, nhash);
	TValue v;

	t->rc = 1;
	LR_SETOBJ(&v, t, LR_TAB);
	lr_store(dst, &v);
}

/* The values at src move into the table: the slots are left nil. */
void lr_setlist(TValue *t, TValue *src, int n, int first)
{
	lr_Table *h = t->v.p;

	if ((lr_Int)first + n - 1 > h->asize)
		growarray(h, (lr_Int)first + n - 1);
	for (int i = 0; i < n; i++) {
		lr_rawseti(h, (lr_Int)first + i, &src[i]);
		lr_clear(&src[i], 1);
	}
}

/* metamethod calls ------------------------------------------------------ */

/* Call f(a, b) for one result into dst. */
static void callmm(TValue *dst, const TValue *f, const TValue *a,
		   const TValue *b, int nargs)
{
	TValue *fa = lr_top;

	if (fa + 4 >= lr_stackend)
		lr_error("stack overflow");
	lr_move(&fa[0], f);
	lr_move(&fa[1], a);
	if (nargs > 1)
		lr_move(&fa[2], b);
	lr_call(fa, nargs, 1);
	TValue r = fa[0];

	LR_SETNIL(&fa[0]);
	lr_store(dst, &r);
}

/* indexing ------------------------------------------------------------- */

void lr_index(TValue *dst, TValue *t, TValue *k)
{
	if (t->tt == LR_TAB) {
		lr_Table *h = t->v.p;
		const TValue *v = k->tt == LR_INT ? lr_rawgeti(h, k->v.i)
						  : lr_rawget(h, k);

		if (v->tt != LR_NIL || !h->mt) {
			lr_move(dst, v);
			return;
		}
	}
	TValue cur = *t;

	lr_retain(&cur);
	for (int loop = 0; loop < 2000; loop++) {
		const TValue *mm;

		if (cur.tt == LR_TAB) {
			lr_Table *h = cur.v.p;
			const TValue *v = lr_rawget(h, k);

			if (v->tt != LR_NIL || !h->mt ||
			    !(mm = lr_metafield(&cur, "__index"))) {
				TValue r = *v;

				lr_retain(&r);
				lr_store(dst, &r);
				lr_release(&cur);
				return;
			}
		} else {
			mm = lr_metafield(&cur, "__index");
			if (!mm) {
				TValue c = cur;

				lr_typeerror(&c, "index");
			}
		}
		if (mm->tt == LR_FN) {
			TValue f = *mm;

			lr_retain(&f);
			callmm(dst, &f, &cur, k, 2);
			lr_release(&f);
			lr_release(&cur);
			return;
		}
		TValue next = *mm;

		lr_retain(&next);
		lr_release(&cur);
		cur = next;
	}
	lr_error("'__index' chain too long; possible loop");
}

void lr_setindex(TValue *t, TValue *k, TValue *v)
{
	/* no metatable, no __newindex to look for */
	if (t->tt == LR_TAB && !((lr_Table *)t->v.p)->mt) {
		if (k->tt == LR_INT)
			lr_rawseti(t->v.p, k->v.i, v);
		else
			lr_rawset(t->v.p, k, v);
		return;
	}
	TValue cur = *t;

	lr_retain(&cur);
	for (int loop = 0; loop < 2000; loop++) {
		const TValue *mm;

		if (cur.tt == LR_TAB) {
			lr_Table *h = cur.v.p;
			const TValue *old = lr_rawget(h, k);

			if (old->tt != LR_NIL || !h->mt ||
			    !(mm = lr_metafield(&cur, "__newindex"))) {
				lr_rawset(h, k, v);
				lr_release(&cur);
				return;
			}
		} else {
			mm = lr_metafield(&cur, "__newindex");
			if (!mm)
				lr_typeerror(&cur, "index");
		}
		if (mm->tt == LR_FN) {
			TValue *fa = lr_top;
			TValue f = *mm;

			lr_retain(&f);
			lr_store(&fa[0], &f);
			lr_move(&fa[1], &cur);
			lr_move(&fa[2], k);
			lr_move(&fa[3], v);
			lr_call(fa, 3, 0);
			lr_release(&cur);
			return;
		}
		TValue next = *mm;

		lr_retain(&next);
		lr_release(&cur);
		cur = next;
	}
	lr_error("'__newindex' chain too long; possible loop");
}

/* arithmetic ------------------------------------------------------------ */

static const char *const EVENTS[] = {
	"__add", "__sub", "__mul", "__mod", "__pow", "__div", "__idiv",
	"__band", "__bor", "__bxor", "__shl", "__shr", "__unm", "__bnot",
};

static lr_Int imod(lr_Int a, lr_Int b)
{
	if ((lr_Unsigned)b + 1u <= 1u) {
		if (b == 0)
			lr_error("attempt to perform 'n%%0'");
		return 0;
	}
	lr_Int m = a % b;

	if (m != 0 && (m ^ b) < 0)
		m += b;
	return m;
}

static lr_Int idiv(lr_Int a, lr_Int b)
{
	if ((lr_Unsigned)b + 1u <= 1u) {
		if (b == 0)
			lr_error("attempt to perform 'n//0'");
		return (lr_Int)(0u - (lr_Unsigned)a);
	}
	lr_Int q = a / b;

	if ((a ^ b) < 0 && a % b != 0)
		q -= 1;
	return q;
}

static lr_Num fmodl_(lr_Num a, lr_Num b)
{
	lr_Num m = fmod(a, b);

	if ((m > 0) ? b < 0 : (m < 0 && b != m))
		m += b;
	return m;
}

static lr_Int shiftl(lr_Int x, lr_Int y)
{
	if (y < 0) {
		if (y <= -64)
			return 0;
		return (lr_Int)((lr_Unsigned)x >> -y);
	}
	if (y >= 64)
		return 0;
	return (lr_Int)((lr_Unsigned)x << y);
}

static int arithint(int op, lr_Int a, lr_Int b, TValue *r)
{
	lr_Unsigned ua = a, ub = b;

	switch (op) {
	case LR_OPADD: LR_SETINT(r, (lr_Int)(ua + ub)); return 1;
	case LR_OPSUB: LR_SETINT(r, (lr_Int)(ua - ub)); return 1;
	case LR_OPMUL: LR_SETINT(r, (lr_Int)(ua * ub)); return 1;
	case LR_OPMOD: LR_SETINT(r, imod(a, b)); return 1;
	case LR_OPIDIV: LR_SETINT(r, idiv(a, b)); return 1;
	case LR_OPUNM: LR_SETINT(r, (lr_Int)(0u - ua)); return 1;
	}
	return 0;
}

static int bitop(int op, lr_Int a, lr_Int b, TValue *r)
{
	switch (op) {
	case LR_OPBAND: LR_SETINT(r, a & b); return 1;
	case LR_OPBOR: LR_SETINT(r, a | b); return 1;
	case LR_OPBXOR: LR_SETINT(r, a ^ b); return 1;
	case LR_OPSHL: LR_SETINT(r, shiftl(a, b)); return 1;
	case LR_OPSHR: LR_SETINT(r, shiftl(a, (lr_Int)(0u - (lr_Unsigned)b)));
		return 1;
	case LR_OPBNOT: LR_SETINT(r, ~a); return 1;
	}
	return 0;
}

static lr_Num arithflt(int op, lr_Num a, lr_Num b)
{
	switch (op) {
	case LR_OPADD: return a + b;
	case LR_OPSUB: return a - b;
	case LR_OPMUL: return a * b;
	case LR_OPMOD: return fmodl_(a, b);
	case LR_OPPOW: return b == 2 ? a * a : pow(a, b);
	case LR_OPDIV: return a / b;
	case LR_OPIDIV: return floor(a / b);
	case LR_OPUNM: return -a;
	}
	return 0;
}

static int isbitop(int op)
{
	return (op >= LR_OPBAND && op <= LR_OPSHR) || op == LR_OPBNOT;
}

/* The operation with numbers, coerced from strings; 0 when it cannot. */
static int rawarith(int op, const TValue *a, const TValue *b, TValue *r)
{
	TValue x, y;

	if (isbitop(op)) {
		lr_Int i, j;

		if (a->tt == LR_INT && b->tt == LR_INT)
			return bitop(op, a->v.i, b->v.i, r);
		if (!lr_tonumber(a, &x) || !lr_tonumber(b, &y))
			return 0;
		if (!lr_tointeger(&x, &i) || !lr_tointeger(&y, &j))
			lr_error("number has no integer representation");
		return bitop(op, i, j, r);
	}
	if (a->tt == LR_INT && b->tt == LR_INT && op != LR_OPPOW &&
	    op != LR_OPDIV)
		return arithint(op, a->v.i, b->v.i, r);
	if (!lr_tonumber(a, &x) || !lr_tonumber(b, &y))
		return 0;
	if (x.tt == LR_INT && y.tt == LR_INT && op != LR_OPPOW &&
	    op != LR_OPDIV)
		return arithint(op, x.v.i, y.v.i, r);
	lr_Num p = x.tt == LR_INT ? (lr_Num)x.v.i : x.v.n;
	lr_Num q = y.tt == LR_INT ? (lr_Num)y.v.i : y.v.n;

	LR_SETFLT(r, arithflt(op, p, q));
	return 1;
}

static void arithmm(TValue *dst, TValue *a, TValue *b, int op)
{
	const TValue *mm = lr_metafield(a, EVENTS[op]);

	if (!mm)
		mm = lr_metafield(b, EVENTS[op]);
	if (mm) {
		TValue f = *mm;

		lr_retain(&f);
		callmm(dst, &f, a, b, 2);
		lr_release(&f);
		return;
	}
	if (isbitop(op)) {
		TValue x;
		const TValue *bad = lr_tonumber(a, &x) ? b : a;

		if (LR_ISNUM(a) && LR_ISNUM(b))
			lr_error("number has no integer representation");
		lr_typeerror(bad, "perform bitwise operation on");
	}
	TValue x;
	const TValue *bad = lr_tonumber(a, &x) ? b : a;

	if (bad->tt == LR_STR)
		lr_typeerror(bad, "perform arithmetic on");
	lr_typeerror(bad, "perform arithmetic on");
}

void lr_arith(TValue *dst, TValue *a, TValue *b, int op)
{
	TValue r;

	/* the common case first, without a call */
	if (a->tt == LR_INT && b->tt == LR_INT) {
		lr_Int x = a->v.i, y = b->v.i;

		switch (op) {
		case LR_OPADD:
			LR_SETINT(&r, (lr_Int)((lr_Unsigned)x + y));
			lr_store(dst, &r);
			return;
		case LR_OPSUB:
			LR_SETINT(&r, (lr_Int)((lr_Unsigned)x - y));
			lr_store(dst, &r);
			return;
		}
	} else if (a->tt == LR_FLT && b->tt == LR_FLT) {
		if (op <= LR_OPIDIV) {
			LR_SETFLT(&r, arithflt(op, a->v.n, b->v.n));
			lr_store(dst, &r);
			return;
		}
	}
	if (rawarith(op, a, b, &r)) {
		lr_store(dst, &r);
		return;
	}
	arithmm(dst, a, b, op);
}

void lr_unm(TValue *dst, TValue *a)
{
	lr_arith(dst, a, a, LR_OPUNM);
}

void lr_bnot(TValue *dst, TValue *a)
{
	lr_arith(dst, a, a, LR_OPBNOT);
}

void lr_not(TValue *dst, TValue *a)
{
	lr_setbool(dst, LR_ISFALSE(a));
}

void lr_len(TValue *dst, TValue *a)
{
	TValue r;

	if (a->tt == LR_STR) {
		LR_SETINT(&r, (lr_Int)((lr_Str *)a->v.p)->len);
		lr_store(dst, &r);
		return;
	}
	const TValue *mm = lr_metafield(a, "__len");

	if (mm) {
		TValue f = *mm;

		lr_retain(&f);
		callmm(dst, &f, a, a, 1);
		lr_release(&f);
		return;
	}
	if (a->tt == LR_TAB) {
		LR_SETINT(&r, lr_rawlen(a->v.p));
		lr_store(dst, &r);
		return;
	}
	lr_typeerror(a, "get length of");
}

/* concatenation --------------------------------------------------------- */

static int tostrable(const TValue *v)
{
	return v->tt == LR_STR || LR_ISNUM(v);
}

/* first[0] .. first[n-1], from the right, as lvm.c does it */
void lr_concat(TValue *dst, TValue *first, int n)
{
	TValue acc = first[n - 1];

	lr_retain(&acc);
	for (int i = n - 2; i >= 0; i--) {
		TValue *a = &first[i];

		if (tostrable(a) && tostrable(&acc)) {
			/* as many as can be joined at once */
			int j = i;
			size_t len = 0;
			char buf[64];

			while (j > 0 && tostrable(&first[j - 1]))
				j--;
			lr_Str *parts[64];
			int np = 0;

			if (i - j + 2 > 64)
				j = i - 62;
			for (int k = j; k <= i; k++) {
				lr_Str *s = lr_tostr(&first[k]);

				parts[np++] = s;
				len += s->len;
			}
			lr_Str *last = lr_tostr(&acc);

			len += last->len;
			lr_Str *r = lr_newstr(NULL, len);
			size_t off = 0;

			for (int k = 0; k < np; k++) {
				memcpy(r->s + off, parts[k]->s, parts[k]->len);
				off += parts[k]->len;
				if (parts[k] != first[j + k].v.p ||
				    first[j + k].tt != LR_STR)
					lr_free((lr_Obj *)parts[k]);
			}
			memcpy(r->s + off, last->s, last->len);
			if (acc.tt != LR_STR)
				lr_free((lr_Obj *)last);
			(void)buf;
			lr_release(&acc);
			lr_setstr(&acc, r);
			i = j;
			continue;
		}
		const TValue *mm = lr_metafield(a, "__concat");

		if (!mm)
			mm = lr_metafield(&acc, "__concat");
		if (!mm) {
			const TValue *bad = tostrable(a) ? &acc : a;

			lr_typeerror(bad, "concatenate");
		}
		TValue f = *mm, r;

		lr_retain(&f);
		LR_SETNIL(&r);
		callmm(&r, &f, a, &acc, 2);
		lr_release(&f);
		lr_release(&acc);
		acc = r;
	}
	lr_store(dst, &acc);
}

/* comparison ------------------------------------------------------------ */

static int callbool(const TValue *f, TValue *a, TValue *b)
{
	TValue r;
	int t;

	LR_SETNIL(&r);
	callmm(&r, f, a, b, 2);
	t = !LR_ISFALSE(&r);
	lr_release(&r);
	return t;
}

int lr_eq(TValue *a, TValue *b)
{
	if (a->tt != b->tt) {
		if (LR_ISNUM(a) && LR_ISNUM(b))
			return lr_rawequal(a, b);
		return 0;
	}
	if (a->tt == LR_TAB || a->tt == LR_UDATA) {
		if (a->v.p == b->v.p)
			return 1;
		const TValue *mm = lr_metafield(a, "__eq");

		if (!mm)
			mm = lr_metafield(b, "__eq");
		if (!mm)
			return 0;
		TValue f = *mm;
		int r;

		lr_retain(&f);
		r = callbool(&f, a, b);
		lr_release(&f);
		return r;
	}
	return lr_rawequal(a, b);
}

/* i < f, exactly, as lvm.c's LTintfloat */
static int ltintflt(lr_Int i, lr_Num f)
{
	if (f != f)
		return 0;
	if (f >= 9223372036854775808.0)
		return 1;
	if (f > -9223372036854775808.0) {
		lr_Num c = ceil(f);

		/* i < f  <=>  i < ceil(f) */
		return i < (lr_Int)c;
	}
	return 0;
}

static int leintflt(lr_Int i, lr_Num f)
{
	if (f != f)
		return 0;
	if (f >= 9223372036854775808.0)
		return 1;
	if (f >= -9223372036854775808.0)
		return i <= (lr_Int)floor(f);
	return 0;
}

static int ltfltint(lr_Num f, lr_Int i)
{
	if (f != f)
		return 0;
	if (f >= 9223372036854775808.0)
		return 0;
	if (f >= -9223372036854775808.0)
		return (lr_Int)floor(f) < i;
	return 1;
}

static int lefltint(lr_Num f, lr_Int i)
{
	if (f != f)
		return 0;
	if (f >= 9223372036854775808.0)
		return 0;
	if (f > -9223372036854775808.0)
		return (lr_Int)ceil(f) <= i;
	return 1;
}

static int strcmp_(lr_Str *a, lr_Str *b)
{
	size_t n = a->len < b->len ? a->len : b->len;
	int c = memcmp(a->s, b->s, n);

	if (c)
		return c;
	return a->len < b->len ? -1 : a->len > b->len;
}

static int compare(TValue *a, TValue *b, int le)
{
	if (a->tt == LR_INT && b->tt == LR_INT)
		return le ? a->v.i <= b->v.i : a->v.i < b->v.i;
	if (LR_ISNUM(a) && LR_ISNUM(b)) {
		if (a->tt == LR_FLT && b->tt == LR_FLT)
			return le ? a->v.n <= b->v.n : a->v.n < b->v.n;
		if (a->tt == LR_INT)
			return le ? leintflt(a->v.i, b->v.n)
				  : ltintflt(a->v.i, b->v.n);
		return le ? lefltint(a->v.n, b->v.i) : ltfltint(a->v.n, b->v.i);
	}
	if (a->tt == LR_STR && b->tt == LR_STR) {
		int c = strcmp_(a->v.p, b->v.p);

		return le ? c <= 0 : c < 0;
	}
	const char *ev = le ? "__le" : "__lt";
	const TValue *mm = lr_metafield(a, ev);

	if (!mm)
		mm = lr_metafield(b, ev);
	if (!mm) {
		const char *ta = lr_objtypename(a), *tb = lr_objtypename(b);

		if (strcmp(ta, tb) == 0)
			lr_error("attempt to compare two %s values", ta);
		lr_error("attempt to compare %s with %s", ta, tb);
	}
	TValue f = *mm;
	int r;

	lr_retain(&f);
	r = callbool(&f, a, b);
	lr_release(&f);
	return r;
}

int lr_lt(TValue *a, TValue *b)
{
	return compare(a, b, 0);
}

int lr_le(TValue *a, TValue *b)
{
	return compare(a, b, 1);
}

/* numeric for ------------------------------------------------------------ */

/*
 * ra[0] is the initial value, ra[1] the limit, ra[2] the step; ra[3] is
 * the control variable the body sees.  For integers the count of turns
 * left is kept in ra[1], as lvm.c does, so the loop cannot overflow.
 * Returns 0 when the loop does not run at all.
 */
int lr_forprep(TValue *ra)
{
	TValue *init = &ra[0], *plimit = &ra[1], *pstep = &ra[2];

	if (init->tt == LR_INT && pstep->tt == LR_INT) {
		lr_Int i = init->v.i, step = pstep->v.i, limit;

		if (step == 0)
			lr_error("'for' step is zero");
		if (plimit->tt == LR_INT) {
			limit = plimit->v.i;
		} else {
			TValue l;
			lr_Num f;

			if (!lr_tonumber(plimit, &l))
				lr_error("'for' limit must be a number");
			if (l.tt == LR_INT) {
				limit = l.v.i;
			} else {
				f = l.v.n;
				if (f != f)
					return 0;
				if (step > 0) {
					f = floor(f);
					if (f >= 9223372036854775808.0)
						limit = INT64_MAX;
					else if (f < -9223372036854775808.0)
						return 0;
					else
						limit = (lr_Int)f;
				} else {
					f = ceil(f);
					if (f < -9223372036854775808.0)
						limit = INT64_MIN;
					else if (f >= 9223372036854775808.0)
						return 0;
					else
						limit = (lr_Int)f;
				}
			}
		}
		if (step > 0 ? i > limit : i < limit)
			return 0;
		lr_Unsigned count;

		if (step > 0) {
			count = (lr_Unsigned)limit - (lr_Unsigned)i;
			if (step != 1)
				count /= (lr_Unsigned)step;
		} else {
			count = (lr_Unsigned)i - (lr_Unsigned)limit;
			count /= (lr_Unsigned)(-(step + 1)) + 1u;
		}
		lr_clear(plimit, 1);
		LR_SETINT(plimit, (lr_Int)count);
		lr_setint(&ra[3], i);
		return 1;
	}
	TValue a, b, c;

	if (!lr_tonumber(plimit, &b))
		lr_error("'for' limit must be a number");
	if (!lr_tonumber(pstep, &c))
		lr_error("'for' step must be a number");
	if (!lr_tonumber(init, &a))
		lr_error("'for' initial value must be a number");
	lr_Num fi = a.tt == LR_INT ? (lr_Num)a.v.i : a.v.n;
	lr_Num fl = b.tt == LR_INT ? (lr_Num)b.v.i : b.v.n;
	lr_Num fs = c.tt == LR_INT ? (lr_Num)c.v.i : c.v.n;

	if (fs == 0)
		lr_error("'for' step is zero");
	if (fs > 0 ? !(fi <= fl) : !(fl <= fi))
		return 0;
	lr_clear(ra, 3);
	LR_SETFLT(&ra[0], fi);
	LR_SETFLT(&ra[1], fl);
	LR_SETFLT(&ra[2], fs);
	lr_clear(&ra[3], 1);
	LR_SETFLT(&ra[3], fi);
	return 1;
}

/* Step the loop; 1 while there is another turn. */
int lr_forloop(TValue *ra)
{
	if (ra[2].tt == LR_INT) {
		lr_Unsigned count = (lr_Unsigned)ra[1].v.i;

		if (count == 0)
			return 0;
		ra[1].v.i = (lr_Int)(count - 1);
		ra[0].v.i = (lr_Int)((lr_Unsigned)ra[0].v.i +
				     (lr_Unsigned)ra[2].v.i);
		lr_setint(&ra[3], ra[0].v.i);
		return 1;
	}
	lr_Num step = ra[2].v.n, idx = ra[0].v.n + step, lim = ra[1].v.n;

	if (step > 0 ? idx <= lim : lim <= idx) {
		ra[0].v.n = idx;
		lr_clear(&ra[3], 1);
		LR_SETFLT(&ra[3], idx);
		return 1;
	}
	return 0;
}

/* the start ----------------------------------------------------------- */

extern int lr_mainchunk(lr_Closure *, TValue *, int);
TValue lr_registry;

int main(int argc, char **argv)
{
	lr_Table *g;
	TValue gv, *base;

	lr_stack = xcalloc(LR_STACKSIZE, sizeof(TValue));
	lr_stackend = lr_stack + LR_STACKSIZE - 64;
	lr_top = lr_hiwater = lr_stack;
	g = lr_tnew(0, 64);
	g->rc = 1;
	LR_SETOBJ(&gv, g, LR_TAB);
	lr_openlibs(g);
	{
		lr_Table *a = lr_tnew(argc, 1);
		TValue av;

		for (int i = 0; i < argc; i++) {
			TValue s;

			lr_setstr(&s, lr_cstr(argv[i]));
			lr_rawseti(a, i, &s);
			lr_release(&s);
		}
		a->rc = 1;
		LR_SETOBJ(&av, a, LR_TAB);
		lr_rawsets(g, "arg", &av);
		lr_release(&av);
	}
	base = lr_stack;
	lr_Closure *c = lr_closure(&base[0], lr_mainchunk, 1, "main chunk");

	lr_newbox(&base[1], &gv);
	lr_upfrombox(c, 0, &base[1]);
	lr_clear(&base[1], 1);
	lr_release(&gv);
	lr_top = base + 1;
	lr_call(base, 0, 0);
	fflush(stdout);
	if (getenv("LR_STATS")) {
		/* Without the reference it holds to itself the globals
		 * table goes, and with it everything the program left
		 * there; what is still live after that is a leak, or
		 * the library. */
		lr_rawsets(g, "_G", &lr_nilvalue);
		fprintf(stderr, "live: str %ld tab %ld fn %ld box %ld "
			"udata %ld\n", nlive[LR_STR], nlive[LR_TAB],
			nlive[LR_FN], nlive[LR_BOX], nlive[LR_UDATA]);
	}
	return 0;
}
