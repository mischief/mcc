#include <stdio.h>

long sizes(void), joined(void), elems(long), others(long), bits(unsigned long);
long locals(long);
long classify(double), classifyf(float);

int main(void)
{
	double z = 0.0, one = 1.0;
	long i;

	printf("sizes %ld\n", sizes());
	printf("joined %ld\n", joined());
	for (i = 0; i < 8; i++)
		printf("elems %ld %ld\n", i, elems(i));
	for (i = 0; i < 2; i++)
		printf("others %ld %ld\n", i, others(i));
	for (i = 0; i < 3; i++)
		printf("locals %ld %ld\n", i, locals(i));
	printf("cls %ld %ld %ld %ld %ld\n", classify(one), classify(-one),
	       classify(one / z), classify(-one / z), classify(z / z));
	printf("clsf %ld %ld %ld %ld\n", classifyf(1.0f), classifyf(-1.0f),
	       classifyf((float)(one / z)), classifyf((float)(z / z)));
	printf("cls0 %ld %ld\n", classify(z), classify(-z));
	for (i = 0; i < 6; i++)
		printf("bits %ld %ld\n", i,
		       bits(0xf0f0f0f0f0f0f0f0UL >> (i * 7)));
	return 0;
}
