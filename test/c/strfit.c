/* SPDX-License-Identifier: ISC */
/* A string initialising a char array with no room for its terminator:
 * C takes the characters alone, and a longer one keeps what fits.  The
 * terminator written anyway landed on the next member, and the next
 * member's own value was dropped as overlapping it.  linux's ACPI table
 * of predefined names is `{"_BCM", METHOD_1ARGS(...), ...}` in a
 * `char name[4]`, and every method read as taking no arguments. */
extern int printf(const char *, ...);
typedef unsigned short u16;
typedef unsigned char u8;
typedef int wchar_t_;

struct ni { char name[4]; u16 args; u8 types; };
#pragma pack(1)
struct pk { char name[4]; u16 args; u8 types; };
#pragma pack()
struct two { char a[3]; char b[2]; int n; };

static const struct ni tab[] = { {"_BCM", 9, 7}, {"ABCD", 0x1234, 5},
				 {"XY", 3, 4} };
static const struct pk ptab[] = { {"_BLT", 0x24b, 1}, {"_ZZZ", 0x909, 2} };
static struct two t2 = { "abc", "de", 42 };
static char trunc[3] = "abcdef";
static __WCHAR_TYPE__ wide[2] = L"xy";
static __WCHAR_TYPE__ wide3[3] = L"xy";
/* gcc takes a string in parentheses, as perl's macros write it. */
static char paren[] = (("" "pa"));

long strfit(void)
{
	struct ni local = { "LOCL", 0x55aa, 9 };
	struct two lt = { "pqr", "st", -7 };
	char lparen[] = ("lp" "x");
	long sum = 0;
	unsigned i;

	for (i = 0; i < sizeof tab / sizeof tab[0]; i++)
		printf("tab %.4s %x %u\n", tab[i].name, tab[i].args,
			tab[i].types);
	for (i = 0; i < 2; i++)
		printf("ptab %.4s %x %u\n", ptab[i].name, ptab[i].args,
			ptab[i].types);
	printf("t2 %.3s %.2s %d\n", t2.a, t2.b, t2.n);
	printf("lt %.3s %.2s %d\n", lt.a, lt.b, lt.n);
	printf("local %.4s %x %u\n", local.name, local.args, local.types);
	printf("trunc %.3s wide %d %d wide3 %d %d %d\n", trunc,
		(int)wide[0], (int)wide[1], (int)wide3[0], (int)wide3[1],
		(int)wide3[2]);
	printf("paren %s %u %s %u\n", paren, (unsigned)sizeof paren, lparen,
		(unsigned)sizeof lparen);
	printf("sizes %u %u %u\n", (unsigned)sizeof tab, (unsigned)sizeof ptab,
		(unsigned)sizeof t2);
	for (i = 0; i < 3; i++) sum += tab[i].args;
	return sum;
}
