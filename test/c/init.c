/* initializers: aggregates, strings, inferred bounds, statics */

typedef unsigned char byte;

struct P { int x; int y; };
struct Q { char tag; struct P at; long big; };

int flat[6] = {1, 2, 3, 4, 5, 6};
int part[6] = {9, 8};
int none[4];
char text[] = "hello";
char fixed[8] = "hi";
const char *names[] = {"alpha", "beta", "gamma"};
struct P pt = {11, 22};
struct P pts[3] = {{1, 2}, {3, 4}};
struct Q q = {'z', {7, 8}, 1234567890123L};
byte lut[8] = {0, 1, 2, 3, 4, 5, 6, 7};
long scaled[3] = {1 * 10, 2 * 10, 3 * 10};
double dbl[3] = {0.5, 1.5, -2.25};
int *pflat = flat;
int *pmid = &flat[2];

long sums(void)
{
	long i;
	long s;

	s = 0;
	for (i = 0; i < 6; i++)
		s = s * 10 + flat[i];
	for (i = 0; i < 6; i++)
		s = s + part[i];
	for (i = 0; i < 4; i++)
		s = s + none[i];
	for (i = 0; i < 8; i++)
		s = s + lut[i];
	for (i = 0; i < 3; i++)
		s = s + scaled[i];
	return s;
}

long strs(void)
{
	long s;
	long i;

	s = 0;
	for (i = 0; text[i]; i++)
		s = s * 3 + text[i];
	for (i = 0; i < 8; i++)
		s = s + fixed[i];
	for (i = 0; i < 3; i++)
		s = s * 7 + names[i][0];
	return s;
}

long recs(void)
{
	long s;

	s = pt.x * 100 + pt.y;
	s = s * 10 + pts[0].x + pts[1].y + pts[2].x;
	s = s + q.tag + q.at.x * 3 + q.at.y * 5;
	return s + (q.big % 1000);
}

long ptrs(void)
{
	return *pflat * 100 + *pmid;
}

long floats(void)
{
	long i;
	double s;

	s = 0.0;
	for (i = 0; i < 3; i++)
		s = s + dbl[i] * 100.0;
	return (long)s;
}

long statics(long n)
{
	static const byte log2tab[8] = {0, 1, 2, 2, 3, 3, 3, 3};
	static long count = 0;
	static char label[] = "st";

	count = count + n;
	return log2tab[n & 7] * 1000 + count * 10 + label[0] - 'a';
}

long locals(void)
{
	int a[4] = {5, 6, 7, 8};
	struct P p = {40, 50};
	char buf[6] = "abc";
	long s;
	long i;

	s = 0;
	for (i = 0; i < 4; i++)
		s = s * 10 + a[i];
	s = s * 100 + p.x + p.y;
	for (i = 0; i < 6; i++)
		s = s + buf[i];
	a[2] = 0;
	return s + a[2];
}
