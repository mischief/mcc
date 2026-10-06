/* SPDX-License-Identifier: ISC */
/*
 * package and require, debug, utf8, and what os has that touches files
 * and processes.  require finds only what is already loaded: there is no
 * compiler at run time to load anything else with.  debug answers what it
 * can without a view of the stack.
 */
#define _POSIX_C_SOURCE 200809L
#include "lrtaux.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/wait.h>

static lr_Table *loaded;

/* package ---------------------------------------------------------------- */

BUILTIN(b_require)
{
	lr_Str *name = lr_checkstr(self, base, nargs, 0);
	const TValue *m = lr_rawget(loaded, &base[0]);

	if (m->tt != LR_NIL) {
		TValue r = *m;

		lr_retain(&r);
		return lr_return(base, nargs, &r, 1);
	}
	lr_error("module '%s' not found:\n\tno field package.preload['%s']",
		 name->s, name->s);
}

/* debug ------------------------------------------------------------------ */

BUILTIN(d_traceback)
{
	if (nargs > 0 && base[0].tt != LR_STR && base[0].tt != LR_NIL &&
	    !LR_ISNUM(&base[0]))
		return lr_retarg(base, nargs, 0);
	const char *msg = nargs > 0 && base[0].tt == LR_STR ?
		((lr_Str *)base[0].v.p)->s : NULL;
	char buf[1024];

	snprintf(buf, sizeof buf, "%s%sstack traceback:\n\t[C]: in ?",
		 msg ? msg : "", msg ? "\n" : "");
	return lr_retstr(base, nargs, lr_cstr(buf));
}

static void setfield(lr_Table *t, const char *k, TValue *v)
{
	lr_rawsets(t, k, v);
	lr_release(v);
}

BUILTIN(d_getinfo)
{
	lr_Table *t = lr_tnew(0, 16);
	TValue v, r;
	int isfn = nargs > 0 && base[0].tt == LR_FN;

	(void)self;
	if (!isfn && nargs > 0 && base[0].tt == LR_INT && base[0].v.i > 50) {
		t->rc = 1;
		lr_free((lr_Obj *)t);
		return lr_retnil(base, nargs);
	}
	lr_setstr(&v, lr_cstr("=?"));
	setfield(t, "source", &v);
	lr_setstr(&v, lr_cstr("?"));
	setfield(t, "short_src", &v);
	lr_setstr(&v, lr_cstr("Lua"));
	setfield(t, "what", &v);
	LR_SETINT(&v, lr_curline);
	setfield(t, "currentline", &v);
	LR_SETINT(&v, -1);
	setfield(t, "linedefined", &v);
	setfield(t, "lastlinedefined", &v);
	LR_SETINT(&v, 0);
	setfield(t, "nups", &v);
	setfield(t, "nparams", &v);
	LR_SETBOOL(&v, 1);
	setfield(t, "isvararg", &v);
	LR_SETBOOL(&v, 0);
	setfield(t, "istailcall", &v);
	if (isfn) {
		v = base[0];
		lr_retain(&v);
		setfield(t, "func", &v);
	}
	t->rc = 1;
	LR_SETOBJ(&r, t, LR_TAB);
	return lr_return(base, nargs, &r, 1);
}

BUILTIN(d_nil)
{
	(void)self;
	return lr_retnil(base, nargs);
}

BUILTIN(d_none)
{
	(void)self;
	return lr_ret0(base, nargs);
}

BUILTIN(d_getmetatable)
{
	lr_checkany(self, base, nargs, 0);
	lr_Table *mt = lr_getmt(&base[0]);
	TValue r;

	if (!mt)
		return lr_retnil(base, nargs);
	LR_SETOBJ(&r, mt, LR_TAB);
	lr_retain(&r);
	return lr_return(base, nargs, &r, 1);
}

BUILTIN(d_setmetatable)
{
	lr_Table *mt = nargs > 1 && base[1].tt == LR_TAB ? base[1].v.p : NULL;

	if (nargs < 2 || (base[1].tt != LR_NIL && base[1].tt != LR_TAB))
		lr_argexpected(self, base, nargs, 1, "nil or table");
	if (base[0].tt == LR_TAB) {
		lr_Table *t = base[0].v.p;

		if (mt)
			mt->rc++;
		if (t->mt && --t->mt->rc == 0)
			lr_free((lr_Obj *)t->mt);
		t->mt = mt;
	} else if (base[0].tt == LR_STR) {
		if (mt)
			mt->rc = LR_IMMORTAL;
		lr_strmt = mt;
	} else if (base[0].tt == LR_UDATA) {
		lr_Udata *u = base[0].v.p;

		if (mt)
			mt->rc++;
		if (u->mt && --u->mt->rc == 0)
			lr_free((lr_Obj *)u->mt);
		u->mt = mt;
	} else {
		lr_error("cannot set the metatable of a %s here",
			 lr_typename(&base[0]));
	}
	return lr_retarg(base, nargs, 0);
}

