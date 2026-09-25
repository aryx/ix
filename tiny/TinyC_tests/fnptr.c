// Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
//
// Function pointers: a variable, a table indexed as a system call's
// (xv6's syscalls[]), a structure of them (xv6's devsw), a callback,
// ( *f)(x), and a call through a pointer in the middle of an
// expression (what is live below it saved).
#include "libc.h"

int add(int a, int b) { return a + b; }
int sub(int a, int b) { return a - b; }
int mul(int a, int b) { return a * b; }

int (*ops[])(int, int) = { add, sub, mul };

struct devsw {
	int (*read)(int);
	int (*write)(int, char*);
};

int
consread(int n)
{
	return n * 10;
}

int
conswrite(int n, char *s)
{
	print("write %d %s\n", n, s);
	return n;
}

struct devsw devsw[2];

int
apply(int (*f)(int, int), int x, int y)
{
	return f(x, y);
}

int
twice(int x)
{
	return 2 * x;
}

int (*pick(int i))(int, int)
{
	return ops[i];
}

void
main(int argc, char *argv[])
{
	int i;
	int (*f)(int, int);
	int (*g)(int);

	for(i = 0; i < 3; i++)
		print("ops[%d](7, 3) = %d\n", i, ops[i](7, 3));
	f = sub;
	print("%d %d\n", f(10, 4), (*f)(10, 4));
	print("%d\n", apply(mul, 6, 7));
	print("%d\n", apply(pick(0), 6, 7));
	devsw[1].read = consread;
	devsw[1].write = conswrite;
	print("%d\n", devsw[1].read(4));
	devsw[1].write(5, "hello");
	g = twice;
	print("%d\n", 1 + g(3) * (100 + g(g(1))));
	print("%d %d\n", f == sub, devsw[0].read == 0);
	exits(0);
}
