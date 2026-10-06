/* SPDX-License-Identifier: ISC */
/* What the library files share: how a builtin is declared, how it checks
 * its arguments, and how it hands back its results. */
#ifndef LRTAUX_H
#define LRTAUX_H

#include "lrt.h"

#define BUILTIN(name) static int name(lr_Closure *self, TValue *base, \
				      int nargs)

void lr_reg(lr_Table *t, const char *name, lr_Fn fn);
lr_Table *lr_newlib(lr_Table *g, const char *name);
lr_Closure *lr_builtin(const char *name, lr_Fn fn);
_Noreturn void lr_argerror(lr_Closure *self, int i, const char *msg);
_Noreturn void lr_argexpected(lr_Closure *self, TValue *base, int nargs,
			      int i, const char *want);
lr_Str *lr_checkstr(lr_Closure *self, TValue *base, int nargs, int i);
lr_Table *lr_checktable(lr_Closure *self, TValue *base, int nargs, int i);
void lr_checkany(lr_Closure *self, TValue *base, int nargs, int i);
int lr_callf(const TValue *f, TValue *args, int nargs, TValue *out,
	     int nwant);

static inline int lr_ret0(TValue *base, int nargs)
{
	lr_clear(base, nargs);
	return 0;
}

static inline int lr_retint(TValue *base, int nargs, lr_Int i)
{
	TValue v;

	LR_SETINT(&v, i);
	return lr_return(base, nargs, &v, 1);
}

static inline int lr_retnum(TValue *base, int nargs, lr_Num n)
{
	TValue v;

	LR_SETFLT(&v, n);
	return lr_return(base, nargs, &v, 1);
}

static inline int lr_retbool(TValue *base, int nargs, int b)
{
	TValue v;

	LR_SETBOOL(&v, b);
	return lr_return(base, nargs, &v, 1);
}

static inline int lr_retnil(TValue *base, int nargs)
{
	TValue v;

	LR_SETNIL(&v);
	return lr_return(base, nargs, &v, 1);
}

/* the value at base[i], retained, as one result */
static inline int lr_retarg(TValue *base, int nargs, int i)
{
	TValue v = *LR_ARG(i);

	lr_retain(&v);
	return lr_return(base, nargs, &v, 1);
}

/* a string of count zero, as one result */
static inline int lr_retstr(TValue *base, int nargs, lr_Str *s)
{
	TValue v;

	lr_setstr(&v, s);
	return lr_return(base, nargs, &v, 1);
}

/* nil and a message, the way a library reports a failure */
static inline int lr_retfail(TValue *base, int nargs, const char *msg)
{
	TValue v[2];

	LR_SETNIL(&v[0]);
	lr_setstr(&v[1], lr_cstr(msg));
	return lr_return(base, nargs, v, 2);
}

#endif
