/* SPDX-License-Identifier: ISC */
/*
 * The runtime of Lua compiled by mcc, with reference counting in place of
 * a collector.
 *
 * Every Lua value is a TValue: eight bytes of payload, then a tag.  A
 * value lives in a slot of the value stack, a table, a box or a closure;
 * compiled code never holds one in a machine register, only the address of
 * the slot it is in.  So everything a program can reach is somewhere this
 * runtime can see, which is what an error unwinding the stack, or a cycle
 * collector looking for roots, would need.
 *
 * A slot owns what it holds.  Writing a slot retains the new value and
 * releases the old one, in that order, so that x = x is safe; a slot is
 * never overwritten without its old value being released, except where it
 * is known to hold nothing.
 *
 * A compiled function, and a builtin, is
 *
 *	int f(lr_Closure *self, TValue *base, int nargs)
 *
 * with its arguments in base[0..nargs) and its frame from base upward.  It
 * leaves its results in base[0..n), every other slot of its frame nil, and
 * returns n.
 */
#ifndef LRT_H
#define LRT_H

#include <stddef.h>
#include <stdint.h>

typedef long long lr_Int;
typedef unsigned long long lr_Unsigned;
typedef double lr_Num;

/* Tags.  Those from LR_STR up are counted. */
enum {
	LR_NIL = 0, LR_FALSE = 1, LR_TRUE = 2, LR_INT = 3, LR_FLT = 4,
	LR_LIGHT = 5,
	LR_STR = 8, LR_TAB = 9, LR_FN = 10, LR_BOX = 11, LR_UDATA = 12,
	LR_THREAD = 13,
};

#define LR_COUNTED(tt) ((tt) >= LR_STR)

typedef struct TValue {
	union {
		lr_Int i;
		lr_Num n;
		void *p;
	} v;
	int tt;
	int pad;
} TValue;

/*
 * Every counted object starts with this.  An object the compiler wrote
 * into the data section starts with a count so large it never reaches
 * zero, and is never freed.
 */
typedef struct lr_Obj {
	intptr_t rc;
	int tt;
} lr_Obj;

#define LR_IMMORTAL ((intptr_t)1 << (sizeof(intptr_t) * 8 - 2))

typedef struct lr_Str {
	intptr_t rc;
	int tt;
	unsigned hash;		/* 0 until it is asked for */
	size_t len;
	char s[1];		/* len bytes, then a NUL */
} lr_Str;

typedef struct lr_Node {
	TValue key, val;
} lr_Node;

/* Compiled code reads arr and asize in place: mcc/lua/code.lua's
 * tabfields says where they are, and has to agree with this. */
typedef struct lr_Table {
	intptr_t rc;
	int tt;
	int flags;
	TValue *arr;		/* keys 1..asize */
	lr_Int asize;
	lr_Node *node;		/* open addressing, hcap a power of two */
	lr_Int hcap, hused;
	struct lr_Table *mt;
} lr_Table;

/* Compiled code reaches a box's value, and a closure's function and
 * upvalues, in place: mcc/lua/code.lua's layout says where they are. */
typedef struct lr_Box {
	intptr_t rc;
	int tt;
	TValue v;
} lr_Box;

struct lr_Closure;
typedef int (*lr_Fn)(struct lr_Closure *, TValue *, int);

typedef struct lr_Closure {
	intptr_t rc;
	int tt;
	int nup;
	lr_Fn fn;
	const char *name;
	lr_Box *up[1];
} lr_Closure;

typedef struct lr_Udata {
	intptr_t rc;
	int tt;
	lr_Table *mt;
	size_t len;
	void (*free)(void *);
	char data[1];
} lr_Udata;

/* The value stack, and the first slot nothing live is at or above. */
extern TValue *lr_stack, *lr_stackend, *lr_top;

/* counting */
void *lr_newobj(size_t n, int tt);
void lr_free(lr_Obj *o);

static inline void lr_retain(const TValue *v)
{
	if (LR_COUNTED(v->tt))
		((lr_Obj *)v->v.p)->rc++;
}

