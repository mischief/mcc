/* SPDX-License-Identifier: ISC */
/* Mark and sweep, run when the heap has doubled.  Roots: registered C
 * globals, objects made immortal with lr_gcfix, live coroutines' value
 * stacks (by tag) and C stacks (any word pointing into an object keeps
 * it, so C locals stay safe across an allocation).  Nothing moves.
 * Objects start zeroed, so a half-built one reads as NULL and nil. */
#include "lrt.h"

#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*
 * Objects up to MAXSMALL bytes live in blocks of BLOCK bytes, aligned to
 * their size, one size class each.  A block's header has a bit per slot
 * for in use and one for marked, so a sweep reads only bitmaps, except
 * where a dead object has memory of its own to give back.
 */
#define BLOCK ((size_t)1 << 16)
#define MAXSMALL 1024
#define NWORDS (BLOCK / 16 / 64)

/* what rc holds in a small object, which is marked in its block */
#define SMALL 2

typedef struct Block {
	struct Block *next;
	unsigned size, nslot, first, nfree, hint;
	int fin;			/* its objects have memory of their own */
	uint64_t used[NWORDS], mark[NWORDS];
} Block;

static const unsigned short sizes[] = {
	16, 32, 48, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448,
	512, 640, 768, 896, 1024,
};
#define NSIZE (sizeof sizes / sizeof sizes[0])

typedef struct {
	Block *head, *cur;
} Class;

/* by size, then without and with memory of their own */
static Class cls[NSIZE * 2];
static unsigned char sizeidx[MAXSMALL / 16 + 1];
/* every block, by address */
static Block **blocks;
static size_t nblocks, capblocks;

/* objects too big for a block */
typedef struct {
	lr_Obj *o;
	size_t n;
} Big;

static Big *bigs;
static size_t nbigs, capbigs;

/* allocations since the last collection, and how many make the next */
static size_t nalloc, limit = 1 << 16;
static size_t nbytes;
int lr_gcstopped;
char *lr_cbase;

/* the objects marked and not yet read */
static lr_Obj **gray;
static size_t ngray, capgray;
/* immortal objects marked this time, to unmark */
static lr_Obj **imm;
static size_t nimm, capimm;
/* objects lr_gckeep and lr_gcfix keep */
static lr_Obj **fixed;
static size_t nfixed, capfixed;
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

/* Lowest set bit of x, not 0, and bits set in x.  mcc makes the
 * builtins loops of a bit at a time. */
static unsigned ctz(uint64_t x)
{
	static const unsigned char tab[64] = {
		0, 1, 2, 53, 3, 7, 54, 27, 4, 38, 41, 8, 34, 55, 48, 28,
		62, 5, 39, 46, 44, 42, 22, 9, 24, 35, 59, 56, 49, 18, 29, 11,
		63, 52, 6, 26, 37, 40, 33, 47, 61, 45, 43, 21, 23, 58, 17, 10,
		51, 25, 36, 32, 60, 20, 57, 16, 50, 31, 19, 15, 30, 14, 13, 12,
	};

	return tab[((x & -x) * 0x022fdd63cc95386dull) >> 58];
}

static unsigned popcount(uint64_t x)
{
	x -= (x >> 1) & 0x5555555555555555ull;
	x = (x & 0x3333333333333333ull) + ((x >> 2) & 0x3333333333333333ull);
	x = (x + (x >> 4)) & 0x0f0f0f0f0f0f0f0full;
	return (unsigned)((x * 0x0101010101010101ull) >> 56);
}

static void nomem(void)
{
	fputs("lua: not enough memory\n", stderr);
	exit(1);
}

