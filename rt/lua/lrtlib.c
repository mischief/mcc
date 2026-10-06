/* SPDX-License-Identifier: ISC */
/*
 * The base library, with table, math, io and os: as much of each as a
 * program that does not load code or run coroutines asks for.
 */
#include "lrt.h"

#include <math.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define BUILTIN(name) static int name(lr_Closure *self, TValue *base, \
				      int nargs)


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

static lr_Table *newlib(lr_Table *g, const char *name)
{
	lr_Table *t = lr_tnew(0, 16);
	TValue v;

	LR_SETOBJ(&v, t, LR_TAB);
	lr_rawsets(g, name, &v);
	return t;
}

static void setnum(lr_Table *t, const char *name, lr_Num n)
{
	TValue v;

	LR_SETFLT(&v, n);
	lr_rawsets(t, name, &v);
}

static void setint(lr_Table *t, const char *name, lr_Int n)
{
	TValue v;

	LR_SETINT(&v, n);
	lr_rawsets(t, name, &v);
}

/* argument checks ------------------------------------------------------- */

static const char *fname(lr_Closure *self)
{
	return self && self->name ? self->name : "?";
}

_Noreturn static void argerror(lr_Closure *self, int i, const char *msg)
{
	lr_error("bad argument #%d to '%s' (%s)", i + 1, fname(self), msg);
}

static void typeerror(lr_Closure *self, int i, const char *want,
		      TValue *got)
{
	char msg[128];

	snprintf(msg, sizeof msg, "%s expected, got %s", want,
		 got->tt == LR_NIL && 0 ? "no value" : lr_objtypename(got));
	argerror(self, i, msg);
}

static void checkany(lr_Closure *self, TValue *base, int nargs, int i)
{
	(void)base;
	if (i >= nargs)
		argerror(self, i, "value expected");
}

static lr_Table *checktable(lr_Closure *self, TValue *base, int nargs,
			    int i)
{
	if (i >= nargs || base[i].tt != LR_TAB)
		typeerror(self, i, "table", (TValue *)LR_ARG(i));
	return base[i].v.p;
}

lr_Int lr_checkint(lr_Closure *self, TValue *base, int nargs, int i)
{
	lr_Int r;
	const TValue *v = LR_ARG(i);

	if (v->tt == LR_INT)
		return v->v.i;
	if (!lr_tointeger(v, &r)) {
		TValue n;

		if (lr_tonumber(v, &n))
			argerror(self, i, "number has no integer representation");
		typeerror(self, i, "number", (TValue *)v);
	}
	return r;
}

lr_Int lr_optint(lr_Closure *self, TValue *base, int nargs, int i,
		 lr_Int def)
{
	if (i >= nargs || base[i].tt == LR_NIL)
		return def;
	return lr_checkint(self, base, nargs, i);
}

lr_Num lr_checknum(lr_Closure *self, TValue *base, int nargs, int i)
{
	TValue n;

	if (!lr_tonumber(LR_ARG(i), &n))
		typeerror(self, i, "number", (TValue *)LR_ARG(i));
	return n.tt == LR_INT ? (lr_Num)n.v.i : n.v.n;
}

/* return helpers ---------------------------------------------------------- */

static int ret0(TValue *base, int nargs)
{
	lr_clear(base, nargs);
	return 0;
}

static int retint(TValue *base, int nargs, lr_Int i)
{
	TValue v;

	LR_SETINT(&v, i);
	return lr_return(base, nargs, &v, 1);
}

static int retnum(TValue *base, int nargs, lr_Num n)
{
	TValue v;

	LR_SETFLT(&v, n);
	return lr_return(base, nargs, &v, 1);
}

static int retbool(TValue *base, int nargs, int b)
{
	TValue v;

	LR_SETBOOL(&v, b);
	return lr_return(base, nargs, &v, 1);
}

/* the value at base[i], retained, as one result */
static int retarg(TValue *base, int nargs, int i)
{
	TValue v = *LR_ARG(i);

	lr_retain(&v);
	return lr_return(base, nargs, &v, 1);
}

static int retstr(TValue *base, int nargs, lr_Str *s)
{
	TValue v;

	lr_setstr(&v, s);
	return lr_return(base, nargs, &v, 1);
}

/* calling back into Lua ------------------------------------------------- */

/* f(args...) for nwant results, which land at lr_top and are moved to
 * out[], owned. */
static int callf(const TValue *f, TValue *args, int nargs, TValue *out,
		 int nwant)
{
	TValue *fa = lr_top;

	if (fa + nargs + 2 >= lr_stackend)
		lr_error("stack overflow");
	lr_move(&fa[0], f);
	for (int i = 0; i < nargs; i++)
		lr_move(&fa[1 + i], &args[i]);
	int n = lr_call(fa, nargs, nwant);

	for (int i = 0; i < n; i++) {
		out[i] = fa[i];
		LR_SETNIL(&fa[i]);
	}
	return n;
}

/* base library -------------------------------------------------------------- */

void lr_tostringmeta(TValue *dst, TValue *v)
{
	const TValue *mm = lr_metafield(v, "__tostring");
	char buf[128];

	if (mm) {
		TValue r;

		callf(mm, v, 1, &r, 1);
		if (r.tt != LR_STR) {
			if (LR_ISNUM(&r)) {
				lr_Str *s = lr_tostr(&r);
				TValue t;

				lr_setstr(&t, s);
				lr_store(dst, &t);
				return;
			}
			lr_error("'__tostring' must return a string");
		}
		lr_store(dst, &r);
		return;
	}
	if (v->tt == LR_STR) {
		lr_move(dst, v);
		return;
	}
	const TValue *nm = lr_metafield(v, "__name");

	if (nm && nm->tt == LR_STR && (v->tt == LR_TAB || v->tt == LR_UDATA))
		snprintf(buf, sizeof buf, "%s: %p", ((lr_Str *)nm->v.p)->s,
			 v->v.p);
	else
		lr_tostring_basic(v, buf, sizeof buf);
	TValue t;

	lr_setstr(&t, lr_cstr(buf));
	lr_store(dst, &t);
}

