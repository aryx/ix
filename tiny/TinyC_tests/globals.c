#include "libc.h"

#define N 5
#define GREETING "hi there"

int primes[] = { 2, 3, 5, 7, 11, 13 };
char *words[] = { "alpha", "beta", "gamma" };
char msg[] = "static message";
static int counter = 40;
long table[N];
short half = -2;
char *greet = GREETING;

static int
next(void)
{
	return ++counter;
}

void
main(int argc, char *argv[])
{
	int i, s;

	s = 0;
	for(i = 0; i < sizeof(primes) / sizeof(primes[0]); i++)
		s += primes[i];
	print("%d %d\n", s, sizeof(primes));
	for(i = 0; i < 3; i++)
		print("%s ", words[i]);
	print("%s %d\n", msg, sizeof(msg));
	print("%d %d %d\n", next(), next(), counter);
	for(i = 0; i < N; i++)
		table[i] = half * i;
	print("%d %s\n", table[4], greet);
	exits(0);
}
