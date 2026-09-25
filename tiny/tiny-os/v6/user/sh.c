// Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
//
// The shell, xv6's in less: a line is commands separated by ';', each a
// pipeline of commands separated by '|', each words with '< file' and
// '> file'; cd is its own. Each command a child: fork, then exec, as
// Unix made shells small by making them two calls. The line's operators
// spaced out first, then its words split at the blanks.
#include "user.h"

char line[256], spaced[512];
char *toks[64];

// the command toks[0..n), in this process (a child): its redirections,
// then exec
void
runcmd(char **t, int n)
{
	char *argv[32];
	int i, argc;

	argc = 0;
	for(i = 0; i < n; i++){
		if(strcmp(t[i], "<") == 0 && i + 1 < n){
			close(0);
			if(open(t[++i], O_RDONLY) < 0){
				print("sh: cannot open %s\n", t[i]);
				exit(1);
			}
		} else if(strcmp(t[i], ">") == 0 && i + 1 < n){
			close(1);
			if(open(t[++i], O_CREATE | O_WRONLY | O_TRUNC) < 0){
				print("sh: cannot create %s\n", t[i]);
				exit(1);
			}
		} else if(argc < 31)
			argv[argc++] = t[i];
	}
	argv[argc] = 0;
	if(argc == 0)
		exit(0);
	exec(argv[0], argv);
	print("sh: %s: not found\n", argv[0]);
	exit(1);
}

// a pipeline, in this process (a child): the first command writing
// into a pipe that the rest reads
void
runpipe(char **t, int n)
{
	int k, p[2];

	for(k = 0; k < n && strcmp(t[k], "|") != 0; k++)
		;
	if(k == n)
		runcmd(t, n);
	if(pipe(p) < 0)
		exit(1);
	if(fork() == 0){
		close(1);
		dup(p[1]);
		close(p[0]);
		close(p[1]);
		runcmd(t, k);
	}
	if(fork() == 0){
		close(0);
		dup(p[0]);
		close(p[0]);
		close(p[1]);
		runpipe(t + k + 1, n - k - 1);
	}
	close(p[0]);
	close(p[1]);
	wait(0);
	wait(0);
	exit(0);
}

// a line from the console, after the prompt; -1 at the input's end
int
getline(void)
{
	int n;

	write(1, "$ ", 2);
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

// the line's words, its operators words too
int
tokenize(void)
{
	char *s, *d;
	int n;

	d = spaced;
	for(s = line; *s; s++){
		if(*s == '<' || *s == '>' || *s == '|' || *s == ';'){
			*d++ = ' ';
			*d++ = *s;
			*d++ = ' ';
		} else
			*d++ = *s;
	}
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
				continue;
			}
			if(fork() == 0)
				runpipe(toks + i, j - i);
			wait(0);
		}
	}
	exit(0);
}
