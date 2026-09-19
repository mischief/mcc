#include <stdio.h>

long sizes(void), carry(long);
double cplxd(int, double, double, double, double);
double cplxf(int, double, double, double, double);
int cplxsame(double, double);
double cplxlast(int);
double cplxl(int, double, double, double, double);

int main(void)
{
	long i;

	printf("sizes %ld\n", sizes());
	for (i = -3; i <= 3; i++)
		printf("carry %ld %ld\n", i, carry(i));
	for (i = 0; i <= 10; i++) {
		printf("cplxd %ld %.9g\n", i,
		       cplxd((int)i, 3.0, 4.0, 1.5, -2.5));
		printf("cplxl %.9g %.9g\n", cplxlast(0), cplxlast(1));
	}
	for (i = 0; i <= 5; i++)
		printf("cplxf %ld %.9g\n", i,
		       cplxf((int)i, 3.0, 4.0, 1.5, -2.5));
	printf("cplxsame %d %d\n", cplxsame(1.5, 2.5), cplxsame(1.5, 0.0));
	for (i = 0; i <= 5; i++)
		printf("cplxl %ld %.9g\n", i,
		       cplxl((int)i, 3.0, 4.0, 1.5, -2.5));
	return 0;
}
