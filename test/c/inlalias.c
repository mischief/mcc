/* SPDX-License-Identifier: ISC */
/* A body built where it was called may read a parameter straight from
 * the caller's slot when nothing can reach that slot from inside.  An
 * address taken of the object reaches every member of it: `&list` goes
 * in, `list.prev` is the argument, and the body writes `head->prev`
 * before it reads `prev`.  linux's list_add_tail is exactly that, and
 * the request list handed to the block scheduler came out empty. */
extern int printf(const char *, ...);

struct list_head { struct list_head *next, *prev; };

static inline void __list_add(struct list_head *new, struct list_head *prev,
			      struct list_head *next)
{
	next->prev = new;
	new->next = next;
	new->prev = prev;
	*(volatile struct list_head **)&prev->next = new;
}

static inline void list_add_tail(struct list_head *new,
				 struct list_head *head)
{
	__list_add(new, head->prev, head);
}

static inline void list_add(struct list_head *new, struct list_head *head)
{
	__list_add(new, head, head->next);
}

struct req { int id; struct list_head q; };

#define container_of(p, T, m) ((T *)((char *)(p) - __builtin_offsetof(T, m)))

__attribute__((noinline)) static int walk(struct list_head *h)
{
	int sum = 0;

	for (struct list_head *p = h->next; p != h; p = p->next)
		sum = sum * 10 + container_of(p, struct req, q)->id;
	return sum;
}

struct pair { int a, b; };

static inline int bump(int *p, int v) { *p += 5; return v; }

long inlalias(void)
{
	struct list_head list = { &list, &list };
	struct req r1 = {1}, r2 = {2}, r3 = {3};
	struct pair pr = { 1, 2 };
	int got;

	list_add_tail(&r1.q, &list);
	list_add_tail(&r2.q, &list);
	list_add(&r3.q, &list);
	printf("list %d next %d prev %d\n", walk(&list),
		list.next == &r3.q, list.prev == &r2.q);
	/* a member of an escaped record, written through the pointer
	 * before the parameter is read */
	got = bump(&pr.a, pr.a);
	printf("pair %d %d %d\n", got, pr.a, pr.b);
	return walk(&list);
}
