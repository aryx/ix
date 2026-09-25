// Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
#include "user.h"

void
main(int argc, char *argv[])
{
	int i;

	for(i = 1; i < argc; i++){
		write(1, argv[i], strlen(argv[i]));
		write(1, i + 1 < argc ? " " : "\n", 1);
	}
	if(argc < 2)
		write(1, "\n", 1);
	exit(0);
}
