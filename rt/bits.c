/* SPDX-License-Identifier: 0BSD */
/* Counting bits, under the names a compiler runtime gives them.  The
   compiler folds these away when it knows the value; what is left is a
   call to one of these. */

int __ffssi2(unsigned int x);
int __ffsdi2(unsigned long long x);
int __clzsi2(unsigned int x);
int __clzdi2(unsigned long long x);
int __ctzsi2(unsigned int x);
int __ctzdi2(unsigned long long x);
int __popcountsi2(unsigned int x);
int __popcountdi2(unsigned long long x);
int __paritysi2(unsigned int x);
int __paritydi2(unsigned long long x);

int
__ffsdi2(unsigned long long x)
{
	int n;

	if (x == 0)
		return 0;
	for (n = 1; (x & 1) == 0; n++)
		x >>= 1;
	return n;
}

int
__ffssi2(unsigned int x)
{
	return __ffsdi2(x);
}

/* Undefined for zero, the way gcc has it; the whole width is as good an
   answer as any. */
int
__clzdi2(unsigned long long x)
{
	int n;

	for (n = 0; n < 64; n++)
		if (x >> (63 - n) & 1)
			break;
	return n;
}

int
__clzsi2(unsigned int x)
{
	int n;

	for (n = 0; n < 32; n++)
		if (x >> (31 - n) & 1)
			break;
	return n;
}

int
__ctzdi2(unsigned long long x)
{
	int n;

	if (x == 0)
		return 64;
	for (n = 0; (x & 1) == 0; n++)
		x >>= 1;
	return n;
}

int
__ctzsi2(unsigned int x)
{
	if (x == 0)
		return 32;
	return __ctzdi2(x);
}

int
__popcountdi2(unsigned long long x)
{
	int n = 0;

	while (x) {
		n += (int)(x & 1);
		x >>= 1;
	}
	return n;
}

int
__popcountsi2(unsigned int x)
{
	return __popcountdi2(x);
}

int
__paritydi2(unsigned long long x)
{
	return __popcountdi2(x) & 1;
}

int
__paritysi2(unsigned int x)
{
	return __popcountdi2(x) & 1;
}
