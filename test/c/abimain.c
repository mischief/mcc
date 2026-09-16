#include <stdio.h>

double dadd(double, double);
float fmix(float, float, float);
double many(double, long, double, double, double, double, double, double,
	    double, double, long, double);
double vsum(long, ...);
double vmix(long, ...);
double callback(double (*)(double, double), double, double);
double libm(double);

static double mul(double a, double b)
{
	return a * b;
}

int main(void)
{
	long i;

	for (i = -3; i <= 3; i++) {
		printf("dadd %.6f\n", dadd((double)i, 0.5));
		printf("fmix %.6f\n", (double)fmix((float)i, 2.5f, 0.25f));
		printf("callback %.6f\n", callback(mul, (double)i, 1.5));
	}
	printf("many %.6f\n",
	       many(1.5, 2, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5, 9.5, 10.5, 11, 12.5));
	printf("vsum0 %.6f\n", vsum(0));
	printf("vsum3 %.6f\n", vsum(3, 1.5, 2.25, 3.125));
	printf("vsum9 %.6f\n", vsum(9, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0,
				   8.0, 9.0));
	printf("vmix %.6f\n", vmix(3, 1L, 2.0, 3L, 4.0, 5L, 6.0));
	for (i = 1; i <= 4; i++)
		printf("libm %.6f\n", libm((double)i));
	return 0;
}
