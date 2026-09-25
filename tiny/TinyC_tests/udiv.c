// Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
//
// Unsigned division and remainder at their edges: divisors past 2^31,
// dividends with the top bit set, powers of two. TinyCPU has only a
// signed division, so tiny-c -tm calls the runtime's __udivmod; the
// random programs rarely reach its corners.
#include "libc.h"

unsigned vals[] = { 0, 1, 2, 3, 7, 10, 255, 65535, 65536, 1000003,
	0x7fffffff, 0x80000000, 0x80000001, 0xc0000000, 0xfffffffe, 0xffffffff };

void
main(int argc, char *argv[])
{
	int i, j, n;
	unsigned a, b, sum;

	n = sizeof vals / sizeof vals[0];
	sum = 0;
	for(i = 0; i < n; i++)
		for(j = 1; j < n; j++){
			a = vals[i];
			b = vals[j];
			print("%ud / %ud = %ud rem %ud\n", a, b, a / b, a % b);
			sum = sum * 31 + a / b + a % b;
		}
	print("%ud\n", sum);
	exits(0);
}
