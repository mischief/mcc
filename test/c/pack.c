/* SPDX-License-Identifier: ISC */
/* `#pragma pack` caps every member's alignment, and the record's with
 * them; push and pop nest, and pack() goes back to the natural layout.
 * linux's virtio and ACPI tables are declared this way, and a record
 * two bytes too long reads its fields from the wrong place.
 *
 * Also `__has_include`, which counts as defined for #ifdef and answers
 * whether #include would find a file. */
extern int printf(const char *, ...);
#include <stddef.h>

typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef unsigned long long u64;

struct plain { u8 a; u32 b; u16 c; };
#pragma pack(1)
struct p1 { struct { u8 type, length; } h; u8 pid; u16 flags; u8 lint; };
struct p1b { u8 a; u64 b; u16 c; };
struct p1bits { u8 a; u32 x:3, y:9; u16 z; };
#pragma pack(2)
struct p2 { u8 a; u32 b; u64 c; u8 d; };
#pragma pack(push, 4)
struct p4 { u8 a; u64 b; u16 c; };
#pragma pack(push, 1)
struct pn { u8 a; u32 b; };
#pragma pack(pop)
struct p4again { u8 a; u64 b; };
#pragma pack(pop)
struct p2again { u8 a; u32 b; };
#pragma pack()
struct back { u8 a; u64 b; };

#ifdef __has_include
static int hasdef = 1;
#else
static int hasdef = 0;
#endif
#if __has_include(<stddef.h>) && !__has_include("no-such-header.h")
static int hasfile = 1;
#else
static int hasfile = 0;
#endif

#define S(T) printf(#T " %u %u\n", (unsigned)sizeof(struct T), \
	(unsigned)_Alignof(struct T))

long packs(void)
{
	struct p1bits q = {0};

	S(plain); S(p1); S(p1b); S(p1bits); S(p2); S(p4); S(pn);
	S(p4again); S(p2again); S(back);
	printf("p1 %u %u %u\n", (unsigned)offsetof(struct p1, pid),
		(unsigned)offsetof(struct p1, flags),
		(unsigned)offsetof(struct p1, lint));
	printf("p2 %u %u %u\n", (unsigned)offsetof(struct p2, b),
		(unsigned)offsetof(struct p2, c),
		(unsigned)offsetof(struct p2, d));
	q.x = 5; q.y = 300; q.z = 7;
	printf("bits %d %d %d\n", q.x, q.y, q.z);
	printf("has %d %d\n", hasdef, hasfile);
	return 0;
}
