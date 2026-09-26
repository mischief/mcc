/* SPDX-License-Identifier: ISC */
/* A static function called with the same number everywhere reads that
 * number inside its body.  A call read before the body counts too:
 * perl's newATTRSUB_x passes `floor` before S_process_special_blocks is
 * defined, and newXS_len_flags passes 0 after, so the body took floor
 * as 0 and never left the scope. */
extern int printf(const char *, ...);

static int ix = 85;
static int leave(int floor, const char *s);

int callfirst(int fl)
{
	return leave(fl, "B");
}

/* Big enough that it is called, not inlined. */
static int leave(int floor, const char *s)
{
	int n = 0;

	if (s[1] == 40)
		n += printf("0 %s\n", s);
	if (s[1] == 41)
		n += printf("1 %s\n", s);
	if (s[1] == 42)
		n += printf("2 %s\n", s);
	if (s[1] == 43)
		n += printf("3 %s\n", s);
	if (s[1] == 44)
		n += printf("4 %s\n", s);
	if (s[1] == 45)
		n += printf("5 %s\n", s);
	if (s[1] == 46)
		n += printf("6 %s\n", s);
	if (s[1] == 47)
		n += printf("7 %s\n", s);
	if (s[1] == 48)
		n += printf("8 %s\n", s);
	if (s[1] == 49)
		n += printf("9 %s\n", s);
	if (s[1] == 50)
		n += printf("10 %s\n", s);
	if (s[1] == 51)
		n += printf("11 %s\n", s);
	if (s[1] == 52)
		n += printf("12 %s\n", s);
	if (s[1] == 53)
		n += printf("13 %s\n", s);
	if (s[1] == 54)
		n += printf("14 %s\n", s);
	if (s[1] == 55)
		n += printf("15 %s\n", s);
	if (s[1] == 56)
		n += printf("16 %s\n", s);
	if (s[1] == 57)
		n += printf("17 %s\n", s);
	if (s[1] == 58)
		n += printf("18 %s\n", s);
	if (s[1] == 59)
		n += printf("19 %s\n", s);
	if (s[1] == 60)
		n += printf("20 %s\n", s);
	if (s[1] == 61)
		n += printf("21 %s\n", s);
	if (s[1] == 62)
		n += printf("22 %s\n", s);
	if (s[1] == 63)
		n += printf("23 %s\n", s);
	if (*s == 'B') {
		if (floor && ix > floor)
			ix = floor;
		return n + 1;
	}
	return n;
}

int callafter(void)
{
	return leave(0, "B");
}

int callix(void)
{
	return ix;
}
