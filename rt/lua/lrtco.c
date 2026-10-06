/* SPDX-License-Identifier: ISC */
/*
 * Coroutines.  Compiled Lua runs on the machine's stack, so a coroutine
 * is a machine context of its own: a C stack, and a value stack beside
 * it.  Resuming one swaps the runtime's notion of where the stack is and
 * the machine context with it; yielding swaps them back.  A frame that
 * yields stays where it is on its coroutine's C stack, which is why a
 * yield may come from anywhere, a pcall or a sort comparator included.
 *
 * The values that cross, the arguments of a resume and of a yield and
 * what a body returns, go through a buffer the coroutine owns.
 *
 * The main chunk runs this way as well, on a C stack far larger than the
 * one the system starts a program with: a recursion the interpreter
 * would make in its own value stack is a recursion of machine frames
 * here.
 */
#define _XOPEN_SOURCE 700
#define _DEFAULT_SOURCE
#include "lrtaux.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

/*
 * The switch itself.  On amd64 it is a few instructions of rt/lua's own,
 * which every System V system runs, OpenBSD among them, and which costs
 * no system call; anywhere else it is ucontext, until the machine has
 * its own.
 */
#if defined(__x86_64__)
#define OWNSWITCH 1
void lr_coswitch(void **save, void *to);
typedef struct { void *sp; } coctx;
#else
#include <ucontext.h>
typedef ucontext_t coctx;
#endif

enum { CO_SUSPENDED, CO_RUNNING, CO_NORMAL, CO_DEAD };

#define CO_CSTACK ((size_t)8 << 20)
#define MAIN_CSTACK ((size_t)512 << 20)
#define CO_VSTACK (1 << 16)
/* Room below the limit for the error the limit raises. */
#define CMARGIN ((size_t)128 << 10)

typedef struct lr_Coro {
	intptr_t rc;
	int tt;
	int status;
	int started, failed;
	coctx ctx;
	struct lr_Coro *prev;		/* who resumed it */
	char *cstack;
	size_t csize;
	/* the runtime's view of the stack while this one is not running */
	TValue *stack, *stackend, *top, *hiwater;
	struct lr_jmp *handler;
	char *climit;
	int line;
	TValue fn;
	/* what crosses: count one each */
	TValue *xv;
	int xn, xcap;
	TValue err;
} lr_Coro;

char *lr_climit;
static lr_Coro mainco;
static lr_Coro *cur = &mainco;

static char *cstack(size_t size)
{
	int flags = MAP_PRIVATE | MAP_ANON;
	char *p;

	/* OpenBSD faults a stack pointer outside a mapping made with
	 * MAP_STACK; Linux only reserves no swap for one marked so */
#ifdef MAP_STACK
	flags |= MAP_STACK;
#endif
#ifdef MAP_NORESERVE
	flags |= MAP_NORESERVE;
#endif
	p = mmap(NULL, size, PROT_READ | PROT_WRITE, flags, -1, 0);

	if (p == MAP_FAILED)
		lr_error("cannot make a coroutine stack");
	/* a guard page at the bottom, which the stack grows towards */
	mprotect(p, 4096, PROT_NONE);
	return p;
}

/* The values from[0..n) move into co's buffer, leaving them nil. */
static void xput(lr_Coro *co, TValue *from, int n)
{
	if (n > co->xcap) {
		co->xcap = n < 8 ? 8 : n;
		co->xv = realloc(co->xv, co->xcap * sizeof(TValue));
		if (!co->xv)
			lr_error("not enough memory");
	}
	for (int i = 0; i < n; i++) {
		co->xv[i] = from[i];
		LR_SETNIL(&from[i]);
	}
	co->xn = n;
}

/* co's buffer moves to to[0..), which must hold nothing counted. */
static int xget(lr_Coro *co, TValue *to)
{
	int n = co->xn;

	for (int i = 0; i < n; i++)
		to[i] = co->xv[i];
	co->xn = 0;
	return n;
}

