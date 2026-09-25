// Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
//
// t6's shell: commands separated by ';', pipelines by '|', '< file' and
// '> file'; cd its own. With spawn and no fork: the shell opens what a
// command gets (a pipe's end, a file) and names it in spawn's map, the
// command's 0, 1 and 2; then closes its own copies. A child has what it
// is given and nothing else, so no pipe's end is ever left open in a
// child, the bug fork's inheritance makes easy (a pipe that never
// ends).
#include "user.h"

char line[256], spaced[512], paths[16][64];
char *toks[64];

// a line after the prompt; -1 at the input's end
int
getline(void)
{
	int n;

	print("$ ");
	for(n = 0; n < sizeof line - 1; n++){
		if(read(0, line + n, 1) != 1){
			if(n == 0)
				return -1;
			break;
		}
		if(line[n] == '\n')
			break;
	}
	line[n] = 0;
	return n;
}

// the line's words, its operators spaced out as words
int
tokenize(void)
{
	char *s, *d;
	int n;

	for(d = spaced, s = line; *s; s++)
		if(*s == '<' || *s == '>' || *s == '|' || *s == ';'){
			*d++ = ' ';
			*d++ = *s;
			*d++ = ' ';
		} else
			*d++ = *s;
	*d = 0;
	n = 0;
	for(s = spaced; *s && n < 63; ){
		while(*s == ' ' || *s == '\t')
			*s++ = 0;
		if(*s == 0)
			break;
		toks[n++] = s;
		while(*s && *s != ' ' && *s != '\t')
			s++;
	}
	return n;
}

// the command t[0..n) spawned, its 0 and 1 in and out unless redirected;
// what it was given closed here; its pid, or -1
int
command(char **t, int n, int in, int out, int slot)
{
	char *argv[32];
	int i, argc, map[3], pid, fin, fout;

	argc = 0;
	fin = fout = -1;
	for(i = 0; i < n; i++)
		if(strcmp(t[i], "<") == 0 && i + 1 < n)
			fin = open(t[++i], O_RDONLY);
		else if(strcmp(t[i], ">") == 0 && i + 1 < n)
			fout = open(t[++i], O_CREATE | O_WRONLY | O_TRUNC);
		else if(argc < 31)
			argv[argc++] = t[i];
	argv[argc] = 0;
	map[0] = fin >= 0 ? fin : in;
	map[1] = fout >= 0 ? fout : out;
	map[2] = 2;
	pid = -1;
	if(argc > 0){
		// a name without a '/' is a program of the root
		if(argv[0][0] == '/' || argv[0][0] == '.')
			strcpy(paths[slot], argv[0]);
		else
			sprint(paths[slot], "/%s", argv[0]);
		if((pid = spawn(paths[slot], argv, map)) < 0)
			print("sh: %s: not found\n", argv[0]);
	}
	if(fin >= 0)
		close(fin);
	if(fout >= 0)
		close(fout);
	return pid;
}

// a pipeline t[0..n): each command's output the next's input
void
pipeline(char **t, int n)
{
	int k, start, in, p[2], spawned;

	in = 0;
	spawned = 0;
	for(start = 0; start < n; start = k + 1){
		for(k = start; k < n && strcmp(t[k], "|") != 0; k++)
			;
		p[0] = -1;
		p[1] = 1;
		if(k < n && pipe(p) < 0){
			print("sh: no pipe\n");
			break;
		}
		if(command(t + start, k - start, in, p[1], spawned) >= 0)
			spawned++;
		if(in != 0)
			close(in);
		if(p[1] != 1)
			close(p[1]);
		in = p[0];
	}
	if(in > 0)
		close(in);
	for(; spawned > 0; spawned--)
		wait(0);
}

void
main(void)
{
	int n, i, j;

	while(getline() >= 0){
		n = tokenize();
		for(i = 0; i < n; i = j + 1){
			for(j = i; j < n && strcmp(toks[j], ";") != 0; j++)
				;
			if(j == i)
				continue;
			if(strcmp(toks[i], "cd") == 0){
				if(j - i < 2 || chdir(toks[i + 1]) < 0)
					print("sh: cd failed\n");
			} else
				pipeline(toks + i, j - i);
		}
	}
	exit(0);
}