BUILTIN(b_print)
{
	TValue s;

	(void)self;
	LR_SETNIL(&s);
	for (int i = 0; i < nargs; i++) {
		if (i)
			fputc('\t', stdout);
		if (base[i].tt == LR_STR) {
			lr_Str *p = base[i].v.p;

			fwrite(p->s, 1, p->len, stdout);
			continue;
		}
		if (base[i].tt == LR_INT) {
			printf("%lld", base[i].v.i);
			continue;
		}
		lr_tostringmeta(&s, &base[i]);
		fwrite(((lr_Str *)s.v.p)->s, 1, ((lr_Str *)s.v.p)->len, stdout);
	}
	fputc('\n', stdout);
	lr_release(&s);
	return ret0(base, nargs);
}

BUILTIN(b_type)
{
	checkany(self, base, nargs, 0);
	return retstr(base, nargs, lr_cstr(lr_typename(&base[0])));
}

BUILTIN(b_tostring)
{
	TValue r;

	checkany(self, base, nargs, 0);
	LR_SETNIL(&r);
	lr_tostringmeta(&r, &base[0]);
	return lr_return(base, nargs, &r, 1);
}

static int digit(int c)
{
	if (c >= '0' && c <= '9')
		return c - '0';
	if (c >= 'a' && c <= 'z')
		return c - 'a' + 10;
	if (c >= 'A' && c <= 'Z')
		return c - 'A' + 10;
	return 99;
}

BUILTIN(b_tonumber)
{
	TValue r;

	if (nargs < 2 || base[1].tt == LR_NIL) {
		checkany(self, base, nargs, 0);
		if (LR_ISNUM(&base[0]))
			return retarg(base, nargs, 0);
		if (base[0].tt == LR_STR && lr_tonumber(&base[0], &r))
			return lr_return(base, nargs, &r, 1);
		LR_SETNIL(&r);
		return lr_return(base, nargs, &r, 1);
	}
	lr_Int b = lr_checkint(self, base, nargs, 1);

	if (base[0].tt != LR_STR)
		typeerror(self, 0, "string", &base[0]);
	if (b < 2 || b > 36)
		argerror(self, 1, "base out of range");
	lr_Str *s = base[0].v.p;
	const char *p = s->s, *e = s->s + s->len;
	lr_Unsigned n = 0;
	int neg = 0, any = 0;

	while (p < e && strchr(" \f\n\r\t\v", *p) && *p)
		p++;
	if (p < e && *p == '-') {
		neg = 1;
		p++;
	} else if (p < e && *p == '+') {
		p++;
	}
	while (p < e && digit((unsigned char)*p) < b) {
		n = n * b + digit((unsigned char)*p);
		p++;
		any = 1;
	}
	while (p < e && strchr(" \f\n\r\t\v", *p) && *p)
		p++;
	if (!any || p != e) {
		LR_SETNIL(&r);
		return lr_return(base, nargs, &r, 1);
	}
	return retint(base, nargs, (lr_Int)(neg ? 0 - n : n));
}

BUILTIN(b_rawequal)
{
	checkany(self, base, nargs, 0);
	checkany(self, base, nargs, 1);
	return retbool(base, nargs, lr_rawequal(&base[0], &base[1]));
}

BUILTIN(b_rawlen)
{
	if (nargs > 0 && base[0].tt == LR_STR)
		return retint(base, nargs, ((lr_Str *)base[0].v.p)->len);
	if (nargs < 1 || base[0].tt != LR_TAB)
		argerror(self, 0, "table or string expected");
	return retint(base, nargs, lr_rawlen(base[0].v.p));
}

BUILTIN(b_rawget)
{
	lr_Table *t = checktable(self, base, nargs, 0);

	checkany(self, base, nargs, 1);
	TValue v = *lr_rawget(t, &base[1]);

	lr_retain(&v);
	return lr_return(base, nargs, &v, 1);
}

BUILTIN(b_rawset)
{
	lr_Table *t = checktable(self, base, nargs, 0);

	checkany(self, base, nargs, 1);
	checkany(self, base, nargs, 2);
	lr_rawset(t, &base[1], &base[2]);
	return retarg(base, nargs, 0);
}

BUILTIN(b_setmetatable)
{
	lr_Table *t = checktable(self, base, nargs, 0);

	if (nargs < 2 || (base[1].tt != LR_NIL && base[1].tt != LR_TAB))
		typeerror(self, 1, "nil or table", (TValue *)LR_ARG(1));
	if (t->mt && lr_rawgets(t->mt, "__metatable")->tt != LR_NIL)
		lr_error("cannot change a protected metatable");
	lr_Table *mt = base[1].tt == LR_TAB ? base[1].v.p : NULL;

	if (mt)
		mt->rc++;
	if (t->mt && --t->mt->rc == 0)
		lr_free((lr_Obj *)t->mt);
	t->mt = mt;
	return retarg(base, nargs, 0);
}

BUILTIN(b_getmetatable)
{
	checkany(self, base, nargs, 0);
	lr_Table *mt = lr_getmt(&base[0]);
	TValue r;

	if (!mt) {
		LR_SETNIL(&r);
		return lr_return(base, nargs, &r, 1);
	}
	const TValue *p = lr_rawgets(mt, "__metatable");

	if (p->tt != LR_NIL) {
		r = *p;
		lr_retain(&r);
		return lr_return(base, nargs, &r, 1);
	}
	LR_SETOBJ(&r, mt, LR_TAB);
	lr_retain(&r);
	return lr_return(base, nargs, &r, 1);
}

BUILTIN(b_assert)
{
	checkany(self, base, nargs, 0);
	if (!LR_ISFALSE(&base[0]))
		return nargs;
	if (nargs < 2) {
		lr_error("assertion failed!");
	}
	TValue e = base[1];

	lr_retain(&e);
	lr_errorv(&e);
}

BUILTIN(b_error)
{
	TValue e = *LR_ARG(0);
	lr_Int level = lr_optint(self, base, nargs, 1, 1);

	(void)self;
	if (e.tt == LR_STR && level > 0 && lr_curline > 0) {
		char pre[256];
		lr_Str *m = e.v.p;
		int n = snprintf(pre, sizeof pre, "%s:%d: ", lr_chunkname,
				 lr_curline);
		lr_Str *s = lr_newstr(NULL, n + m->len);

		memcpy(s->s, pre, n);
		memcpy(s->s + n, m->s, m->len);
		lr_setstr(&e, s);
	} else {
		lr_retain(&e);
	}
	lr_errorv(&e);
}

/* Release every slot from `from` up to the highest the stack reached. */
static void unwind(TValue *from)
{
	TValue *hi = lr_hiwater;

	if (hi > from)
		lr_clear(from, (int)(hi - from));
	lr_hiwater = from;
}

