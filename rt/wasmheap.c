/* SPDX-License-Identifier: 0BSD */
/*
 * A heap over linear memory, above __heap_base.  Free blocks sit in one
 * list per power of two, so malloc never looks at a block in use.  A
 * free block keeps its size at both ends, so free joins it to either
 * neighbour without a search.
 */

typedef unsigned long size_t;

void *memcpy(void *, const void *, size_t);

/* the page count, and one more page, as the instruction answers them */
extern unsigned long __wasm_memory_size(void);
extern unsigned long __wasm_memory_grow(unsigned long pages);

#define PAGE	65536
#define HEAD	8		/* keeps the payload eight byte aligned */
#define MIN	24		/* header, two links, and the size at the end */
#define USED	1
#define PUSED	2		/* the block before this one is in use */
#define NBIN	32

typedef struct blk {
	size_t hdr;		/* whole block size, and the two bits */
	size_t pad;
	struct blk *next;	/* the links, only while free */
	struct blk *prev;
} blk;

static blk *bin[NBIN];
static char *top, *end;
static int toppused;		/* whether the block below top is in use */

extern char __heap_base;

#define SIZE(b)		((b)->hdr & ~(size_t)7)
#define AT(b, n)	((blk *)((char *)(b) + (n)))
#define FOOT(b)		(*(size_t *)((char *)(b) + SIZE(b) - sizeof(size_t)))

static void setup(void)
{
	top = (char *)(((size_t)&__heap_base + 7) & ~(size_t)7);
	end = (char *)(__wasm_memory_size() * PAGE);
	toppused = 1;
}

static int binof(size_t n)
{
	int k = 0;

	while (n > 1 && k < NBIN - 1) { n >>= 1; k++; }
	return k;
}

static void link(blk *b)
{
	int k = binof(SIZE(b));

	b->prev = 0;
	b->next = bin[k];
	if (bin[k]) bin[k]->prev = b;
	bin[k] = b;
}

static void unlink(blk *b)
{
	if (b->prev) b->prev->next = b->next;
	else bin[binof(SIZE(b))] = b->next;
	if (b->next) b->next->prev = b->prev;
}

/* mark `b`, of size `n`, free, and tell the block after it */
static void setfree(blk *b, size_t n, int pused)
{
	b->hdr = n | (pused ? PUSED : 0);
	FOOT(b) = n;
	if ((char *)AT(b, n) < top) AT(b, n)->hdr &= ~(size_t)PUSED;
	else toppused = 0;
}

void *malloc(size_t want)
{
	size_t n = (want + HEAD + 7) & ~(size_t)7;
	int k;
	blk *b;

	if (n < MIN) n = MIN;
	if (n < want) return 0;
	if (!top) setup();
	for (k = binof(n); k < NBIN; k++) {
		for (b = bin[k]; b; b = b->next) {
			size_t have = SIZE(b);

			if (have < n) continue;
			unlink(b);
			if (have - n >= MIN) {
				setfree(AT(b, n), have - n, 1);
				link(AT(b, n));
				b->hdr = n | USED | (b->hdr & PUSED);
			} else {
				b->hdr |= USED;
				if ((char *)AT(b, have) < top)
					AT(b, have)->hdr |= PUSED;
				else
					toppused = 1;
			}
			return (char *)b + HEAD;
		}
	}
	while ((size_t)(end - top) < n) {
		unsigned long pages = (n + PAGE - 1) / PAGE;

		if (pages < 16) pages = 16;
		if (__wasm_memory_grow(pages) == (unsigned long)-1) return 0;
		end = (char *)(__wasm_memory_size() * PAGE);
	}
	b = (blk *)top;
	b->hdr = n | USED | (toppused ? PUSED : 0);
	top += n;
	toppused = 1;
	return (char *)b + HEAD;
}

void free(void *p)
{
	blk *b, *nb;
	size_t n;
	int pused;

	if (!p) return;
	b = (blk *)((char *)p - HEAD);
	n = SIZE(b);
	pused = (b->hdr & PUSED) != 0;
	if (!pused) {
		size_t pn = *(size_t *)((char *)b - sizeof(size_t));

		b = (blk *)((char *)b - pn);
		unlink(b);
		n += pn;
		pused = 1;		/* a free block never follows another */
	}
	nb = AT(b, n);
	if ((char *)nb == top) {
		top = (char *)b;
		toppused = pused;
		return;
	}
	if (!(nb->hdr & USED)) {
		unlink(nb);
		n += SIZE(nb);
	}
	setfree(b, n, pused);
	link(b);
}

void *realloc(void *p, size_t want)
{
	blk *b;
	size_t have;
	void *q;

	if (!p) return malloc(want);
	if (want == 0) { free(p); return 0; }
	b = (blk *)((char *)p - HEAD);
	have = SIZE(b) - HEAD;
	if (have >= want) return p;
	/* the last block grows where it stands */
	if ((char *)AT(b, SIZE(b)) == top) {
		size_t n = (want + HEAD + 7) & ~(size_t)7;
		size_t more = n - SIZE(b);

		while ((size_t)(end - top) < more) {
			unsigned long pages = (more + PAGE - 1) / PAGE;

			if (pages < 16) pages = 16;
			if (__wasm_memory_grow(pages) == (unsigned long)-1)
				return 0;
			end = (char *)(__wasm_memory_size() * PAGE);
		}
		top += more;
		b->hdr = n | (b->hdr & 7);
		return p;
	}
	q = malloc(want);
	if (!q) return 0;
	memcpy(q, p, have);
	free(p);
	return q;
}

void *calloc(size_t a, size_t b)
{
	size_t n = a * b;
	char *p;
	size_t i;

	if (b && n / b != a) return 0;
	p = malloc(n);
	if (p) for (i = 0; i < n; i++) p[i] = 0;
	return p;
}
