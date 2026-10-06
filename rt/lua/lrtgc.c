/* SPDX-License-Identifier: ISC */
/* Mark and sweep, run when the object count doubles.  Roots: registered
 * C globals, LR_IMMORTAL heap objects, live coroutines' value stacks (by
 * tag) and C stacks (any word pointing into an object keeps it, so C
 * locals stay safe across an allocation).  Nothing moves.  Objects start
 * zeroed, so a half-built one reads as NULL and nil. */
#include "lrt.h"

#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
	lr_Obj *o;
	size_t n;
} Ent;

/* every heap object */
static Ent *objs;
static size_t nobjs, capobjs;
/* the collection after this many objects */
static size_t limit = 1 << 16;
static size_t nbytes;
static long nlive[16];
int lr_gcstopped;
char *lr_cbase;

/* the objects marked and not yet read */
static lr_Obj **gray;
static size_t ngray, capgray;
/* immortal objects marked this time, to unmark */
static lr_Obj **imm;
static size_t nimm, capimm;
/* words from C stacks and userdata that may point into an object */
static uintptr_t *cand;
static size_t ncand, capcand;
static uintptr_t heaplo = UINTPTR_MAX, heaphi;

static TValue *roots[32];
static int nroots;
static lr_Obj **rootp[32];
static int nrootp;
/* no C stack is read: the program is over */
static int nocstack;

/* a coroutine's own: what it holds, and its stacks */
void lr_gctraceco(void *co);
void lr_gccoroots(void);
char *lr_cstacktop(void);
void lr_freecoro(struct lr_Coro *co);

static void *grow(void *p, size_t *cap, size_t sz)
{
	*cap = *cap ? *cap * 2 : 256;
	p = realloc(p, *cap * sz);
	if (!p) {
		fputs("lua: not enough memory\n", stderr);
		exit(1);
	}
	return p;
}

void lr_gcroot(TValue *v)
{
	if (nroots == (int)(sizeof roots / sizeof roots[0]))
		abort();
	roots[nroots++] = v;
}

void lr_gcrootp(void *pp)
{
	if (nrootp == (int)(sizeof rootp / sizeof rootp[0]))
		abort();
	rootp[nrootp++] = pp;
}

static lr_Obj **kept;
static size_t nkept, capkept;

void lr_gckeep(void *o)
{
	if (nkept == capkept)
		kept = grow(kept, &capkept, sizeof *kept);
	kept[nkept++] = o;
}

void *lr_newobj(size_t n, int tt)
{
	if (nobjs >= limit && !lr_gcstopped && lr_cbase)
		lr_gccollect();
	lr_Obj *o = calloc(1, n);

	if (!o) {
		fputs("lua: not enough memory\n", stderr);
		exit(1);
	}
	o->tt = tt;
	if (nobjs == capobjs)
		objs = grow(objs, &capobjs, sizeof *objs);
	objs[nobjs].o = o;
	objs[nobjs].n = n;
	if ((uintptr_t)o < heaplo)
		heaplo = (uintptr_t)o;
	if ((uintptr_t)o + n > heaphi)
		heaphi = (uintptr_t)o + n;
	nobjs++;
	nbytes += n;
	nlive[tt]++;
	return o;
}

/* The collector frees; nothing else does. */
void lr_free(lr_Obj *o)
{
	(void)o;
}

size_t lr_gcbytes(void)
{
	return nbytes;
}

void lr_gcmark(void *p)
{
	lr_Obj *o = p;

	if (!o)
		return;
	if (o->rc >= LR_IMMORTAL) {
		if (o->rc != LR_IMMORTAL)
			return;
		o->rc = LR_IMMORTAL + 1;
		if (nimm == capimm)
			imm = grow(imm, &capimm, sizeof *imm);
		imm[nimm++] = o;
	} else {
		if (o->rc)
			return;
		o->rc = 1;
	}
	if (o->tt == LR_STR)
		return;
	if (ngray == capgray)
		gray = grow(gray, &capgray, sizeof *gray);
	gray[ngray++] = o;
}

void lr_gcmarkv(const TValue *v)
{
	if (LR_COUNTED(v->tt))
		lr_gcmark(v->v.p);
}

void lr_gcmarkstack(TValue *lo, TValue *hi)
{
	for (TValue *v = lo; v < hi; v++)
		lr_gcmarkv(v);
}

void lr_gcscan(const void *lo, const void *hi)
{
	uintptr_t a = ((uintptr_t)lo + sizeof(void *) - 1) &
		~(uintptr_t)(sizeof(void *) - 1);

	for (; a + sizeof(void *) <= (uintptr_t)hi; a += sizeof(void *)) {
		uintptr_t w = *(uintptr_t *)a;

		if (w < heaplo || w >= heaphi)
			continue;
		if (ncand == capcand)
			cand = grow(cand, &capcand, sizeof *cand);
		cand[ncand++] = w;
	}
}

static int bynum(const void *a, const void *b)
{
	uintptr_t x = *(const uintptr_t *)a, y = *(const uintptr_t *)b;

	return x < y ? -1 : x > y;
}

/* Mark every object a candidate word points into, and every immortal
 * one, which is a root: the words sorted, then one pass over the
 * objects. */
