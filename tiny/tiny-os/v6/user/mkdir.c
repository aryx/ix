// Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
#include "user.h"

void
main(int argc, char *argv[])
{
	int i;

	for(i = 1; i < argc; i++)
		if(mkdir(argv[i]) < 0){
			print("mkdir: %s failed\n", argv[i]);
			exit(1);
		}
	exit(0);
}