static int protect(lr_Closure *self, TValue *base, int nargs,
		   const TValue *handler)
{
	struct lr_jmp j;
	TValue *volatile vbase = base;
	TValue *volatile savedtop = lr_top;
	volatile int status;

	(void)self;
	j.prev = lr_handler;
	lr_handler = &j;
	status = setjmp(j.b);
	if (status == 0) {
		int n = lr_call(vbase, nargs - 1, -1);

		lr_handler = j.prev;
		if (vbase + n + 1 >= lr_stackend)
			lr_error("stack overflow");
		memmove(vbase + 1, vbase, n * sizeof(TValue));
		LR_SETBOOL(&vbase[0], 1);
		return n + 1;
	}
	lr_handler = j.prev;
	lr_top = savedtop;
	base = vbase;
	unwind(base);
	TValue r[2];

	LR_SETBOOL(&r[0], 0);
	r[1] = j.err;
	if (handler) {
		TValue h = *handler, out;

		callf(&h, &r[1], 1, &out, 1);
		lr_release(&r[1]);
		lr_release(&h);
		r[1] = out;
	}
	base[0] = r[0];
	base[1] = r[1];
	return 2;
}

BUILTIN(b_pcall)
{
	checkany(self, base, nargs, 0);
	return protect(self, base, nargs, NULL);
}

BUILTIN(b_xpcall)
{
	TValue h;

	if (nargs < 2)
		argerror(self, 1, "value expected");
	/* f, msgh, args... becomes f, args..., with msgh kept aside */
	h = base[1];
	memmove(&base[1], &base[2], (nargs - 2) * sizeof(TValue));
	LR_SETNIL(&base[nargs - 1]);
	int n = protect(self, base, nargs - 1, &h);

	if (n > 0 && base[0].tt == LR_TRUE)
		lr_release(&h);
	return n;
}

BUILTIN(b_next)
{
	lr_Table *t = checktable(self, base, nargs, 0);
	TValue k = *LR_ARG(1), v;

	if (!lr_next(t, &k, &v)) {
		TValue r;

		LR_SETNIL(&r);
		return lr_return(base, nargs, &r, 1);
	}
	TValue r[2] = {k, v};

	lr_retain(&r[0]);
	lr_retain(&r[1]);
	return lr_return(base, nargs, r, 2);
}

static lr_Closure *nextfn;

BUILTIN(b_pairs)
{
	checkany(self, base, nargs, 0);
	const TValue *mm = lr_metafield(&base[0], "__pairs");

	if (mm) {
		TValue f = *mm, out[3];

		lr_retain(&f);
		callf(&f, &base[0], 1, out, 3);
		lr_release(&f);
		return lr_return(base, nargs, out, 3);
	}
	if (base[0].tt != LR_TAB)
		typeerror(self, 0, "table", &base[0]);
	TValue r[3];

	LR_SETOBJ(&r[0], nextfn, LR_FN);
	r[1] = base[0];
	lr_retain(&r[1]);
	LR_SETNIL(&r[2]);
	return lr_return(base, nargs, r, 3);
}

BUILTIN(b_ipairsaux)
{
	lr_Int i = base[1].v.i + 1;
	TValue k, r[2];

	(void)self;
	LR_SETINT(&k, i);
	LR_SETNIL(&r[1]);
	if (base[0].tt == LR_TAB && !((lr_Table *)base[0].v.p)->mt) {
		r[1] = *lr_rawgeti(base[0].v.p, i);
		lr_retain(&r[1]);
	} else {
		lr_index(&r[1], &base[0], &k);
	}
	if (r[1].tt == LR_NIL)
		return lr_return(base, nargs, &r[1], 1);
	r[0] = k;
	return lr_return(base, nargs, r, 2);
}

static lr_Closure *ipairsauxfn;

BUILTIN(b_ipairs)
{
	TValue r[3];

	checkany(self, base, nargs, 0);
	LR_SETOBJ(&r[0], ipairsauxfn, LR_FN);
	r[1] = base[0];
	lr_retain(&r[1]);
	LR_SETINT(&r[2], 0);
	return lr_return(base, nargs, r, 3);
}

BUILTIN(b_select)
{
	if (nargs > 0 && base[0].tt == LR_STR &&
	    ((lr_Str *)base[0].v.p)->s[0] == '#')
		return retint(base, nargs, nargs - 1);
	lr_Int n = lr_checkint(self, base, nargs, 0);

	if (n < 0)
		n = nargs - 1 + n;
	else if (n > nargs - 1)
		n = nargs - 1;
	else
		n = n - 1;
	if (n < 0)
		argerror(self, 0, "index out of range");
	/* keep base[1 + n ..) */
	lr_clear(base, (int)(1 + n));
	int k = nargs - 1 - (int)n;

	memmove(base, base + 1 + n, k * sizeof(TValue));
	for (int i = k; i < nargs; i++)
		LR_SETNIL(&base[i]);
	return k;
}

BUILTIN(b_unpack);

BUILTIN(b_collectgarbage)
{
	const char *opt = nargs > 0 && base[0].tt == LR_STR ?
		((lr_Str *)base[0].v.p)->s : "collect";

	(void)self;
	if (strcmp(opt, "count") == 0)
		return retnum(base, nargs, 0);
	if (strcmp(opt, "isrunning") == 0)
		return retbool(base, nargs, 1);
	return retint(base, nargs, 0);
}

/* table library ----------------------------------------------------------- */

/* t[i], respecting metamethods when there are any, owned */
static TValue geti(TValue *t, lr_Int i)
{
	TValue r;

	if (t->tt == LR_TAB && !((lr_Table *)t->v.p)->mt) {
		r = *lr_rawgeti(t->v.p, i);
		lr_retain(&r);
		return r;
	}
	TValue k;

	LR_SETINT(&k, i);
	LR_SETNIL(&r);
	lr_index(&r, t, &k);
	return r;
}

static void seti(TValue *t, lr_Int i, TValue *v)
{
	if (t->tt == LR_TAB && !((lr_Table *)t->v.p)->mt) {
		lr_rawseti(t->v.p, i, v);
		return;
	}
	TValue k;

	LR_SETINT(&k, i);
	lr_setindex(t, &k, v);
}

