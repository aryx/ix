#include "libc.h"

int
eight(int a, int b, int c, int d, int e, int f, int g, int h)
{
	return a + 2*b + 3*c + 4*d + 5*e + 6*f + 7*g + 8*h;
}

vlong
mix(char c, short s, vlong v, uchar u)
{
	return c + s + v + u;
}

int
sq(int x)
{
	return x * x;
}

void
main(int argc, char *argv[])
{
	int x;
	char buf[100];

	print("%d\n", eight(1, 2, 3, 4, 5, 6, 7, 8));
	x = 3;
	print("%d\n", x + sq(x + 1) * sq(sq(2)) - eight(x, x, x, x, x, x, x, sq(x)));
	print("%lld\n", mix(-1, -300, 1LL << 33, 255));
	sprint(buf, "%d-%s-%x-%c", 42, "str", 255, 'Z');
	print("%s %d\n", buf, strlen(buf) + atoi("17"));
	print("%d %d %d %d %d %d %d %d %d\n", 1, 2, 3, 4, 5, 6, 7, 8, sq(3));
	exits(0);
}