/* utf8, after lutf8lib.c ------------------------------------------------- */

#define MAXUNICODE 0x10FFFFu
#define MAXUTF 0x7FFFFFFFu
#define iscont(c) (((c) & 0xC0) == 0x80)
#define iscontp(p) iscont(*(p))
#define MSGINVALID "invalid UTF-8 code"

typedef unsigned int utfint;

static lr_Int u_posrelat(lr_Int pos, size_t len)
{
	if (pos >= 0)
		return pos;
	if (0u - (size_t)pos > len)
		return 0;
	return (lr_Int)len + pos + 1;
}

static const char *utf8_decode(const char *s, utfint *val, int strict)
{
	static const utfint limits[] = {
		~(utfint)0, 0x80, 0x800, 0x10000u, 0x200000u, 0x4000000u};
	unsigned int c = (unsigned char)s[0];
	utfint res = 0;

	if (c < 0x80) {
		res = c;
	} else {
		int count = 0;

		for (; c & 0x40; c <<= 1) {
			unsigned int cc = (unsigned char)s[++count];

			if (!iscont(cc))
				return NULL;
			res = (res << 6) | (cc & 0x3F);
		}
		res |= ((utfint)(c & 0x7F) << (count * 5));
		if (count > 5 || res > MAXUTF || res < limits[count])
			return NULL;
		s += count;
	}
	if (strict && (res > MAXUNICODE || (0xD800u <= res && res <= 0xDFFFu)))
		return NULL;
	if (val)
		*val = res;
	return s + 1;
}

static int toboolean(TValue *base, int nargs, int i)
{
	return i < nargs && !LR_ISFALSE(&base[i]);
}

BUILTIN(u_len)
{
	lr_Str *str = lr_checkstr(self, base, nargs, 0);
	const char *s = str->s;
	size_t len = str->len;
	lr_Int n = 0;
	lr_Int posi = u_posrelat(lr_optint(self, base, nargs, 1, 1), len);
	lr_Int posj = u_posrelat(lr_optint(self, base, nargs, 2, -1), len);
	int lax = toboolean(base, nargs, 3);

	if (!(1 <= posi && --posi <= (lr_Int)len))
		lr_argerror(self, 1, "initial position out of bounds");
	if (!(--posj < (lr_Int)len))
		lr_argerror(self, 2, "final position out of bounds");
	while (posi <= posj) {
		const char *s1 = utf8_decode(s + posi, NULL, !lax);

		if (s1 == NULL) {
			TValue r[2];

			LR_SETNIL(&r[0]);
			LR_SETINT(&r[1], posi + 1);
			return lr_return(base, nargs, r, 2);
		}
		posi = s1 - s;
		n++;
	}
	return lr_retint(base, nargs, n);
}

BUILTIN(u_codepoint)
{
	lr_Str *str = lr_checkstr(self, base, nargs, 0);
	const char *s = str->s, *se;
	size_t len = str->len;
	lr_Int posi = u_posrelat(lr_optint(self, base, nargs, 1, 1), len);
	lr_Int pose = u_posrelat(lr_optint(self, base, nargs, 2, posi), len);
	int lax = toboolean(base, nargs, 3);
	int n = 0;

	if (posi < 1)
		lr_argerror(self, 1, "out of bounds");
	if (pose > (lr_Int)len)
		lr_argerror(self, 2, "out of bounds");
	if (posi > pose)
		return lr_ret0(base, nargs);
	if (pose - posi >= 1000000)
		lr_error("string slice too long");
	TValue *out = base + nargs;

	if (out + (pose - posi) + 2 >= lr_stackend)
		lr_error("string slice too long");
	se = s + pose;
	for (s += posi - 1; s < se;) {
		utfint code;

		s = utf8_decode(s, &code, !lax);
		if (s == NULL)
			lr_error(MSGINVALID);
		lr_setint(&out[n++], code);
	}
	lr_clear(base, nargs);
	memmove(base, out, n * sizeof(TValue));
	for (TValue *p = base + n > out ? base + n : out; p < out + n; p++)
		LR_SETNIL(p);
	return n;
}

static int utf8esc(char *buff, unsigned long x)
{
	int n = 1;

	if (x < 0x80) {
		buff[7] = (char)x;
	} else {
		unsigned int mfb = 0x3f;

		do {
			buff[8 - (n++)] = (char)(0x80 | (x & 0x3f));
			x >>= 6;
			mfb >>= 1;
		} while (x > mfb);
		buff[8 - n] = (char)((~mfb << 1) | x);
	}
	return n;
}