static void save(lr_Coro *co)
{
	co->stack = lr_stack;
	co->stackend = lr_stackend;
	co->top = lr_top;
	co->hiwater = lr_hiwater;
	co->handler = lr_handler;
	co->climit = lr_climit;
	co->line = lr_curline;
}

static void load(lr_Coro *co)
{
	lr_stack = co->stack;
	lr_stackend = co->stackend;
	lr_top = co->top;
	lr_hiwater = co->hiwater;
	lr_handler = co->handler;
	lr_climit = co->climit;
	lr_curline = co->line;
	cur = co;
}

/* From the running coroutine to another, and back here when something
 * switches to this one again. */
static void switchto(lr_Coro *to)
{
	lr_Coro *from = cur;

	save(from);
	load(to);
#ifdef OWNSWITCH
	lr_coswitch(&from->ctx.sp, to->ctx.sp);
#else
	if (swapcontext(&from->ctx, &to->ctx) != 0)
		lr_error("cannot switch coroutines");
#endif
}

/* A context that starts f on the stack [s, s + size). */
static void coinit(coctx *c, char *s, size_t size, void (*f)(void))
{
#ifdef OWNSWITCH
	/* six registers for the switch to pop, then f as the address its
	 * ret takes, then a word so that f starts as a call would leave
	 * it: the stack pointer eight short of sixteen */
	void **sp = (void **)(((uintptr_t)(s + size) & ~(uintptr_t)15) - 64);

	for (int i = 0; i < 6; i++)
		sp[i] = NULL;
	sp[6] = (void *)f;
	sp[7] = NULL;
	c->sp = sp;
#else
	getcontext(c);
	c->uc_stack.ss_sp = s;
	c->uc_stack.ss_size = size;
	c->uc_link = NULL;
	makecontext(c, f, 0);
#endif
}

/* Release everything a value stack still holds. */
static void unwindstack(lr_Coro *co)
{
	TValue *hi = co == cur ? lr_hiwater : co->hiwater;

	if (hi > co->stack)
		lr_clear(co->stack, (int)(hi - co->stack));
}

/* Where a coroutine starts: its body under a handler of its own, so an
 * error ends the coroutine rather than the program. */
static void coentry(void)
{
	lr_Coro *co = cur;
	struct lr_jmp j;
	volatile int n;

	j.prev = NULL;
	lr_handler = &j;
	if (setjmp(j.b) == 0) {
		TValue *base = lr_stack;

		base[0] = co->fn;
		LR_SETNIL(&co->fn);
		n = xget(co, base + 1);
		lr_top = base + 1 + n;
		if (lr_top > lr_hiwater)
			lr_hiwater = lr_top;
		n = lr_call(base, n, -1);
		lr_handler = NULL;
		xput(co, lr_stack, n);
	} else {
		lr_handler = NULL;
		co->err = j.err;
		co->failed = 1;
		unwindstack(co);
		co->xn = 0;
	}
	co->status = CO_DEAD;
	lr_hiwater = lr_stack;
	co->prev->status = CO_RUNNING;
	switchto(co->prev);
	/* nothing switches to a dead coroutine */
	abort();
}

static lr_Coro *newco(TValue *fn)
{
	lr_Coro *co = lr_newobj(sizeof *co, LR_THREAD);

	memset((char *)co + offsetof(lr_Coro, status), 0,
	       sizeof *co - offsetof(lr_Coro, status));
	co->status = CO_SUSPENDED;
	co->fn = *fn;
	lr_retain(fn);
	co->stack = calloc(CO_VSTACK, sizeof(TValue));
	if (!co->stack)
		lr_error("not enough memory");
	co->stackend = co->stack + CO_VSTACK - 64;
	co->top = co->hiwater = co->stack;
	LR_SETNIL(&co->err);
	return co;
}

void lr_freecoro(lr_Coro *co)
{
	unwindstack(co);
	for (int i = 0; i < co->xn; i++)
		lr_release(&co->xv[i]);
	lr_release(&co->fn);
	lr_release(&co->err);
	free(co->xv);
	free(co->stack);
	if (co->cstack)
		munmap(co->cstack, co->csize);
	free(co);
}

