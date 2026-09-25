// Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
//
// The first program: the console as 0, 1 and 2, then the shell; when
// the shell ends, init does, and with it the machine (proc.c's exit).
#include "user.h"

char *argv[] = { "sh", 0 };

void
main(void)
{
	int pid, status;

	if(open("console", O_RDWR) < 0)
		exit(1);
	dup(0);
	dup(0);
	if((pid = fork()) == 0){
		exec("sh", argv);
		print("init: exec sh failed\n");
		exit(1);
	}
	status = 0;
	while(wait(&status) != pid)
		;
	exit(status);
}