BUILTIN(u_char)
{
	char *buf = malloc(nargs * 8 + 1);
	size_t len = 0;

	for (int i = 0; i < nargs; i++) {
		lr_Unsigned code = (lr_Unsigned)lr_checkint(self, base, nargs, i);
		char b[8];

		if (code > MAXUTF)
			lr_argerror(self, i, "value out of range");
		int n = utf8esc(b, (unsigned long)code);

		memcpy(buf + len, b + 8 - n, n);
		len += n;
	}
	lr_Str *s = lr_newstr(buf, len);

	free(buf);
	return lr_retstr(base, nargs, s);
}

BUILTIN(u_offset)
{
	lr_Str *str = lr_checkstr(self, base, nargs, 0);
	const char *s = str->s;
	size_t len = str->len;
	lr_Int n = lr_checkint(self, base, nargs, 1);
	lr_Int posi = n >= 0 ? 1 : (lr_Int)len + 1;

	posi = u_posrelat(lr_optint(self, base, nargs, 2, posi), len);
	if (!(1 <= posi && --posi <= (lr_Int)len))
		lr_argerror(self, 2, "position out of bounds");
	if (n == 0) {
		while (posi > 0 && iscontp(s + posi))
			posi--;
	} else {
		if (iscontp(s + posi))
			lr_error("initial position is a continuation byte");
		if (n < 0) {
			while (n < 0 && posi > 0) {
				do {
					posi--;
				} while (posi > 0 && iscontp(s + posi));
				n++;
			}
		} else {
			n--;
			while (n > 0 && posi < (lr_Int)len) {
				do {
					posi++;
				} while (iscontp(s + posi));
				n--;
			}
		}
	}
	if (n == 0)
		return lr_retint(base, nargs, posi + 1);
	return lr_retnil(base, nargs);
}

static int iteraux(lr_Closure *self, TValue *base, int nargs, int strict)
{
	lr_Str *str = lr_checkstr(self, base, nargs, 0);
	const char *s = str->s;
	size_t len = str->len;
	lr_Unsigned n = nargs > 1 && base[1].tt == LR_INT ?
		(lr_Unsigned)base[1].v.i : 0;

	if (n < len) {
		while (iscontp(s + n))
			n++;
	}
	if (n >= len)
		return lr_ret0(base, nargs);
	utfint code;
	const char *next = utf8_decode(s + n, &code, strict);

	if (next == NULL || iscontp(next))
		lr_error(MSGINVALID);
	TValue r[2];

	LR_SETINT(&r[0], (lr_Int)n + 1);
	LR_SETINT(&r[1], code);
	return lr_return(base, nargs, r, 2);
}

BUILTIN(u_iterstrict)
{
	return iteraux(self, base, nargs, 1);
}

BUILTIN(u_iterlax)
{
	return iteraux(self, base, nargs, 0);
}

static lr_Closure *iterstrict, *iterlax;

BUILTIN(u_codes)
{
	int lax = toboolean(base, nargs, 1);
	lr_Str *s = lr_checkstr(self, base, nargs, 0);
	TValue r[3];

	if (iscontp(s->s))
		lr_argerror(self, 0, MSGINVALID);
	LR_SETOBJ(&r[0], lax ? iterlax : iterstrict, LR_FN);
	r[1] = base[0];
	lr_retain(&r[1]);
	LR_SETINT(&r[2], 0);
	return lr_return(base, nargs, r, 3);
}

/* os ------------------------------------------------------------------------ */

BUILTIN(os_tmpname)
{
	char name[] = "/tmp/lua_XXXXXX";
	int fd = mkstemp(name);

	(void)self;
	if (fd == -1)
		lr_error("unable to generate a unique filename");
	close(fd);
	return lr_retstr(base, nargs, lr_cstr(name));
}

BUILTIN(os_execute)
{
	if (nargs == 0 || base[0].tt == LR_NIL)
		return lr_retbool(base, nargs, system(NULL) != 0);
	lr_Str *cmd = lr_checkstr(self, base, nargs, 0);

	fflush(NULL);
	int st = system(cmd->s);
	TValue r[3];

	if (st == -1) {
		LR_SETNIL(&r[0]);
		lr_setstr(&r[1], lr_cstr(strerror(errno)));
		LR_SETINT(&r[2], errno);
		return lr_return(base, nargs, r, 3);
	}
	if (WIFEXITED(st)) {
		st = WEXITSTATUS(st);
		lr_setstr(&r[1], lr_cstr("exit"));
	} else {
		st = WIFSIGNALED(st) ? WTERMSIG(st) : st;
		lr_setstr(&r[1], lr_cstr("signal"));
	}
	if (st == 0 && r[1].v.p && ((lr_Str *)r[1].v.p)->s[0] == 'e')
		LR_SETBOOL(&r[0], 1);
	else
		LR_SETNIL(&r[0]);
	LR_SETINT(&r[2], st);
	return lr_return(base, nargs, r, 3);
}