static lr_Int lenof(TValue *t)
{
	if (t->tt == LR_TAB && !((lr_Table *)t->v.p)->mt)
		return lr_rawlen(t->v.p);
	TValue r;

	LR_SETNIL(&r);
	lr_len(&r, t);
	if (r.tt != LR_INT)
		lr_error("object length is not an integer");
	return r.v.i;
}

static void checktab(lr_Closure *self, TValue *base, int nargs, int i)
{
	if (i < nargs && base[i].tt == LR_TAB)
		return;
	if (i < nargs && lr_getmt(&base[i]))
		return;
	typeerror(self, i, "table", (TValue *)LR_ARG(i));
}

BUILTIN(t_insert)
{
	checktab(self, base, nargs, 0);
	lr_Int e = lenof(&base[0]) + 1;

	if (nargs == 2) {
		seti(&base[0], e, &base[1]);
		return ret0(base, nargs);
	}
	if (nargs != 3)
		lr_error("wrong number of arguments to 'insert'");
	lr_Int pos = lr_checkint(self, base, nargs, 1);

	if ((lr_Unsigned)pos - 1u >= (lr_Unsigned)e)
		argerror(self, 1, "position out of bounds");
	for (lr_Int i = e; i > pos; i--) {
		TValue v = geti(&base[0], i - 1);

		seti(&base[0], i, &v);
		lr_release(&v);
	}
	seti(&base[0], pos, &base[2]);
	return ret0(base, nargs);
}

BUILTIN(t_remove)
{
	checktab(self, base, nargs, 0);
	lr_Int size = lenof(&base[0]);
	lr_Int pos = lr_optint(self, base, nargs, 1, size);

	if (nargs > 1 && size + 1 != pos &&
	    (lr_Unsigned)pos - 1u >= (lr_Unsigned)size + 1u &&
	    !(size == 0 && pos == 0))
		argerror(self, 1, "position out of bounds");
	TValue r = geti(&base[0], pos);

	for (; pos < size; pos++) {
		TValue v = geti(&base[0], pos + 1);

		seti(&base[0], pos, &v);
		lr_release(&v);
	}
	if (pos <= size || nargs < 2 || size + 1 == pos)
		seti(&base[0], pos, (TValue *)&lr_nilvalue);
	return lr_return(base, nargs, &r, 1);
}

BUILTIN(t_concat)
{
	checktab(self, base, nargs, 0);
	const char *sep = "";
	size_t seplen = 0;

	if (nargs > 1 && base[1].tt != LR_NIL) {
		if (base[1].tt != LR_STR && !LR_ISNUM(&base[1]))
			typeerror(self, 1, "string", &base[1]);
		if (base[1].tt == LR_STR) {
			sep = ((lr_Str *)base[1].v.p)->s;
			seplen = ((lr_Str *)base[1].v.p)->len;
		}
	}
	lr_Str *sepnum = NULL;

	if (nargs > 1 && LR_ISNUM(&base[1])) {
		sepnum = lr_tostr(&base[1]);
		sep = sepnum->s;
		seplen = sepnum->len;
	}
	lr_Int i = lr_optint(self, base, nargs, 2, 1);
	lr_Int last = nargs > 3 && base[3].tt != LR_NIL ?
		lr_checkint(self, base, nargs, 3) : lenof(&base[0]);
	size_t cap = 64, len = 0;
	char *buf = malloc(cap);

	for (; i <= last; i++) {
		TValue v = geti(&base[0], i);
		lr_Str *s = lr_tostr(&v);

		if (!s) {
			free(buf);
			lr_error("invalid value (at index %lld) in table for "
				 "'concat'", i);
		}
		size_t need = len + s->len + seplen;

		if (need > cap) {
			while (need > cap)
				cap *= 2;
			buf = realloc(buf, cap);
		}
		memcpy(buf + len, s->s, s->len);
		len += s->len;
		if (v.tt != LR_STR)
			lr_free((lr_Obj *)s);
		lr_release(&v);
		if (i != last) {
			memcpy(buf + len, sep, seplen);
			len += seplen;
		}
		if (i == last)
			break;
	}
	lr_Str *r = lr_newstr(buf, len);

	free(buf);
	if (sepnum)
		lr_free((lr_Obj *)sepnum);
	return retstr(base, nargs, r);
}

BUILTIN(b_unpack)
{
	lr_Int i = lr_optint(self, base, nargs, 1, 1);
	lr_Int e = nargs > 2 && base[2].tt != LR_NIL ?
		lr_checkint(self, base, nargs, 2) :
		lenof((TValue *)LR_ARG(0));

	if (i > e)
		return ret0(base, nargs);
	lr_Unsigned n = (lr_Unsigned)e - i;

	if (n >= 1000000 || base + nargs + n + 1 >= lr_stackend)
		lr_error("too many results to unpack");
	/* the results go above the arguments, then down */
	TValue *out = base + nargs;

	for (lr_Unsigned k = 0; k <= n; k++) {
		TValue v = geti(&base[0], i + (lr_Int)k);

		lr_store(&out[k], &v);
	}
	lr_clear(base, nargs);
	memmove(base, out, (n + 1) * sizeof(TValue));
	for (TValue *p = base + n + 1 > out ? base + n + 1 : out;
	     p < out + n + 1; p++)
		LR_SETNIL(p);
	return (int)(n + 1);
}

BUILTIN(t_pack)
{
	lr_Table *t = lr_tnew(nargs, 1);
	TValue r, n;

	(void)self;
	for (int i = 0; i < nargs; i++)
		lr_rawseti(t, i + 1, &base[i]);
	LR_SETINT(&n, nargs);
	lr_rawsets(t, "n", &n);
	t->rc = 1;
	LR_SETOBJ(&r, t, LR_TAB);
	return lr_return(base, nargs, &r, 1);
}

/* ltablib.c's sort, so that the order of equal elements is Lua's own */
struct sorter {
	TValue *t;
	TValue *cmp;
};

static int sortlt(struct sorter *s, TValue *a, TValue *b)
{
	if (!s->cmp || s->cmp->tt == LR_NIL)
		return lr_lt(a, b);
	TValue args[2] = {*a, *b}, r;
	int res;

	callf(s->cmp, args, 2, &r, 1);
	res = !LR_ISFALSE(&r);
	lr_release(&r);
	return res;
}

static void set2(struct sorter *s, lr_Int i, TValue *vi, lr_Int j,
		 TValue *vj)
{
	seti(s->t, i, vi);
	seti(s->t, j, vj);
}

