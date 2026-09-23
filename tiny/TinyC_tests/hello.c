#include "libc.h"

void
main(int argc, char *argv[])
{
	print("hello, %s: %d arguments\n", "world", argc);
	exits(0);
}
