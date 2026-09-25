// Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
//
// The first program: the console opened, the shell spawned with it as
// its 0, 1 and 2; its end is init's, and the machine's.
#include "user.h"

char *argv[] = { "sh", 0 };
int map[] = { 0, 0, 0 };

void
main(void)
{
	int status;

	if(open("/console", O_RDWR) != 0 || spawn("/sh", argv, map) < 0)
		exit(1);
	status = 0;
	while(wait(&status) < 0)
		;
	exit(status);
}
