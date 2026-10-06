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
 * The main chunk runs on whatever stack it was called on, as code called
 * from C would.  Its limit is the system's: a recursion the interpreter
 * would make in its own value stack is a recursion of machine frames
 * here, so it meets a stack overflow error sooner than Lua would.
 */
#define _XOPEN_SOURCE 700
#define _DEFAULT_SOURCE
#include "lrtaux.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>

/*
 * The switch itself.  On amd64, arm64 and riscv it is a few instructions
 * of rt/lua's own, which costs no system call and needs no ucontext,
 * which OpenBSD lacks; anywhere else it is ucontext.
 *
 * COFRAME is the words lr_coswitch keeps on a stack, and CORA the one
 * it returns through.
 */
#if defined(__x86_64__)
#define COFRAME 8	/* six registers, the return address, a pad */
#define CORA 6
#elif defined(__aarch64__)
#define COFRAME 20	/* x19-x30, then d8-d15 */
#define CORA 11
#elif defined(__riscv) && __riscv_xlen == 64 && \
	defined(__riscv_float_abi_double)
#define COFRAME 26	/* ra, s0-s11, fs0-fs11 */
#define CORA 0
#elif defined(__riscv) && __riscv_xlen == 32 && \
	defined(__riscv_float_abi_soft)
#define COFRAME 16	/* ra, s0-s11, padded to sixteen bytes */
#define CORA 0
#endif

#ifdef COFRAME
#define OWNSWITCH 1
void lr_coswitch(void **save, void *to);
typedef struct { void *sp; } coctx;
#else
#include <ucontext.h>
typedef ucontext_t coctx;
#endif

enum { CO_SUSPENDED, CO_RUNNING, CO_NORMAL, CO_DEAD };

/* A coroutine's C stack.  Address space is not free everywhere:
 * OpenBSD counts an anonymous mapping against the data limit, so a
 * thousand coroutines must not ask for gigabytes. */
#define CO_CSTACK ((size_t)2 << 20)
#define CO_VSTACK (1 << 16)
/* Room below the limit for the error the limit raises. */
#define CMARGIN ((size_t)128 << 10)

typedef struct lr_Coro {
	intptr_t rc;
	int tt;
	int status;
	int started, failed;
	coctx ctx;
	char *gcsp;			/* its C stack's lowest live word */
	struct lr_Coro *prev;		/* who resumed it */
	char *cstack;
	size_t csize;
	/* the runtime's view of the stack while this one is not running */
	TValue *stack, *stackend, *top, *hiwater;
	struct lr_jmp *handler;
	char *climit;
	int line;
	/* its to-be-closed variables, as lr_tbcv has them while it runs */
	TValue **tbcv;
	int tbcn, tbccap;
	TValue fn;
	/* the values a resume or a yield hands across */
	TValue *xv;
	int xn, xcap;
	TValue err;
} lr_Coro;

char *lr_climit;
static lr_Coro mainco = {.rc = LR_IMMORTAL, .tt = LR_THREAD};
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

/* co's buffer moves to to[0..). */
static int xget(lr_Coro *co, TValue *to)
{
	int n = co->xn;

	for (int i = 0; i < n; i++)
		to[i] = co->xv[i];
	co->xn = 0;
	return n;
}

/* What changes while a coroutine runs; where its stacks are does not,
 * and is set once, when it is made. */
static void save(lr_Coro *co)
{
	co->top = lr_top;
	co->hiwater = lr_hiwater;
	co->handler = lr_handler;
	co->line = lr_curline;
	co->tbcv = lr_tbcv;
	co->tbcn = lr_tbcn;
	co->tbccap = lr_tbccap;
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
	lr_tbcv = co->tbcv;
	lr_tbcn = co->tbcn;
	lr_tbccap = co->tbccap;
	cur = co;
}

/* From the running coroutine to another, and back here when something
 * switches to this one again. */
static void switchto(lr_Coro *to)
{
	lr_Coro *from = cur;
	jmp_buf regs;

	/* the registers go on this stack, where the collector reads */
	if (setjmp(regs))
		abort();
	from->gcsp = (char *)&regs;
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
	/* a frame as lr_coswitch leaves one, with f where it returns.
	 * f starts as a call would leave it: on amd64 the ret pops f and
	 * the pad word stays, eight short of sixteen; elsewhere the
	 * stack pointer is the aligned top */
	void **sp = (void **)(((uintptr_t)(s + size) & ~(uintptr_t)15) -
		COFRAME * sizeof(void *));

	for (int i = 0; i < COFRAME; i++)
		sp[i] = NULL;
	sp[CORA] = (void *)f;
	c->sp = sp;
#else
	getcontext(c);
	c->uc_stack.ss_sp = s;
	c->uc_stack.ss_size = size;
	c->uc_link = NULL;
	makecontext(c, f, 0);
#endif
}

/* Empty every slot a value stack still holds. */
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
		/* The stack stays as the error left it, to-be-closed
		 * variables and all, until the coroutine is closed. */
		lr_handler = NULL;
		co->err = j.err;
		co->failed = 1;
		co->xn = 0;
	}
	co->status = CO_DEAD;
	if (!co->failed)
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