static inline void lr_release(TValue *v)
{
	if (LR_COUNTED(v->tt)) {
		lr_Obj *o = (lr_Obj *)v->v.p;

		if (--o->rc == 0)
			lr_free(o);
	}
}

/* Take a value of count one into a slot, releasing what it held. */
static inline void lr_store(TValue *dst, TValue *v)
{
	TValue old = *dst;

	*dst = *v;
	lr_release(&old);
}

#define LR_SETNIL(o) ((o)->tt = LR_NIL, (o)->v.i = 0)
#define LR_SETINT(o, x) ((o)->tt = LR_INT, (o)->v.i = (x))
#define LR_SETFLT(o, x) ((o)->tt = LR_FLT, (o)->v.n = (x))
#define LR_SETBOOL(o, b) ((o)->tt = (b) ? LR_TRUE : LR_FALSE, (o)->v.i = 0)
#define LR_SETOBJ(o, x, t) ((o)->tt = (t), (o)->v.p = (x))
#define LR_ISFALSE(o) ((o)->tt <= LR_FALSE)
#define LR_ISNUM(o) ((o)->tt == LR_INT || (o)->tt == LR_FLT)

/* Copy a value into a slot: count the new, then let go of the old. */
static inline void lr_move(TValue *dst, const TValue *src)
{
	TValue old = *dst;

	lr_retain(src);
	*dst = *src;
	lr_release(&old);
}

static inline void lr_setint(TValue *dst, lr_Int i)
{
	TValue v;

	LR_SETINT(&v, i);
	lr_store(dst, &v);
}

static inline void lr_setbool(TValue *dst, int b)
{
	TValue v;

	LR_SETBOOL(&v, b);
	lr_store(dst, &v);
}

/*
 * What compiled code calls.  Copying, counting and letting go of a value,
 * and reaching a box or an upvalue, it does itself; only lr_free is
 * called for those.
 */
void lr_clear(TValue *from, int n);
void lr_enter(TValue *base, int nargs, int np, int nslots);
TValue *lr_venter(TValue *base, int nargs, int np, int nslots);
int lr_ret(TValue *lo, TValue *hi, TValue *src, int n);
int lr_call(TValue *fa, int nargs, int nwant);
int lr_callret(TValue *fa, int n, int nwant);
int lr_varargs(TValue *dst, TValue *src, int nvar, int want);
void lr_self(TValue *fa, TValue *obj, TValue *key);

void lr_newtable(TValue *dst, int narr, int nhash);
void lr_setlist(TValue *t, TValue *src, int n, int first);
lr_Closure *lr_closure(TValue *dst, lr_Fn fn, int nup, const char *name);
void lr_upfromval(lr_Closure *c, int i, TValue *v);
void lr_newbox(TValue *dst, TValue *init);
void lr_upindex(TValue *dst, lr_Closure *c, int i, TValue *k);
void lr_upsetindex(lr_Closure *c, int i, TValue *k, TValue *v);

void lr_index(TValue *dst, TValue *t, TValue *k);
void lr_setindex(TValue *t, TValue *k, TValue *v);
void lr_arith(TValue *dst, TValue *a, TValue *b, int op);
void lr_unm(TValue *dst, TValue *a);
void lr_bnot(TValue *dst, TValue *a);
void lr_len(TValue *dst, TValue *a);
void lr_concat(TValue *dst, TValue *first, int n);
int lr_eq(TValue *a, TValue *b);
int lr_lt(TValue *a, TValue *b);
int lr_le(TValue *a, TValue *b);
int lr_forprep(TValue *ra);
int lr_forloop(TValue *ra);
void lr_line(int line);
void lr_tbc(TValue *v, TValue *name);
void lr_close(TValue *v);
void lr_closeto(TValue *level, TValue *err);
extern TValue **lr_tbcv;
extern int lr_tbcn, lr_tbccap;

enum {
	LR_OPADD, LR_OPSUB, LR_OPMUL, LR_OPMOD, LR_OPPOW, LR_OPDIV,
	LR_OPIDIV, LR_OPBAND, LR_OPBOR, LR_OPBXOR, LR_OPSHL, LR_OPSHR,
	LR_OPUNM, LR_OPBNOT,
};

