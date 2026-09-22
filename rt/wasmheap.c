/* SPDX-License-Identifier: 0BSD */
/*
 * A heap over linear memory: first fit over a list that coalesces, and
 * memory.grow when the list has nothing big enough.
 *
 * The arena starts above everything the module was linked with, which
 * __heap_base names, and ends at whatever the memory has grown to.
 */

typedef unsigned long size_t;

void *memcpy(void *, const void *, size_t);

/* the page count, and one more page, as the instruction answers them */
extern unsigned long __wasm_memory_size(void);
extern unsigned long __wasm_memory_grow(unsigned long pages);

#define PAGE	65536
#define ALIGN	8

struct head {
	size_t size;		/* payload bytes, not counting this */
	struct head *next;	/* the free list, when free */
	int free;
	int pad;
};

static struct head *first;
static char *top, *end;

extern char __heap_base;

static void setup(void)
{
	unsigned long have = __wasm_memory_size() * PAGE;

	top = &__heap_base;
	/* leave the shadow stack alone: it grows down from the top of
	   what was there when the module was written */
	end = (char *)have;
	if (top >= end) {
		__wasm_memory_grow(16);
		end = (char *)(__wasm_memory_size() * PAGE);
	}
}

static size_t roundup(size_t n)
{
	return (n + (ALIGN - 1)) & ~(size_t)(ALIGN - 1);
}

void *malloc(size_t n)
{
	struct head *h, *prev = 0;

	if (n == 0) n = 1;
	n = roundup(n);
	if (!top) setup();

	for (h = first; h; prev = h, h = h->next) {
		if (h->free && h->size >= n) {
			/* split, when what is left is worth a header */
			if (h->size >= n + sizeof(struct head) + ALIGN) {
				struct head *s =
				    (struct head *)((char *)(h + 1) + n);

				s->size = h->size - n - sizeof(struct head);
				s->free = 1;
				s->next = h->next;
				h->next = s;
				h->size = n;
			}
			h->free = 0;
			return h + 1;
		}
	}

	while (top + sizeof(struct head) + n > end) {
		unsigned long want = (sizeof(struct head) + n + PAGE - 1)
		    / PAGE;

		if (want < 16) want = 16;
		if (__wasm_memory_grow(want) == (unsigned long)-1) return 0;
		end = (char *)(__wasm_memory_size() * PAGE);
	}

	h = (struct head *)top;
	top += sizeof(struct head) + n;
	h->size = n;
	h->free = 0;
	h->next = 0;
	if (prev) prev->next = h; else first = h;
	return h + 1;
}

void free(void *p)
{
	struct head *h, *n;

	if (!p) return;
	h = (struct head *)p - 1;
	h->free = 1;
	/* join what follows, so a run of frees does not leave crumbs */
	for (n = h->next; n && n->free; n = h->next) {
		h->size += sizeof(struct head) + n->size;
		h->next = n->next;
	}
}

void *realloc(void *p, size_t n)
{
	struct head *h;
	void *q;

	if (!p) return malloc(n);
	if (n == 0) { free(p); return 0; }
	h = (struct head *)p - 1;
	if (h->size >= n) return p;
	q = malloc(n);
	if (!q) return 0;
	memcpy(q, p, h->size);
	free(p);
	return q;
}

void *calloc(size_t a, size_t b)
{
	size_t n = a * b;
	char *p = malloc(n);
	size_t i;

	if (p) for (i = 0; i < n; i++) p[i] = 0;
	return p;
}