/*
 * Close what co left open, with err, and let go of its stack.  The
 * __close functions run here, on the running coroutine's stacks; what
 * they close over is read from co's.  An error one raises replaces err.
 */
static void closeco(lr_Coro *co, TValue *err)
{
	TValue **v = lr_tbcv;
	int n = lr_tbcn, cap = lr_tbccap;
	int st = co->status;

	co->status = CO_RUNNING;
	lr_tbcv = co->tbcv;
	lr_tbcn = co->tbcn;
	lr_tbccap = co->tbccap;
	lr_closeto(co->stack, err);
	co->tbcv = lr_tbcv;
	co->tbcn = lr_tbcn;
	co->tbccap = lr_tbccap;
	lr_tbcv = v;
	lr_tbcn = n;
	lr_tbccap = cap;
	co->status = st;
	unwindstack(co);
	co->hiwater = co->top = co->stack;
}

void lr_freecoro(lr_Coro *co)
{
	unwindstack(co);
	for (int i = 0; i < co->xn; i++)
		lr_release(&co->xv[i]);
	lr_release(&co->fn);
	lr_release(&co->err);
	free(co->xv);
	free(co->tbcv);
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
	/* the first time the main coroutine is left, where its stacks
	 * are is taken down */
	if (cur == &mainco && !mainco.stack) {
		mainco.stack = lr_stack;
		mainco.stackend = lr_stackend;
		mainco.climit = lr_climit;
	}
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

	LR_SETOBJ(&r, co, LR_THREAD);
	return lr_return(base, nargs, &r, 1);
}

BUILTIN(co_resume)
{
	lr_Coro *co = checkco(self, base, nargs, 0);
	const char *why;
	int ok;

	/* held while it runs: the only reference may be the argument */
	ok = resume(co, base, 1, nargs, &why);
	lr_clear(base, nargs);
	if (ok < 0) {
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
		/* the coroutine keeps its error, for close to answer */
		LR_SETBOOL(&base[0], 0);
		base[1] = co->err;
		lr_retain(&base[1]);
		n = 2;
	}
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

		for (int i = 0; i < co->xn; i++)
			lr_release(&co->xv[i]);
		co->xn = 0;
		closeco(co, &co->err);
		co->status = CO_DEAD;
		if (co->err.tt != LR_NIL)
			co->failed = 1;
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

	/* resume took every argument, leaving nothing in base to clear */
	ok = resume(co, base, 0, nargs, &why);
	if (ok < 0) {
		lr_error("%s", why);
	}
	if (!ok) {
		TValue e;

		closeco(co, &co->err);
		e = co->err;
		LR_SETNIL(&co->err);
		co->failed = 0;
		lr_errorv(&e);
	}
	if (base + co->xn >= lr_stackend)
		lr_error("stack overflow");
	int n = xget(co, base);

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
	LR_SETOBJ(&cv, co, LR_THREAD);
	b->v = cv;
	c->up[0] = b;
	return lr_return(base, nargs, &r, 1);
}

/* the collector ------------------------------------------------------- */

char *lr_cstacktop(void)
{
	return cur == &mainco ? lr_cbase : cur->cstack + cur->csize;
}

/* The main coroutine, and every one waiting on the one that runs. */
void lr_gccoroots(void)
{
	lr_gcmark(&mainco);
	for (lr_Coro *co = cur; co; co = co->prev)
		lr_gcmark(co);
}

void lr_gctraceco(void *p)
{
	lr_Coro *co = p;

	lr_gcmarkv(&co->fn);
	lr_gcmarkv(&co->err);
	for (int i = 0; i < co->xn; i++)
		lr_gcmarkv(&co->xv[i]);
	lr_gcmark(co->prev);
	/* the running one's stacks are the collector's own to read */
	if (co == cur)
		return;
	if (co->stack)
		lr_gcmarkstack(co->stack, co->top > co->hiwater ? co->top :
			co->hiwater);
	if (co->gcsp && co->status != CO_DEAD)
		lr_gcscan(co->gcsp, co == &mainco ? lr_cbase :
			co->cstack + co->csize);
}

/* the main chunk ------------------------------------------------------ */

/*
 * Run f as the main coroutine, on the stack this was called on.  The
 * lowest the stack may reach is what the system's limit allows below
 * here, less the room an error needs; with no limit, eight megabytes.
 */
void lr_runmain(void (*f)(void))
{
	char here;
	struct rlimit rl;
	size_t lim = (size_t)8 << 20;

	if (getrlimit(RLIMIT_STACK, &rl) == 0 && rl.rlim_cur != RLIM_INFINITY &&
	    rl.rlim_cur > 2 * CMARGIN)
		lim = rl.rlim_cur;
	mainco.status = CO_RUNNING;
	cur = &mainco;
	lr_climit = &here - (lim - 2 * CMARGIN);
	f();
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