/* for the library */
lr_Str *lr_newstr(const char *s, size_t len);
lr_Str *lr_cstr(const char *s);
void lr_setstr(TValue *o, lr_Str *s);
unsigned lr_strhash(lr_Str *s);
int lr_streq(lr_Str *a, lr_Str *b);
lr_Table *lr_tnew(lr_Int narr, lr_Int nhash);
const TValue *lr_rawget(lr_Table *t, const TValue *k);
const TValue *lr_rawgetstr(lr_Table *t, lr_Str *s);
const TValue *lr_rawgeti(lr_Table *t, lr_Int i);
const TValue *lr_rawgets(lr_Table *t, const char *k);
void lr_rawset(lr_Table *t, const TValue *k, const TValue *v);
void lr_rawseti(lr_Table *t, lr_Int i, const TValue *v);
void lr_rawsets(lr_Table *t, const char *k, const TValue *v);
lr_Int lr_rawlen(lr_Table *t);
int lr_next(lr_Table *t, TValue *k, TValue *v);
lr_Table *lr_getmt(const TValue *o);
const TValue *lr_metafield(const TValue *o, const char *event);
int lr_rawequal(const TValue *a, const TValue *b);

lr_Str *lr_tostr(const TValue *v);
int lr_tostring_basic(const TValue *v, char *buf, size_t n);
void lr_tostringmeta(TValue *dst, TValue *v);
int lr_tonumber(const TValue *v, TValue *out);
int lr_str2num(const char *s, size_t len, TValue *out);
int lr_tointeger(const TValue *v, lr_Int *out);
int lr_numtoint(lr_Num n, lr_Int *out);
const char *lr_typename(const TValue *v);
const char *lr_objtypename(const TValue *v);

_Noreturn void lr_error(const char *fmt, ...);
_Noreturn void lr_errorv(TValue *v);
_Noreturn void lr_errorhere(const char *msg);
_Noreturn void lr_typeerror(const TValue *v, const char *op);

/* a builtin's results: put n values from vals at base, release the rest */
int lr_return(TValue *base, int nargs, TValue *vals, int n);

/* What C code holds across a call that may raise lives in these. */
TValue *lr_anchor(int n);
void lr_unanchor(TValue *p);
typedef struct {
	TValue *slot;
	lr_Str *s;
	size_t n, cap;
} lr_SBuf;
void lr_sbinit(lr_SBuf *b);
void lr_sbadd(lr_SBuf *b, const char *p, size_t n);
lr_Str *lr_sbresult(lr_SBuf *b);
void lr_sbdrop(lr_SBuf *b);

/* The innermost protected call.  An error takes the value raised,
 * which it owns, there. */
#include <setjmp.h>
struct lr_jmp {
	jmp_buf b;
	struct lr_jmp *prev;
	TValue err;
};
extern struct lr_jmp *lr_handler;
/* the highest slot the stack has reached since the last unwind */
extern TValue *lr_hiwater;
extern int lr_curline;
extern const char lr_chunkname[];

lr_Int lr_checkint(lr_Closure *self, TValue *base, int nargs, int i);
lr_Int lr_optint(lr_Closure *self, TValue *base, int nargs, int i,
		 lr_Int def);
lr_Num lr_checknum(lr_Closure *self, TValue *base, int nargs, int i);

extern lr_Table *lr_strmt;
extern TValue lr_registry;
void lr_openlibs(lr_Table *g);
void lr_openstring(lr_Table *g);
void lr_openio(lr_Table *g);
void lr_openpkg(lr_Table *g);
void lr_opencoroutine(lr_Table *g);
void lr_runmain(void (*f)(void));
struct lr_Coro;
void lr_freecoro(struct lr_Coro *co);
/* The lowest a C stack may reach before a call is refused, or NULL. */
extern char *lr_climit;

#define LR_ARG(n) (n < nargs ? &base[n] : &lr_nilvalue)
extern const TValue lr_nilvalue;

#endif