static void resolve(void)
{
	qsort(cand, ncand, sizeof *cand, bynum);
	for (size_t i = 0; i < nobjs; i++) {
		uintptr_t o = (uintptr_t)objs[i].o;
		size_t lo = 0, hi = ncand;

		if (objs[i].o->rc) {
			if (objs[i].o->rc == LR_IMMORTAL)
				lr_gcmark(objs[i].o);
			continue;
		}
		if (!ncand)
			continue;
		while (lo < hi) {
			size_t mid = lo + (hi - lo) / 2;

			if (cand[mid] < o)
				lo = mid + 1;
			else
				hi = mid;
		}
		if (lo < ncand && cand[lo] < o + objs[i].n)
			lr_gcmark(objs[i].o);
	}
	ncand = 0;
}

static void trace(lr_Obj *o)
{
	switch (o->tt) {
	case LR_TAB: {
		lr_Table *t = (lr_Table *)o;

		lr_gcmark(t->mt);
		for (lr_Int i = 0; i < t->asize; i++)
			lr_gcmarkv(&t->arr[i]);
		for (lr_Int i = 0; i < t->hcap; i++) {
			lr_gcmarkv(&t->node[i].key);
			lr_gcmarkv(&t->node[i].val);
		}
		break;
	}
	case LR_FN: {
		lr_Closure *c = (lr_Closure *)o;

		for (int i = 0; i < c->nup; i++)
			lr_gcmark(c->up[i]);
		break;
	}
	case LR_BOX:
		lr_gcmarkv(&((lr_Box *)o)->v);
		break;
	case LR_UDATA: {
		lr_Udata *u = (lr_Udata *)o;

		lr_gcmark(u->mt);
		/* what a library keeps in one is opaque: read it as words */
		lr_gcscan(u->data, u->data + u->len);
		break;
	}
	case LR_THREAD:
		lr_gctraceco(o);
		break;
	}
}

static void gcfree(Ent *e)
{
	lr_Obj *o = e->o;

	nlive[o->tt]--;
	nbytes -= e->n;
	switch (o->tt) {
	case LR_TAB: {
		lr_Table *t = (lr_Table *)o;

		free(t->arr);
		free(t->node);
		free(t);
		break;
	}
	case LR_UDATA: {
		lr_Udata *u = (lr_Udata *)o;

		if (u->free)
			u->free(u->data);
		free(u);
		break;
	}
	case LR_THREAD:
		lr_freecoro((struct lr_Coro *)o);
		break;
	default:
		free(o);
	}
}

/* Read the running coroutine's C stack, from a frame below every one
 * that might hold an object up to where it starts. */
static void scancstack(void)
{
	char here;

	lr_gcscan(&here, lr_cstacktop());
}

static void (*volatile scanfn)(void) = scancstack;

void lr_gccollect(void)
{
	jmp_buf regs;
	size_t keep = 0;

	/* the callee-saved registers go into regs, on this stack */
	if (setjmp(regs))
		return;
	for (int i = 0; i < nroots; i++)
		lr_gcmarkv(roots[i]);
	for (int i = 0; i < nrootp; i++)
		lr_gcmark(*rootp[i]);
	for (size_t i = 0; i < nkept; i++)
		lr_gcmark(kept[i]);
	lr_gccoroots();
	lr_gcmarkstack(lr_stack, lr_top > lr_hiwater ? lr_top : lr_hiwater);
	if (!nocstack)
		scanfn();
	do {
		while (ngray > 0)
			trace(gray[--ngray]);
		resolve();
	} while (ngray > 0);

	for (size_t i = 0; i < nobjs; i++) {
		lr_Obj *o = objs[i].o;

		if (o->rc == 0) {
			gcfree(&objs[i]);
			continue;
		}
		if (o->rc < LR_IMMORTAL)
			o->rc = 0;
		objs[keep++] = objs[i];
	}
	nobjs = keep;
	heaplo = UINTPTR_MAX;
	heaphi = 0;
	for (size_t i = 0; i < nobjs; i++) {
		if ((uintptr_t)objs[i].o < heaplo)
			heaplo = (uintptr_t)objs[i].o;
		if ((uintptr_t)objs[i].o + objs[i].n > heaphi)
			heaphi = (uintptr_t)objs[i].o + objs[i].n;
	}
	for (size_t i = 0; i < nimm; i++)
		imm[i]->rc = LR_IMMORTAL;
	nimm = 0;
	limit = nobjs * 2 > (1 << 16) ? nobjs * 2 : 1 << 16;
}

void lr_gcstats(void)
{
	for (int i = 0; i < nroots; i++)
		LR_SETNIL(roots[i]);
	for (int i = 0; i < nrootp; i++)
		*rootp[i] = NULL;
	nkept = 0;
	lr_clear(lr_stack, (int)((lr_top > lr_hiwater ? lr_top : lr_hiwater) -
		lr_stack));
	nocstack = 1;
	lr_gccollect();
	fprintf(stderr, "live: str %ld tab %ld fn %ld box %ld udata %ld "
		"thread %ld\n", nlive[LR_STR], nlive[LR_TAB], nlive[LR_FN],
		nlive[LR_BOX], nlive[LR_UDATA], nlive[LR_THREAD]);
}
