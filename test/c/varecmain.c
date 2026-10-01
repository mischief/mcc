/* SPDX-License-Identifier: ISC */
#include <stdio.h>

struct DL { double d; long l; };
struct FFI { float a, b; int c; };
struct DD { double x, y; };
struct LD { long l; double d; };

long walk(int, ...);

int main(void)
{
	struct DL dl = {1.5, 2};
	struct FFI f = {2.25f, 3.0f, 4};
	struct DD dd = {5.0, 6.0};
	struct LD ld = {7, 8.0};
	double _Complex z;
	float _Complex w;

	((double *)&z)[0] = 9.0;
	((double *)&z)[1] = 10.0;
	((float *)&w)[0] = 11.0f;
	((float *)&w)[1] = 12.0f;
	printf("1 %ld\n", walk(1, dl, f, dd, ld, z, w));
	printf("2 %ld\n", walk(2, dl, f, dd, ld, z, w, dl, f, dd, ld, z, w));
	printf("3 %ld\n", walk(3, dl, f, dd, ld, z, w, dl, f, dd, ld, z, w,
			       dl, f, dd, ld, z, w));
	return 0;
}
