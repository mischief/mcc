/* SPDX-License-Identifier: ISC */
/* A record read for its effect reads nothing, and only the call is
 * left.  perl writes `(void)*(PL_ppaddr[OP_LC])(aTHX)`. */
struct op { long a, b, c, d; };
typedef struct op *(*ppaddr)(void);

static struct op one = {1, 2, 3, 4};
static int calls;

static struct op *step(void)
{
	calls++;
	return &one;
}

static ppaddr table[] = {step, step};

int voidrec(void)
{
	ppaddr lower = table[1];

	(void)*(lower)();
	(void)*(table[0])();
	*step();
	return calls;
}
