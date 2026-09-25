// Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
#include "user.h"

char buf[512];

void
cat(int fd)
{
	int n;

	while((n = read(fd, buf, sizeof buf)) > 0)
		if(write(1, buf, n) != n){
			print("cat: write error\n");
			exit(1);
		}
}

void
main(int argc, char *argv[])
{
	int i, fd;

	if(argc <= 1)
		cat(0);
	for(i = 1; i < argc; i++){
		if((fd = open(argv[i], O_RDONLY)) < 0){
			print("cat: cannot open %s\n", argv[i]);
			exit(1);
		}
		cat(fd);
		close(fd);
	}
	exit(0);
}
