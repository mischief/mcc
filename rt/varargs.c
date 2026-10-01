/* SPDX-License-Identifier: 0BSD */
/*
 * The variadic argument walker.
 *
 * The compiler's va_start fills the state in: how many argument registers of
 * each file are still unread, where each save area continues, and where the
 * caller's stack arguments begin.  An argument occupies whole words, and
 * one aligned to two words starts on an even one, which is what the
 * calling convention does with it.  A target that passes floating point
 * in ordinary registers never asks for the float file.
 */

/* A freestanding program links no runtime, so the compiler builds this
   into the object.  VFN is how it makes it its own. */
#ifndef VFN
#define VFN
#endif

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

VFN void *__va_next(__va_list_tag *ap, long size, long flt)
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
	long tmp[2];		/* a value gathered from two places */
} __va_state;

/*
 * What flt says, besides which file: VA_PAIR, the value is aligned to
 * two words and starts on an even register or word; VA_REF, a record
 * the caller handed over by address; VA_SPLIT, a two-word value may
 * take the last register and a stack word; VA_HFA4, a record of floats
 * that took a vector register each.
 */
#define VA_FLT		1
#define VA_PAIR		4
#define VA_REF		8
#define VA_SPLIT	16
#define VA_HFA4		32

VFN void *__va_next(__va_state *ap, long size, long flt)
{
	long n = (size + WORD - 1) / WORD;
	void *p;

	if (flt & VA_REF)
		return *(void **)__va_next(ap, WORD, 0);
	if (flt & VA_FLT) {
		/* Each member of a float record took a register of its own. */
		long m = (flt & VA_HFA4) ? size / 4 : (size + 7) / 8;

		if (ap->fleft >= m) {
			p = ap->freg;
			if (flt & VA_HFA4) {
				long i;

				for (i = 0; i < m; i++)
					((float *)ap->tmp)[i] =
					    *(float *)(ap->freg + 8 * i);
				p = ap->tmp;
			}
			ap->freg += 8 * m;
			ap->fleft -= m;
			return p;
		}
		ap->fleft = 0;
	} else if (ap->left > 0) {
		if (n > 1 && (flt & VA_PAIR) && ((ap->regs - ap->left) & 1)) {
			ap->reg += WORD;	/* an even register */
			ap->left--;
		}
		if (ap->left >= n) {
			p = ap->reg;
			ap->reg += n * WORD;
			ap->left -= n;
			return p;
		}
		if (n == 2 && ap->left == 1 && (flt & VA_SPLIT)) {
			ap->tmp[0] = *(long *)ap->reg;
			ap->tmp[1] = *(long *)ap->stk;
			ap->reg += WORD;
			ap->stk += WORD;
			ap->left = 0;
			return ap->tmp;
		}
		/* What does not fit closes the file to what comes after. */
		ap->left = 0;
	}
#ifndef __i386__
	/*
	 * A value aligned to two words starts on an even word, which is
	 * where the caller put it.  The i386 ABI is the one that does
	 * not: everything there is four byte aligned.
	 */
	if (n > 1 && (flt & VA_PAIR) &&
	    ((((unsigned long)ap->stk) / (unsigned long)WORD) & 1)) {
		ap->stk += WORD;
	}
#endif
	p = ap->stk;
	ap->stk += n * WORD;
	return p;
}
#endif