static unsigned randpivot(void)
{
	return (unsigned)clock() + (unsigned)time(NULL);
}

static lr_Int partition(struct sorter *s, lr_Int lo, lr_Int up)
{
	lr_Int i = lo, j = up - 1;
	TValue P = geti(s->t, up - 1);

	for (;;) {
		TValue a, b;

		for (;;) {
			a = geti(s->t, ++i);
			if (!sortlt(s, &a, &P))
				break;
			if (i == up - 1)
				lr_error("invalid order function for sorting");
			lr_release(&a);
		}
		for (;;) {
			b = geti(s->t, --j);
			if (!sortlt(s, &P, &b))
				break;
			if (j < i)
				lr_error("invalid order function for sorting");
			lr_release(&b);
		}
		if (j < i) {
			TValue u = geti(s->t, up - 1);

			lr_release(&b);
			set2(s, up - 1, &a, i, &u);
			lr_release(&a);
			lr_release(&u);
			lr_release(&P);
			return i;
		}
		set2(s, i, &b, j, &a);
		lr_release(&a);
		lr_release(&b);
	}
}

static void auxsort(struct sorter *s, lr_Int lo, lr_Int up, unsigned rnd)
{
	while (lo < up) {
		lr_Int p, n;
		TValue a = geti(s->t, lo), b = geti(s->t, up);

		if (sortlt(s, &b, &a))
			set2(s, lo, &b, up, &a);
		lr_release(&a);
		lr_release(&b);
		if (up - lo == 1)
			break;
		if (up - lo < 100 || rnd == 0) {
			p = (lo + up) / 2;
		} else {
			lr_Int r4 = (up - lo) / 4;

			p = rnd % (r4 * 2) + (lo + r4);
		}
		a = geti(s->t, p);
		b = geti(s->t, lo);
		if (sortlt(s, &a, &b)) {
			set2(s, p, &b, lo, &a);
		} else {
			TValue c = geti(s->t, up);

			if (sortlt(s, &c, &a))
				set2(s, p, &c, up, &a);
			lr_release(&c);
		}
		lr_release(&a);
		lr_release(&b);
		if (up - lo == 2)
			break;
		a = geti(s->t, p);
		b = geti(s->t, up - 1);
		set2(s, p, &b, up - 1, &a);
		lr_release(&a);
		lr_release(&b);
		p = partition(s, lo, up);
		if (p - lo < up - p) {
			auxsort(s, lo, p - 1, rnd);
			n = p - lo;
			lo = p + 1;
		} else {
			auxsort(s, p + 1, up, rnd);
			n = up - p;
			up = p - 1;
		}
		if ((up - lo) / 128 > n)
			rnd = randpivot();
	}
}

BUILTIN(t_sort)
{
	struct sorter s;

	checktab(self, base, nargs, 0);
	lr_Int n = lenof(&base[0]);

	if (n > 1) {
		if (n >= 0x7fffffff)
			argerror(self, 0, "array too big");
		if (nargs > 1 && base[1].tt != LR_NIL && base[1].tt != LR_FN)
			typeerror(self, 1, "function", &base[1]);
		s.t = &base[0];
		s.cmp = nargs > 1 ? &base[1] : NULL;
		auxsort(&s, 1, n, 0);
	}
	return ret0(base, nargs);
}

BUILTIN(t_move)
{
	checktab(self, base, nargs, 0);
	lr_Int f = lr_checkint(self, base, nargs, 1);
	lr_Int e = lr_checkint(self, base, nargs, 2);
	lr_Int t = lr_checkint(self, base, nargs, 3);
	TValue *tt = nargs > 4 && base[4].tt != LR_NIL ? &base[4] : &base[0];

	if (e >= f) {
		if (t > e || t <= f || (nargs > 4 && base[4].tt != LR_NIL)) {
			for (lr_Int i = 0; i <= e - f; i++) {
				TValue v = geti(&base[0], f + i);

				seti(tt, t + i, &v);
				lr_release(&v);
			}
		} else {
			for (lr_Int i = e - f; i >= 0; i--) {
				TValue v = geti(&base[0], f + i);

				seti(tt, t + i, &v);
				lr_release(&v);
			}
		}
	}
	return retarg(base, nargs, tt == &base[0] ? 0 : 4);
}

/* math -------------------------------------------------------------------- */

#define MATH1(name, fn)							\
BUILTIN(name)								\
{									\
	return retnum(base, nargs, fn(lr_checknum(self, base, nargs, 0)));\
}

MATH1(m_sqrt, sqrt)
MATH1(m_sin, sin)
MATH1(m_cos, cos)
MATH1(m_tan, tan)
MATH1(m_asin, asin)
MATH1(m_acos, acos)
MATH1(m_exp, exp)

BUILTIN(m_atan)
{
	lr_Num y = lr_checknum(self, base, nargs, 0);
	lr_Num x = nargs > 1 && base[1].tt != LR_NIL ?
		lr_checknum(self, base, nargs, 1) : 1;

	return retnum(base, nargs, atan2(y, x));
}

BUILTIN(m_log)
{
	lr_Num x = lr_checknum(self, base, nargs, 0);

	if (nargs < 2 || base[1].tt == LR_NIL)
		return retnum(base, nargs, log(x));
	lr_Num b = lr_checknum(self, base, nargs, 1);

	if (b == 2)
		return retnum(base, nargs, log2(x));
	if (b == 10)
		return retnum(base, nargs, log10(x));
	return retnum(base, nargs, log(x) / log(b));
}

static int floorceil(lr_Closure *self, TValue *base, int nargs, int up)
{
	if (nargs > 0 && base[0].tt == LR_INT)
		return retarg(base, nargs, 0);
	lr_Num f = lr_checknum(self, base, nargs, 0);
	lr_Int i;

	f = up ? ceil(f) : floor(f);
	if (lr_numtoint(f, &i))
		return retint(base, nargs, i);
	return retnum(base, nargs, f);
}

BUILTIN(m_floor)
{
	return floorceil(self, base, nargs, 0);
}

BUILTIN(m_ceil)
{
	return floorceil(self, base, nargs, 1);
}

BUILTIN(m_abs)
{
	if (nargs > 0 && base[0].tt == LR_INT) {
		lr_Int i = base[0].v.i;

		return retint(base, nargs, i < 0 ? (lr_Int)(0u - (lr_Unsigned)i)
					     : i);
	}
	return retnum(base, nargs, fabs(lr_checknum(self, base, nargs, 0)));
}