static lr_Coro *checkco(lr_Closure *self, TValue *base, int nargs, int i)
{
	if (i >= nargs || base[i].tt != LR_THREAD)
		lr_argexpected(self, base, nargs, i, "coroutine");
	return base[i].v.p;
}

/* Resume co with base[from..nargs) as what it is handed.  Gives 1 and
 * leaves co's answers in its buffer, or 0 and the error in co->err. */
static int resume(lr_Coro *co, TValue *base, int from, int nargs,
		  const char **why)
{
	if (co->status != CO_SUSPENDED) {
		*why = co->status == CO_DEAD ? "cannot resume dead coroutine"
			: "cannot resume non-suspended coroutine";
		return -1;
	}
	xput(co, base + from, nargs - from);
	if (!co->started) {
		co->started = 1;
		co->csize = CO_CSTACK;
		co->cstack = cstack(co->csize);
		coinit(&co->ctx, co->cstack, co->csize, coentry);
		co->climit = co->cstack + CMARGIN;
	}
	co->prev = cur;
	cur->status = CO_NORMAL;
	co->status = CO_RUNNING;
	switchto(co);
	cur->status = CO_RUNNING;
	return co->failed ? 0 : 1;
}

BUILTIN(co_create)
{
	if (nargs < 1 || base[0].tt != LR_FN)
		lr_argexpected(self, base, nargs, 0, "function");
	lr_Coro *co = newco(&base[0]);
	TValue r;

	co->rc = 1;
	LR_SETOBJ(&r, co, LR_THREAD);
	return lr_return(base, nargs, &r, 1);
}

BUILTIN(co_resume)
{
	lr_Coro *co = checkco(self, base, nargs, 0);
	const char *why;
	int ok;

	/* held while it runs: the only reference may be the argument */
	co->rc++;
	ok = resume(co, base, 1, nargs, &why);
	lr_clear(base, nargs);
	if (ok < 0) {
		if (--co->rc == 0)
			lr_free((lr_Obj *)co);
		LR_SETBOOL(&base[0], 0);
		lr_setstr(&base[1], lr_cstr(why));
		return 2;
	}
	if (base + 1 + co->xn >= lr_stackend)
		lr_error("stack overflow");
	int n;

	if (ok) {
		LR_SETBOOL(&base[0], 1);
		n = 1 + xget(co, base + 1);
	} else {
		LR_SETBOOL(&base[0], 0);
		base[1] = co->err;
		LR_SETNIL(&co->err);
		co->failed = 0;
		n = 2;
	}
	if (--co->rc == 0)
		lr_free((lr_Obj *)co);
	return n;
}

BUILTIN(co_yield)
{
	lr_Coro *co = cur;

	(void)self;
	if (co == &mainco)
		lr_errorhere("attempt to yield from outside a coroutine");
	xput(co, base, nargs);
	co->status = CO_SUSPENDED;
	co->prev->status = CO_RUNNING;
	switchto(co->prev);
	/* resumed: what resume handed over is the answer */
	if (base + co->xn >= lr_stackend)
		lr_error("stack overflow");
	return xget(co, base);
}

static const char *statusname(lr_Coro *co)
{
	if (co == cur)
		return "running";
	switch (co->status) {
	case CO_SUSPENDED: return "suspended";
	case CO_NORMAL: return "normal";
	case CO_DEAD: return "dead";
	}
	return "running";
}

BUILTIN(co_status)
{
	lr_Coro *co = checkco(self, base, nargs, 0);

	return lr_retstr(base, nargs, lr_cstr(statusname(co)));
}

BUILTIN(co_running)
{
	TValue r[2];

	(void)self;
	LR_SETOBJ(&r[0], cur, LR_THREAD);
	lr_retain(&r[0]);
	LR_SETBOOL(&r[1], cur == &mainco);
	return lr_return(base, nargs, r, 2);
}