BUILTIN(os_rename)
{
	lr_Str *a = lr_checkstr(self, base, nargs, 0);
	lr_Str *b = lr_checkstr(self, base, nargs, 1);

	if (rename(a->s, b->s) == 0)
		return lr_retbool(base, nargs, 1);
	char msg[512];

	snprintf(msg, sizeof msg, "%s: %s", a->s, strerror(errno));
	return lr_retfail(base, nargs, msg);
}

BUILTIN(os_remove)
{
	lr_Str *a = lr_checkstr(self, base, nargs, 0);

	if (remove(a->s) == 0)
		return lr_retbool(base, nargs, 1);
	char msg[512];
	TValue r[3];

	snprintf(msg, sizeof msg, "%s: %s", a->s, strerror(errno));
	LR_SETNIL(&r[0]);
	lr_setstr(&r[1], lr_cstr(msg));
	LR_SETINT(&r[2], errno);
	return lr_return(base, nargs, r, 3);
}

BUILTIN(os_difftime)
{
	lr_Int a = lr_checkint(self, base, nargs, 0);
	lr_Int b = lr_optint(self, base, nargs, 1, 0);

	return lr_retnum(base, nargs, difftime((time_t)a, (time_t)b));
}

/* the whole ---------------------------------------------------------------- */

void lr_openpkg(lr_Table *g)
{
	lr_Table *pkg = lr_newlib(g, "package");
	TValue v;
	static const char *const libs[] = {
		"_G", "string", "table", "math", "io", "os", "package",
		"debug", "utf8", "coroutine",
	};

	lr_reg(g, "require", b_require);
	loaded = lr_tnew(0, 16);
	LR_SETOBJ(&v, loaded, LR_TAB);
	lr_rawsets(pkg, "loaded", &v);
	lr_setstr(&v, lr_cstr("/\n;\n?\n!\n-\n"));
	setfield(pkg, "config", &v);
	lr_setstr(&v, lr_cstr("./?.lua"));
	setfield(pkg, "path", &v);
	lr_setstr(&v, lr_cstr("./?.so"));
	setfield(pkg, "cpath", &v);
	{
		lr_Table *pre = lr_tnew(0, 1);

		LR_SETOBJ(&v, pre, LR_TAB);
		lr_rawsets(pkg, "preload", &v);
	}

	lr_Table *d = lr_newlib(g, "debug");

	lr_reg(d, "traceback", d_traceback);
	lr_reg(d, "getinfo", d_getinfo);
	lr_reg(d, "getlocal", d_nil);
	lr_reg(d, "setlocal", d_nil);
	lr_reg(d, "getupvalue", d_nil);
	lr_reg(d, "setupvalue", d_nil);
	lr_reg(d, "upvalueid", d_nil);
	lr_reg(d, "upvaluejoin", d_none);
	lr_reg(d, "sethook", d_none);
	lr_reg(d, "gethook", d_nil);
	lr_reg(d, "getregistry", d_nil);
	lr_reg(d, "getuservalue", d_nil);
	lr_reg(d, "setuservalue", d_nil);
	lr_reg(d, "setcstacklimit", d_nil);
	lr_reg(d, "getmetatable", d_getmetatable);
	lr_reg(d, "setmetatable", d_setmetatable);

	lr_Table *u = lr_newlib(g, "utf8");

	lr_reg(u, "len", u_len);
	lr_reg(u, "codepoint", u_codepoint);
	lr_reg(u, "char", u_char);
	lr_reg(u, "offset", u_offset);
	lr_reg(u, "codes", u_codes);
	lr_setstr(&v, lr_newstr("[\0-\x7F\xC2-\xFD][\x80-\xBF]*", 14));
	setfield(u, "charpattern", &v);
	iterstrict = lr_builtin("codes", u_iterstrict);
	iterlax = lr_builtin("codes", u_iterlax);

	const TValue *os = lr_rawgets(g, "os");

	if (os->tt == LR_TAB) {
		lr_reg(os->v.p, "tmpname", os_tmpname);
		lr_reg(os->v.p, "execute", os_execute);
		lr_reg(os->v.p, "rename", os_rename);
		lr_reg(os->v.p, "remove", os_remove);
		lr_reg(os->v.p, "difftime", os_difftime);
	}
	for (size_t i = 0; i < sizeof libs / sizeof libs[0]; i++) {
		const TValue *l = lr_rawgets(g, libs[i]);

		if (l->tt != LR_NIL)
			lr_rawsets(loaded, libs[i], l);
	}
}
