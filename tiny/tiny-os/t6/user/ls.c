// Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
//
// ls [dir]: each entry of a directory, as read from it: its name, its
// type, its size (a file is its entry: nothing else to ask).
#include "user.h"

void
main(int argc, char *argv[])
{
	struct dirent d;
	char name[21];
	int fd, i;

	if((fd = open(argc > 1 ? argv[1] : ".", O_RDONLY)) < 0){
		print("ls: cannot open %s\n", argc > 1 ? argv[1] : ".");
		exit(1);
	}
	while(read(fd, (char*)&d, sizeof d) == sizeof d){
		if(d.type == 0)
			continue;
		for(i = 0; i < 20 && d.name[i]; i++)
			name[i] = d.name[i];
		name[i] = 0;
		print("%s %d %d\n", name, d.type, d.size);
	}
	exit(0);
}