BUILTIN(co_isyieldable)
{
	lr_Coro *co = nargs > 0 ? checkco(self, base, nargs, 0) : cur;

	return lr_retbool(base, nargs, co != &mainco);
}

BUILTIN(co_close)
{
	lr_Coro *co = checkco(self, base, nargs, 0);

	if (co->status == CO_SUSPENDED || co->status == CO_DEAD) {
		TValue r[2];
		int n = 1;

		unwindstack(co);
		co->hiwater = co->top = co->stack;
		for (int i = 0; i < co->xn; i++)
			lr_release(&co->xv[i]);
		co->xn = 0;
		co->status = CO_DEAD;
		if (co->failed) {
			LR_SETBOOL(&r[0], 0);
			r[1] = co->err;
			LR_SETNIL(&co->err);
			co->failed = 0;
			n = 2;
		} else {
			LR_SETBOOL(&r[0], 1);
		}
		return lr_return(base, nargs, r, n);
	}
	lr_error("cannot close a %s coroutine", statusname(co));
}

/* What coroutine.wrap makes: a function that resumes, and raises what
 * the coroutine raised. */
BUILTIN(co_wrapped)
{
	lr_Coro *co = self->up[0]->v.v.p;
	const char *why;
	int ok;

	co->rc++;
	ok = resume(co, base, 0, nargs, &why);
	lr_clear(base, nargs);
	if (ok < 0) {
		if (--co->rc == 0)
			lr_free((lr_Obj *)co);
		lr_error("%s", why);
	}
	if (!ok) {
		TValue e = co->err;

		LR_SETNIL(&co->err);
		co->failed = 0;
		if (--co->rc == 0)
			lr_free((lr_Obj *)co);
		lr_errorv(&e);
	}
	if (base + co->xn >= lr_stackend)
		lr_error("stack overflow");
	int n = xget(co, base);

	if (--co->rc == 0)
		lr_free((lr_Obj *)co);
	return n;
}

BUILTIN(co_wrap)
{
	if (nargs < 1 || base[0].tt != LR_FN)
		lr_argexpected(self, base, nargs, 0, "function");
	lr_Coro *co = newco(&base[0]);
	TValue r, cv;
	lr_Closure *c;
	lr_Box *b = lr_newobj(sizeof *b, LR_BOX);

	LR_SETNIL(&r);
	c = lr_closure(&r, co_wrapped, 1, "wrap");
	co->rc = 1;
	LR_SETOBJ(&cv, co, LR_THREAD);
	b->rc = 1;
	b->v = cv;
	c->up[0] = b;
	return lr_return(base, nargs, &r, 1);
}

/* the main chunk ------------------------------------------------------ */

static lr_Coro osco;
static void (*mainfn)(void);

static void mainentry(void)
{
	mainfn();
	/* back to the stack the system started on */
	switchto(&osco);
	abort();
}

/* Run f on a C stack of its own, as the main coroutine. */
void lr_runmain(void (*f)(void))
{
	char *s = cstack(MAIN_CSTACK);

	mainco.rc = LR_IMMORTAL;
	mainco.tt = LR_THREAD;
	mainco.status = CO_RUNNING;
	mainfn = f;
	coinit(&mainco.ctx, s, MAIN_CSTACK, mainentry);
	/* the system's stack, as a coroutine to come back to */
	cur = &osco;
	save(&mainco);
	mainco.climit = s + CMARGIN;
	switchto(&mainco);
	cur = &mainco;
	lr_climit = NULL;
}

void lr_opencoroutine(lr_Table *g)
{
	lr_Table *co = lr_newlib(g, "coroutine");

	lr_reg(co, "create", co_create);
	lr_reg(co, "resume", co_resume);
	lr_reg(co, "yield", co_yield);
	lr_reg(co, "status", co_status);
	lr_reg(co, "running", co_running);
	lr_reg(co, "isyieldable", co_isyieldable);
	lr_reg(co, "close", co_close);
	lr_reg(co, "wrap", co_wrap);
}