static int minmax(lr_Closure *self, TValue *base, int nargs, int max)
{
	int best = 0;

	lr_checknum(self, base, nargs, 0);
	for (int i = 1; i < nargs; i++) {
		lr_checknum(self, base, nargs, i);
		if (max ? lr_lt(&base[best], &base[i])
			: lr_lt(&base[i], &base[best]))
			best = i;
	}
	return retarg(base, nargs, best);
}

BUILTIN(m_max)
{
	return minmax(self, base, nargs, 1);
}

BUILTIN(m_min)
{
	return minmax(self, base, nargs, 0);
}

BUILTIN(m_fmod)
{
	if (nargs > 1 && base[0].tt == LR_INT && base[1].tt == LR_INT) {
		lr_Int a = base[0].v.i, b = base[1].v.i;

		if ((lr_Unsigned)b + 1u <= 1u) {
			if (b == 0)
				argerror(self, 1, "zero");
			return retint(base, nargs, 0);
		}
		return retint(base, nargs, a % b);
	}
	return retnum(base, nargs, fmod(lr_checknum(self, base, nargs, 0),
					lr_checknum(self, base, nargs, 1)));
}

BUILTIN(m_modf)
{
	if (nargs > 0 && base[0].tt == LR_INT) {
		TValue r[2] = {base[0]};

		LR_SETFLT(&r[1], 0.0);
		LR_SETNIL(&base[0]);
		return lr_return(base, nargs, r, 2);
	}
	lr_Num x = lr_checknum(self, base, nargs, 0);
	lr_Num ip = x >= 0 ? floor(x) : ceil(x);
	TValue r[2];
	lr_Int i;

	if (lr_numtoint(ip, &i))
		LR_SETINT(&r[0], i);
	else
		LR_SETFLT(&r[0], ip);
	LR_SETFLT(&r[1], x == ip ? 0.0 : x - ip);
	return lr_return(base, nargs, r, 2);
}

BUILTIN(m_tointeger)
{
	lr_Int i;
	TValue r;

	if (nargs > 0 && base[0].tt == LR_INT)
		return retarg(base, nargs, 0);
	if (nargs > 0 && base[0].tt == LR_FLT && lr_numtoint(base[0].v.n, &i))
		return retint(base, nargs, i);
	if (nargs > 0 && base[0].tt == LR_STR && lr_tointeger(&base[0], &i))
		return retint(base, nargs, i);
	checkany(self, base, nargs, 0);
	LR_SETNIL(&r);
	return lr_return(base, nargs, &r, 1);
}

BUILTIN(m_type)
{
	TValue r;

	checkany(self, base, nargs, 0);
	if (base[0].tt == LR_INT)
		return retstr(base, nargs, lr_cstr("integer"));
	if (base[0].tt == LR_FLT)
		return retstr(base, nargs, lr_cstr("float"));
	LR_SETNIL(&r);
	return lr_return(base, nargs, &r, 1);
}

BUILTIN(m_ult)
{
	lr_Int a = lr_checkint(self, base, nargs, 0);
	lr_Int b = lr_checkint(self, base, nargs, 1);

	return retbool(base, nargs, (lr_Unsigned)a < (lr_Unsigned)b);
}

/* xoshiro256**, as lmathlib.c has it */
static lr_Unsigned rs[4];

static lr_Unsigned rotl(lr_Unsigned x, int n)
{
	return (x << n) | (x >> (64 - n));
}

static lr_Unsigned nextrand(void)
{
	lr_Unsigned s0 = rs[0], s1 = rs[1], s2 = rs[2] ^ s0, s3 = rs[3] ^ s1;
	lr_Unsigned res = rotl(s1 * 5, 7) * 9;

	s1 <<= 17;
	rs[0] = s0 ^ s3;
	rs[1] = s0 ^ s2;
	rs[2] = s2 ^ s1;
	rs[3] = rotl(s3, 45);
	(void)s1;
	return res;
}

static void setseed(lr_Unsigned n1, lr_Unsigned n2)
{
	rs[0] = n1;
	rs[1] = 0xff;
	rs[2] = n2;
	rs[3] = 0;
	for (int i = 0; i < 16; i++)
		nextrand();
}

static lr_Unsigned project(lr_Unsigned ran, lr_Unsigned n)
{
	if ((n & (n + 1)) == 0)
		return ran & n;
	lr_Unsigned lim = n;

	lim |= lim >> 1;
	lim |= lim >> 2;
	lim |= lim >> 4;
	lim |= lim >> 8;
	lim |= lim >> 16;
	lim |= lim >> 32;
	while ((ran &= lim) > n)
		ran = nextrand();
	return ran;
}

BUILTIN(m_random)
{
	lr_Unsigned rv = nextrand();
	lr_Int lo, up;

	switch (nargs) {
	case 0:
		return retnum(base, nargs, (lr_Num)(rv >> 11) *
			      (0.5 / ((lr_Unsigned)1 << 52)));
	case 1:
		lo = 1;
		up = lr_checkint(self, base, nargs, 0);
		if (up == 0)
			return retint(base, nargs, (lr_Int)rv);
		break;
	case 2:
		lo = lr_checkint(self, base, nargs, 0);
		up = lr_checkint(self, base, nargs, 1);
		break;
	default:
		lr_error("wrong number of arguments");
	}
	if (lo > up)
		argerror(self, nargs - 1, "interval is empty");
	return retint(base, nargs, (lr_Int)(project(rv, (lr_Unsigned)up -
						      (lr_Unsigned)lo) +
					     (lr_Unsigned)lo));
}

BUILTIN(m_randomseed)
{
	if (nargs == 0) {
		setseed((lr_Unsigned)time(NULL), (lr_Unsigned)clock());
		return ret0(base, nargs);
	}
	lr_Int n1 = (lr_Int)lr_checknum(self, base, nargs, 0);
	lr_Int n2 = lr_optint(self, base, nargs, 1, 0);

	if (base[0].tt == LR_INT)
		n1 = base[0].v.i;
	setseed((lr_Unsigned)n1, (lr_Unsigned)n2);
	TValue r[2];

	LR_SETINT(&r[0], n1);
	LR_SETINT(&r[1], n2);
	return lr_return(base, nargs, r, 2);
}

/* io and os ---------------------------------------------------------------- */

