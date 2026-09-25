// Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
#include "user.h"

char buf[512];

void
main(int argc, char *argv[])
{
	int fd, i, n, l, w, c, inword;

	fd = 0;
	if(argc > 1 && (fd = open(argv[1], O_RDONLY)) < 0){
		print("wc: cannot open %s\n", argv[1]);
		exit(1);
	}
	l = w = c = inword = 0;
	while((n = read(fd, buf, sizeof buf)) > 0)
		for(i = 0; i < n; i++){
			c++;
			if(buf[i] == '\n')
				l++;
			if(buf[i] == ' ' || buf[i] == '\n' || buf[i] == '\t')
				inword = 0;
			else if(!inword){
				w++;
				inword = 1;
			}
		}
	print("%d %d %d\n", l, w, c);
	exit(0);
}