static void *grow(void *p, size_t *cap, size_t sz)
{
	*cap = *cap ? *cap * 2 : 256;
	p = realloc(p, *cap * sz);
	if (!p)
		nomem();
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

void lr_gckeep(void *o)
{
	if (nfixed == capfixed)
		fixed = grow(fixed, &capfixed, sizeof *fixed);
	fixed[nfixed++] = o;
}

void lr_gcfix(void *o)
{
	((lr_Obj *)o)->rc = LR_IMMORTAL;
	lr_gckeep(o);
}

static void widen(uintptr_t lo, uintptr_t hi)
{
	if (lo < heaplo)
		heaplo = lo;
	if (hi > heaphi)
		heaphi = hi;
}

/* the bits of bitmap word w past a block's last slot */
static uint64_t tail(Block *b, unsigned w)
{
	unsigned n = b->nslot - w * 64;

	return n >= 64 ? 0 : ~(uint64_t)0 << n;
}

static Block *newblock(int c)
{
	Block *b;
	unsigned size = sizes[c / 2];

	if (posix_memalign((void **)&b, BLOCK, BLOCK) != 0)
		nomem();
	memset(b, 0, sizeof *b);
	b->size = size;
	b->first = (sizeof *b + 15) & ~15u;
	b->nslot = (BLOCK - b->first) / size;
	b->nfree = b->nslot;
	b->fin = c & 1;
	for (unsigned w = 0; w * 64 < b->nslot; w++)
		b->used[w] = tail(b, w);
	b->next = cls[c].head;
	cls[c].head = b;

	size_t i = nblocks;

	if (nblocks == capblocks)
		blocks = grow(blocks, &capblocks, sizeof *blocks);
	while (i > 0 && blocks[i - 1] > b) {
		blocks[i] = blocks[i - 1];
		i--;
	}
	blocks[i] = b;
	nblocks++;
	widen((uintptr_t)b, (uintptr_t)b + BLOCK);
	return b;
}

static void *smallalloc(int c)
{
	Class *k = &cls[c];

	for (Block *b = k->cur ? k->cur : k->head;; b = b->next) {
		if (!b)
			b = newblock(c);
		if (!b->nfree)
			continue;
		for (unsigned w = b->hint;; w++) {
			uint64_t free = ~b->used[w];

			if (!free)
				continue;
			unsigned bit = ctz(free);

			b->used[w] |= (uint64_t)1 << bit;
			b->nfree--;
			b->hint = w;
			k->cur = b;
			return (char *)b + b->first + (w * 64 + bit) * b->size;
		}
	}
}

void *lr_newobj(size_t n, int tt)
{
	lr_Obj *o;

	if (nalloc >= limit && !lr_gcstopped && lr_cbase)
		lr_gccollect();
	nalloc++;
	nbytes += n;
	if (n <= MAXSMALL) {
		if (!sizeidx[MAXSMALL / 16]) {
			for (unsigned i = 0, s = 0; i <= MAXSMALL / 16; i++) {
				while (sizes[s] < i * 16)
					s++;
				sizeidx[i] = s;
			}
		}
		int fin = tt == LR_TAB || tt == LR_UDATA || tt == LR_THREAD;
		int c = sizeidx[(n + 15) / 16] * 2 + fin;

		o = smallalloc(c);
		memset(o, 0, sizes[c / 2]);
		o->rc = SMALL;
	} else {
		o = calloc(1, n);
		if (!o)
			nomem();
		if (nbigs == capbigs)
			bigs = grow(bigs, &capbigs, sizeof *bigs);
		bigs[nbigs].o = o;
		bigs[nbigs].n = n;
		nbigs++;
		widen((uintptr_t)o, (uintptr_t)o + n);
	}
	o->tt = tt;
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

static Block *blockof(const void *p)
{
	return (Block *)((uintptr_t)p & ~(uintptr_t)(BLOCK - 1));
}

/* Set the mark bit of a small object; 0 if it was set already. */
static int marksmall(lr_Obj *o)
{
	Block *b = blockof(o);
	unsigned i = (unsigned)((char *)o - (char *)b - b->first) / b->size;
	uint64_t bit = (uint64_t)1 << (i % 64);

	if (b->mark[i / 64] & bit)
		return 0;
	b->mark[i / 64] |= bit;
	return 1;
}

void lr_gcmark(void *p)
{
	lr_Obj *o = p;

	if (!o)
		return;
	if (o->rc == SMALL) {
		if (!marksmall(o))
			return;
	} else if (o->rc >= LR_IMMORTAL) {
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

/* The block w is in, or NULL. */
static Block *findblock(uintptr_t w)
{
	Block *b = blockof((void *)w);
	size_t lo = 0, hi = nblocks;

	while (lo < hi) {
		size_t mid = lo + (hi - lo) / 2;

		if (blocks[mid] < b)
			lo = mid + 1;
		else
			hi = mid;
	}
	return lo < nblocks && blocks[lo] == b ? b : NULL;
}

/* Mark every object a candidate word points into. */
static void resolve(void)
{
	if (!ncand)
		return;
	qsort(cand, ncand, sizeof *cand, bynum);
	for (size_t i = 0; i < ncand; i++) {
		Block *b = findblock(cand[i]);

		if (!b)
			continue;
		uintptr_t off = cand[i] - (uintptr_t)b;

		if (off < b->first)
			continue;
		unsigned k = (unsigned)(off - b->first) / b->size;

		if (k < b->nslot && (b->used[k / 64] >> (k % 64) & 1))
			lr_gcmark((char *)b + b->first + k * b->size);
	}
	for (size_t i = 0; i < nbigs; i++) {
		uintptr_t o = (uintptr_t)bigs[i].o;
		size_t lo = 0, hi = ncand;

		while (lo < hi) {
			size_t mid = lo + (hi - lo) / 2;

			if (cand[mid] < o)
				lo = mid + 1;
			else
				hi = mid;
		}
		if (lo < ncand && cand[lo] < o + bigs[i].n)
			lr_gcmark(bigs[i].o);
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

/* Give back what a dead object holds besides itself. */
static void finalize(lr_Obj *o)
{
	switch (o->tt) {
	case LR_TAB: {
		lr_Table *t = (lr_Table *)o;

		free(t->arr);
		free(t->node);
		break;
	}
	case LR_UDATA: {
		lr_Udata *u = (lr_Udata *)o;

		if (u->free)
			u->free(u->data);
		break;
	}
	case LR_THREAD:
		lr_freecoro((struct lr_Coro *)o);
		break;
	}
}

static void sweepblock(Block *b)
{
	unsigned nw = (b->nslot + 63) / 64, live = 0;

	for (unsigned w = 0; w < nw; w++) {
		uint64_t t = tail(b, w);
		uint64_t dead = b->used[w] & ~b->mark[w] & ~t;

		while (b->fin && dead) {
			unsigned bit = ctz(dead);

			finalize((lr_Obj *)((char *)b + b->first +
				(w * 64 + bit) * b->size));
			dead &= dead - 1;
		}
		b->used[w] = b->mark[w] | t;
		b->mark[w] = 0;
		live += popcount(b->used[w] & ~t);
	}
	b->nfree = b->nslot - live;
	b->hint = 0;
}

static void freeblock(Block *b)
{
	size_t i = 0;

	while (blocks[i] != b)
		i++;
	memmove(&blocks[i], &blocks[i + 1], (nblocks - i - 1) * sizeof *blocks);
	nblocks--;
	free(b);
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
	size_t live = 0, keep = 0;

	/* the callee-saved registers go into regs, on this stack */
	if (setjmp(regs))
		return;
	for (size_t i = 0; i < nfixed; i++)
		lr_gcmark(fixed[i]);
	for (int i = 0; i < nroots; i++)
		lr_gcmarkv(roots[i]);
	for (int i = 0; i < nrootp; i++)
		lr_gcmark(*rootp[i]);
	lr_gccoroots();
	lr_gcmarkstack(lr_stack, lr_top > lr_hiwater ? lr_top : lr_hiwater);
	if (!nocstack)
		scanfn();
	do {
		while (ngray > 0)
			trace(gray[--ngray]);
		resolve();
	} while (ngray > 0);
	/* an immortal object in a block keeps its slot */
	for (size_t i = 0; i < nfixed; i++) {
		if (fixed[i]->rc >= LR_IMMORTAL &&
		    findblock((uintptr_t)fixed[i]))
			marksmall(fixed[i]);
	}

	nbytes = 0;
	heaplo = UINTPTR_MAX;
	heaphi = 0;
	for (size_t c = 0; c < NSIZE * 2; c++) {
		Block **pb = &cls[c].head;

		while (*pb) {
			Block *b = *pb;

			sweepblock(b);
			/* an empty block goes, unless it is the class's last */
			if (b->nfree == b->nslot && (b->next || pb != &cls[c].head)) {
				*pb = b->next;
				freeblock(b);
				continue;
			}
			live += b->nslot - b->nfree;
			nbytes += (size_t)(b->nslot - b->nfree) * b->size;
			widen((uintptr_t)b, (uintptr_t)b + BLOCK);
			pb = &b->next;
		}
		cls[c].cur = cls[c].head;
	}
	for (size_t i = 0; i < nbigs; i++) {
		lr_Obj *o = bigs[i].o;

		if (o->rc == 0) {
			finalize(o);
			free(o);
			continue;
		}
		if (o->rc < LR_IMMORTAL)
			o->rc = 0;
		nbytes += bigs[i].n;
		widen((uintptr_t)o, (uintptr_t)o + bigs[i].n);
		bigs[keep++] = bigs[i];
	}
	nbigs = keep;
	live += nbigs;
	for (size_t i = 0; i < nimm; i++)
		imm[i]->rc = LR_IMMORTAL;
	nimm = 0;
	nalloc = 0;
	limit = live > (1 << 16) ? live : 1 << 16;
}

void lr_gcstats(void)
{
	long n[16] = {0};

	for (int i = 0; i < nroots; i++)
		LR_SETNIL(roots[i]);
	for (int i = 0; i < nrootp; i++)
		*rootp[i] = NULL;
	lr_clear(lr_stack, (int)((lr_top > lr_hiwater ? lr_top : lr_hiwater) -
		lr_stack));
	/* the library's immortal objects stay; a cache is let go */
	size_t k = 0;

	for (size_t i = 0; i < nfixed; i++) {
		if (fixed[i]->rc >= LR_IMMORTAL)
			fixed[k++] = fixed[i];
	}
	nfixed = k;
	nocstack = 1;
	lr_gccollect();
	for (size_t i = 0; i < nblocks; i++) {
		Block *b = blocks[i];

		for (unsigned k = 0; k < b->nslot; k++) {
			if (b->used[k / 64] >> (k % 64) & 1)
				n[((lr_Obj *)((char *)b + b->first +
					k * b->size))->tt]++;
		}
	}
	for (size_t i = 0; i < nbigs; i++)
		n[bigs[i].o->tt]++;
	fprintf(stderr, "live: str %ld tab %ld fn %ld box %ld udata %ld "
		"thread %ld\n", n[LR_STR], n[LR_TAB], n[LR_FN], n[LR_BOX],
		n[LR_UDATA], n[LR_THREAD]);
}