static int writeall(lr_Closure *self, TValue *base, int nargs, int from,
		    FILE *f)
{
	char buf[64];

	for (int i = from; i < nargs; i++) {
		if (base[i].tt == LR_STR) {
			lr_Str *s = base[i].v.p;

			fwrite(s->s, 1, s->len, f);
		} else if (LR_ISNUM(&base[i])) {
			if (base[i].tt == LR_INT)
				fprintf(f, "%lld", base[i].v.i);
			else {
				snprintf(buf, sizeof buf, "%.14g", base[i].v.n);
				fputs(buf, f);
			}
		} else {
			typeerror(self, i, "string", &base[i]);
		}
	}
	return 0;
}

static TValue stdoutv;

BUILTIN(io_write)
{
	writeall(self, base, nargs, 0, stdout);
	TValue r = stdoutv;

	lr_retain(&r);
	return lr_return(base, nargs, &r, 1);
}

/* f:write(...), for io.stdout and io.stderr */
BUILTIN(f_write)
{
	FILE *f = stdout;

	if (nargs > 0 && base[0].tt == LR_UDATA)
		f = *(FILE **)((lr_Udata *)base[0].v.p)->data;
	writeall(self, base, nargs, 1, f);
	return retarg(base, nargs, 0);
}

BUILTIN(f_flush)
{
	(void)self;
	fflush(stdout);
	return ret0(base, nargs);
}

static int readline(TValue *base, int nargs, FILE *f, int keep)
{
	size_t cap = 128, len = 0;
	char *buf = malloc(cap);
	int c = EOF;

	while ((c = getc(f)) != EOF) {
		if (len + 2 > cap) {
			cap *= 2;
			buf = realloc(buf, cap);
		}
		if (c == '\n') {
			if (keep)
				buf[len++] = '\n';
			break;
		}
		buf[len++] = (char)c;
	}
	if (c == EOF && len == 0) {
		TValue r;

		free(buf);
		LR_SETNIL(&r);
		return lr_return(base, nargs, &r, 1);
	}
	lr_Str *s = lr_newstr(buf, len);

	free(buf);
	return retstr(base, nargs, s);
}

static int readall(TValue *base, int nargs, FILE *f)
{
	size_t cap = 4096, len = 0, n;
	char *buf = malloc(cap);

	while ((n = fread(buf + len, 1, cap - len, f)) > 0) {
		len += n;
		if (len == cap) {
			cap *= 2;
			buf = realloc(buf, cap);
		}
	}
	lr_Str *s = lr_newstr(buf, len);

	free(buf);
	return retstr(base, nargs, s);
}

static int readfmt(lr_Closure *self, TValue *base, int nargs, int i,
		   FILE *f)
{
	if (i >= nargs)
		return readline(base, nargs, f, 0);
	if (base[i].tt == LR_STR) {
		const char *fmt = ((lr_Str *)base[i].v.p)->s;

		if (*fmt == '*')
			fmt++;
		if (*fmt == 'l')
			return readline(base, nargs, f, 0);
		if (*fmt == 'L')
			return readline(base, nargs, f, 1);
		if (*fmt == 'a')
			return readall(base, nargs, f);
		if (*fmt == 'n') {
			double d;

			if (fscanf(f, "%lf", &d) == 1) {
				lr_Int k;

				if (lr_numtoint(d, &k) && d == (double)k &&
				    0)
					return retint(base, nargs, k);
				return retnum(base, nargs, d);
			}
			TValue r;

			LR_SETNIL(&r);
			return lr_return(base, nargs, &r, 1);
		}
		argerror(self, i, "invalid format");
	}
	lr_Int n = lr_checkint(self, base, nargs, i);
	char *buf = malloc(n + 1);
	size_t got = fread(buf, 1, n, f);

	if (got == 0 && n > 0) {
		TValue r;

		free(buf);
		LR_SETNIL(&r);
		return lr_return(base, nargs, &r, 1);
	}
	lr_Str *s = lr_newstr(buf, got);

	free(buf);
	return retstr(base, nargs, s);
}

BUILTIN(io_read)
{
	return readfmt(self, base, nargs, 0, stdin);
}

BUILTIN(f_read)
{
	return readfmt(self, base, nargs, 1, stdin);
}

BUILTIN(os_time)
{
	(void)self;
	if (nargs > 0 && base[0].tt == LR_TAB) {
		struct tm tm;
		lr_Table *t = base[0].v.p;
		const TValue *v;

		memset(&tm, 0, sizeof tm);
#define FIELD(name, f, def, adj)					\
		v = lr_rawgets(t, name);				\
		tm.f = v->tt == LR_INT ? (int)(v->v.i - adj) : def;
		FIELD("year", tm_year, 70, 1900)
		FIELD("month", tm_mon, 0, 1)
		FIELD("day", tm_mday, 1, 0)
		FIELD("hour", tm_hour, 12, 0)
		FIELD("min", tm_min, 0, 0)
		FIELD("sec", tm_sec, 0, 0)
#undef FIELD
		tm.tm_isdst = -1;
		return retint(base, nargs, (lr_Int)mktime(&tm));
	}
	return retint(base, nargs, (lr_Int)time(NULL));
}

BUILTIN(os_clock)
{
	(void)self;
	return retnum(base, nargs, (lr_Num)clock() / CLOCKS_PER_SEC);
}

BUILTIN(os_date)
{
	const char *fmt = nargs > 0 && base[0].tt == LR_STR ?
		((lr_Str *)base[0].v.p)->s : "%c";
	time_t t = nargs > 1 ? (time_t)lr_checkint(self, base, nargs, 1)
			     : time(NULL);
	struct tm *tm;
	char buf[256];

	if (*fmt == '!') {
		tm = gmtime(&t);
		fmt++;
	} else {
		tm = localtime(&t);
	}
	if (strncmp(fmt, "*t", 2) == 0) {
		lr_Table *r = lr_tnew(0, 9);
		TValue v;

		setint(r, "year", tm->tm_year + 1900);
		setint(r, "month", tm->tm_mon + 1);
		setint(r, "day", tm->tm_mday);
		setint(r, "hour", tm->tm_hour);
		setint(r, "min", tm->tm_min);
		setint(r, "sec", tm->tm_sec);
		setint(r, "wday", tm->tm_wday + 1);
		setint(r, "yday", tm->tm_yday + 1);
		LR_SETBOOL(&v, tm->tm_isdst > 0);
		lr_rawsets(r, "isdst", &v);
		r->rc = 1;
		LR_SETOBJ(&v, r, LR_TAB);
		return lr_return(base, nargs, &v, 1);
	}
	size_t n = strftime(buf, sizeof buf, fmt, tm);

	return retstr(base, nargs, lr_newstr(buf, n));
}

