/*
 * The variadic argument walker.
 *
 * The compiler's va_start fills the state in: how many argument registers of
 * each file are still unread, where each save area continues, and where the
 * caller's stack arguments begin.  Every argument occupies one word, whatever
 * its size, so on a little-endian machine a narrow one is read from the low
 * end of its slot.  A target that passes floating point in ordinary registers
 * always asks for flt = 0.
 */

typedef struct {
	long left;
	long fleft;
	char *reg;
	char *freg;
	char *stk;
} __va_state;

void *__va_next(__va_state *ap, long size, long flt)
{
	void *p;

	(void)size;
	if (flt) {
		if (ap->fleft > 0) {
			p = ap->freg;
			ap->freg += 8;
			ap->fleft--;
			return p;
		}
	} else if (ap->left > 0) {
		p = ap->reg;
		ap->reg += 8;
		ap->left--;
		return p;
	}
	p = ap->stk;
	ap->stk += 8;
	return p;
}
