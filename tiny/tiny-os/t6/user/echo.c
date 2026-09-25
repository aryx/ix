// Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
#include "user.h"

void
main(int argc, char *argv[])
{
	int i;

	for(i = 1; i < argc; i++)
		print("%s%s", argv[i], i + 1 < argc ? " " : "");
	print("\n");
	exit(0);
}