BUILTIN(os_getenv)
{
	TValue r;

	if (nargs < 1 || base[0].tt != LR_STR)
		typeerror(self, 0, "string", (TValue *)LR_ARG(0));
	const char *v = getenv(((lr_Str *)base[0].v.p)->s);

	if (!v) {
		LR_SETNIL(&r);
		return lr_return(base, nargs, &r, 1);
	}
	return retstr(base, nargs, lr_cstr(v));
}

BUILTIN(os_exit)
{
	int st = 0;

	(void)self;
	if (nargs > 0) {
		if (base[0].tt == LR_TRUE)
			st = 0;
		else if (base[0].tt == LR_FALSE)
			st = 1;
		else if (base[0].tt == LR_INT)
			st = (int)base[0].v.i;
	}
	fflush(stdout);
	exit(st);
}

BUILTIN(os_remove)
{
	if (nargs < 1 || base[0].tt != LR_STR)
		typeerror(self, 0, "string", (TValue *)LR_ARG(0));
	return retbool(base, nargs, remove(((lr_Str *)base[0].v.p)->s) == 0);
}

/* the whole ---------------------------------------------------------------- */

static lr_Closure *builtin(const char *name, lr_Fn fn)
{
	lr_Closure *c = malloc(sizeof *c);

	c->rc = LR_IMMORTAL;
	c->tt = LR_FN;
	c->nup = 0;
	c->fn = fn;
	c->name = name;
	return c;
}

static TValue stdfile(lr_Table *mt, FILE *f)
{
	lr_Udata *u = malloc(sizeof *u + sizeof f);
	TValue v;

	u->rc = LR_IMMORTAL;
	u->tt = LR_UDATA;
	u->mt = mt;
	mt->rc++;
	u->len = sizeof f;
	u->free = NULL;
	memcpy(u->data, &f, sizeof f);
	LR_SETOBJ(&v, u, LR_UDATA);
	return v;
}

void lr_openlibs(lr_Table *g)
{
	TValue gv;

	LR_SETOBJ(&gv, g, LR_TAB);
	lr_rawsets(g, "_G", &gv);
	{
		TValue v;

		lr_setstr(&v, lr_cstr("Lua 5.4"));
		lr_rawsets(g, "_VERSION", &v);
		lr_release(&v);
	}
	reg(g, "print", b_print);
	reg(g, "type", b_type);
	reg(g, "tostring", b_tostring);
	reg(g, "tonumber", b_tonumber);
	reg(g, "rawequal", b_rawequal);
	reg(g, "rawlen", b_rawlen);
	reg(g, "rawget", b_rawget);
	reg(g, "rawset", b_rawset);
	reg(g, "setmetatable", b_setmetatable);
	reg(g, "getmetatable", b_getmetatable);
	reg(g, "assert", b_assert);
	reg(g, "error", b_error);
	reg(g, "pcall", b_pcall);
	reg(g, "xpcall", b_xpcall);
	reg(g, "next", b_next);
	reg(g, "pairs", b_pairs);
	reg(g, "ipairs", b_ipairs);
	reg(g, "select", b_select);
	reg(g, "collectgarbage", b_collectgarbage);
	nextfn = builtin("next", b_next);
	ipairsauxfn = builtin("ipairs_aux", b_ipairsaux);

	lr_Table *t = newlib(g, "table");

	reg(t, "insert", t_insert);
	reg(t, "remove", t_remove);
	reg(t, "concat", t_concat);
	reg(t, "unpack", b_unpack);
	reg(t, "pack", t_pack);
	reg(t, "sort", t_sort);
	reg(t, "move", t_move);

	lr_Table *m = newlib(g, "math");

	reg(m, "sqrt", m_sqrt);
	reg(m, "sin", m_sin);
	reg(m, "cos", m_cos);
	reg(m, "tan", m_tan);
	reg(m, "asin", m_asin);
	reg(m, "acos", m_acos);
	reg(m, "atan", m_atan);
	reg(m, "exp", m_exp);
	reg(m, "log", m_log);
	reg(m, "floor", m_floor);
	reg(m, "ceil", m_ceil);
	reg(m, "abs", m_abs);
	reg(m, "max", m_max);
	reg(m, "min", m_min);
	reg(m, "fmod", m_fmod);
	reg(m, "modf", m_modf);
	reg(m, "tointeger", m_tointeger);
	reg(m, "type", m_type);
	reg(m, "ult", m_ult);
	reg(m, "random", m_random);
	reg(m, "randomseed", m_randomseed);
	setnum(m, "pi", 3.141592653589793238462643383279502884);
	setnum(m, "huge", HUGE_VAL);
	setint(m, "maxinteger", INT64_MAX);
	setint(m, "mininteger", INT64_MIN);
	setseed((lr_Unsigned)time(NULL), (lr_Unsigned)(uintptr_t)g);

	lr_Table *io = newlib(g, "io");
	lr_Table *fmt = lr_tnew(0, 4), *fidx = lr_tnew(0, 4);
	TValue fv;

	reg(io, "write", io_write);
	reg(io, "read", io_read);
	reg(fidx, "write", f_write);
	reg(fidx, "flush", f_flush);
	reg(fidx, "read", f_read);
	LR_SETOBJ(&fv, fidx, LR_TAB);
	lr_rawsets(fmt, "__index", &fv);
	{
		TValue n;

		lr_setstr(&n, lr_cstr("FILE*"));
		lr_rawsets(fmt, "__name", &n);
		lr_release(&n);
	}
	stdoutv = stdfile(fmt, stdout);
	lr_rawsets(io, "stdout", &stdoutv);
	{
		TValue e = stdfile(fmt, stderr), i = stdfile(fmt, stdin);

		lr_rawsets(io, "stderr", &e);
		lr_rawsets(io, "stdin", &i);
	}
	reg(io, "flush", f_flush);

	lr_Table *os = newlib(g, "os");

	reg(os, "time", os_time);
	reg(os, "clock", os_clock);
	reg(os, "date", os_date);
	reg(os, "getenv", os_getenv);
	reg(os, "exit", os_exit);
	reg(os, "remove", os_remove);

	lr_openstring(g);
}
