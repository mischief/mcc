/*
 * The variadic argument walker.
 *
 * The compiler's va_start fills the state in: how many argument registers of
 * each file are still unread, where each save area continues, and where the
 * caller's stack arguments begin.  An argument occupies whole words, so a
 * value twice the register width takes two of them and starts on an even
 * one, which is what the calling convention does with it.  A target that
 * passes floating point in ordinary registers always asks for flt = 0.
 */

#define WORD ((long)sizeof(void *))

typedef struct {
	long left;		/* integer argument registers still unread */
	long fleft;		/* floating point ones still unread */
	long regs;		/* how many integer ones there were */
	char *reg;		/* the next integer one in the save area */
	char *freg;		/* the next floating point one */
	char *stk;		/* the next one on the caller's stack */
} __va_state;

void *__va_next(__va_state *ap, long size, long flt)
{
	long n = (size + WORD - 1) / WORD;
	void *p;

	if (flt && ap->fleft > 0) {
		p = ap->freg;
		ap->freg += 8;
		ap->fleft--;
		return p;
	}
	if (!flt && ap->left >= n) {
		if (n > 1 && ((ap->regs - ap->left) & 1)) {
			ap->reg += WORD;	/* an even register */
			ap->left--;
		}
		if (ap->left >= n) {
			p = ap->reg;
			ap->reg += n * WORD;
			ap->left -= n;
			return p;
		}
	}
	if (n > 1 && ((((unsigned long)ap->stk) / (unsigned long)WORD) & 1)) {
		ap->stk += WORD;
	}
	p = ap->stk;
	ap->stk += n * WORD;
	return p;
}
