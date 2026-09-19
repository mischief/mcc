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

#ifdef __amd64__
/*
 * System V on amd64 has a va_list of its own, which the system's vprintf
 * reads, so this compiler uses that one rather than a shape of its own.
 * The save area is six integer registers and then eight floating point
 * ones sixteen bytes apart; an offset past the end of a file means that
 * file is used up and the rest comes off the caller's stack.
 */
#define GPEND	48
#define FPEND	176

typedef struct {
	unsigned int gp_offset;
	unsigned int fp_offset;
	char *overflow_arg_area;
	char *reg_save_area;
} __va_list_tag;

void *__va_next(__va_list_tag *ap, long size, long flt)
{
	long n = (size + 7) / 8;
	void *p;

	if (flt == 2) {
		/*
		 * The extended type is never in a register, and the ABI
		 * aligns it to sixteen where the caller left it.
		 */
		p = (char *)(((unsigned long)ap->overflow_arg_area + 15)
			     & ~15UL);
		ap->overflow_arg_area = (char *)p + 16;
		return p;
	}
	if (flt && ap->fp_offset + 16 <= FPEND) {
		p = ap->reg_save_area + ap->fp_offset;
		ap->fp_offset += 16;
		return p;
	}
	if (!flt && ap->gp_offset + n * 8 <= GPEND) {
		p = ap->reg_save_area + ap->gp_offset;
		ap->gp_offset += (unsigned int)(n * 8);
		return p;
	}
	p = ap->overflow_arg_area;
	ap->overflow_arg_area += n * 8;
	return p;
}
#else

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
#endif
