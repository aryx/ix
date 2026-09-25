// Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
//
// A C program for tiny-cpu, compiled by tiny-c -tm: its arguments, a
// sum, a string built by sprint, the heap.
#include "libc/libc.h"

int
fib(int n)
{
	if(n < 2)
		return n;
	return fib(n - 1) + fib(n - 2);
}

void
main(int argc, char *argv[])
{
	int i;
	char buf[64], *p;

	print("hello from tiny-cpu, %d arguments:", argc);
	for(i = 0; i < argc; i++)
		print(" %s", argv[i]);
	print("\n");
	sprint(buf, "fib(%d) = %d", 20, fib(20));
	p = malloc(strlen(buf) + 1);
	strcpy(p, buf);
	print("%s, %d bytes, 0x%x unsigned: %u\n", p, strlen(p), 48879, -1);
	exits(0);
}
