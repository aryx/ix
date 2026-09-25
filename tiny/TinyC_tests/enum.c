// Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
//
// enum: constants numbered from 0 or from the last given, as a type,
// in a switch and in a structure (xv6's procstate; its USED is EMBRYO,
// older xv6's name, as USED is a keyword of Plan 9's C).
#include "libc.h"

enum procstate { UNUSED, EMBRYO, SLEEPING, RUNNABLE, RUNNING, ZOMBIE };
enum { SMALL = 3, MEDIUM, LARGE = 10, HUGE };

struct proc {
	enum procstate state;
	int pid;
};

struct proc procs[4];

char*
name(enum procstate s)
{
	switch(s){
	case UNUSED: return "unused";
	case EMBRYO: return "embryo";
	case SLEEPING: return "sleeping";
	case RUNNABLE: return "runnable";
	case RUNNING: return "running";
	case ZOMBIE: return "zombie";
	}
	return "?";
}

void
main(int argc, char *argv[])
{
	int i;
	enum procstate s;

	print("%d %d %d %d\n", SMALL, MEDIUM, LARGE, HUGE);
	for(i = 0; i < 4; i++){
		procs[i].pid = i + 1;
		procs[i].state = i * 2 % 6;
	}
	for(i = 0; i < 4; i++)
		print("%d %s\n", procs[i].pid, name(procs[i].state));
	s = RUNNABLE;
	s++;
	print("%s %d\n", name(s), s == RUNNING);
	print("%d\n", sizeof(enum procstate));
	exits(0);
}
