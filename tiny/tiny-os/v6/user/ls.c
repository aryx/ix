// Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
//
// ls [path]: each name of a directory (or the file) with its type, its
// inode and its size, as xv6's.
#include "user.h"

void
show(char *name, char *path)
{
	int fd;
	struct stat st;

	if((fd = open(path, O_RDONLY)) < 0 || fstat(fd, &st) < 0){
		print("ls: cannot stat %s\n", path);
		return;
	}
	close(fd);
	print("%s %d %d %d\n", name, st.type, st.ino, st.size);
}

void
main(int argc, char *argv[])
{
	char *path, full[64], name[13];
	int fd, n;
	struct stat st;
	struct dirent de;

	path = argc > 1 ? argv[1] : ".";
	if((fd = open(path, O_RDONLY)) < 0 || fstat(fd, &st) < 0){
		print("ls: cannot open %s\n", path);
		exit(1);
	}
	if(st.type != T_DIR){
		show(path, path);
		exit(0);
	}
	while(read(fd, (char*)&de, sizeof de) == sizeof de){
		if(de.inum == 0)
			continue;
		for(n = 0; n < 12 && de.name[n]; n++)
			name[n] = de.name[n];
		name[n] = 0;
		sprint(full, "%s/%s", path, name);
		show(name, full);
	}
	exit(0);
}
