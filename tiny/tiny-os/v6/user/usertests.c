// Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
//
// The kernel's tests from the inside, xv6's usertests in less: each
// prints its name and ok, or FAIL and why; the last line counts them.
#include "user.h"

int failed;

void
fail(char *test, char *why)
{
	print("FAIL %s: %s\n", test, why);
	failed++;
}

// ten children, each exiting with its number: every status collected
void
forks(void)
{
	int i, pid, status, sum;

	for(i = 0; i < 10; i++)
		if((pid = fork()) == 0)
			exit(i);
		else if(pid < 0)
			fail("forks", "fork");
	sum = 0;
	for(i = 0; i < 10; i++){
		status = -1;
		if(wait(&status) < 0)
			fail("forks", "wait");
		sum += status;
	}
	if(wait(0) != -1)
		fail("forks", "a child too many");
	if(sum != 45)
		fail("forks", "the statuses");
	print("forks ok\n");
}

// 3,000 bytes through a pipe, from a child
void
pipes(void)
{
	int p[2], i, n, total, bad;
	char buf[100];

	if(pipe(p) < 0){
		fail("pipes", "pipe");
		return;
	}
	if(fork() == 0){
		close(p[0]);
		for(i = 0; i < 30; i++){
			memset(buf, 'a' + i % 26, 100);
			write(p[1], buf, 100);
		}
		exit(0);
	}
	close(p[1]);
	total = bad = 0;
	while((n = read(p[0], buf, 70)) > 0){
		for(i = 0; i < n; i++)
			if(buf[i] != 'a' + (total + i) / 100 % 26)
				bad = 1;
		total += n;
	}
	close(p[0]);
	wait(0);
	if(total != 3000 || bad)
		fail("pipes", "the bytes");
	print("pipes ok\n");
}

// a file of three blocks written, read back, removed
void
files(void)
{
	int fd, i, n, total;
	char buf[500];

	if((fd = open("tf", O_CREATE | O_RDWR)) < 0){
		fail("files", "create");
		return;
	}
	for(i = 0; i < 6; i++){
		memset(buf, '0' + i, 500);
		if(write(fd, buf, 500) != 500)
			fail("files", "write");
	}
	close(fd);
	if((fd = open("tf", O_RDONLY)) < 0){
		fail("files", "open");
		return;
	}
	total = 0;
	while((n = read(fd, buf, 300)) > 0){
		for(i = 0; i < n; i++)
			if(buf[i] != '0' + (total + i) / 500)
				fail("files", "the bytes");
		total += n;
	}
	close(fd);
	if(total != 3000)
		fail("files", "the size");
	if(unlink("tf") < 0 || open("tf", O_RDONLY) >= 0)
		fail("files", "unlink");
	print("files ok\n");
}

// a directory made, entered, left, removed
void
dirs(void)
{
	int fd;

	if(mkdir("dd") < 0 || chdir("dd") < 0){
		fail("dirs", "mkdir");
		return;
	}
	if((fd = open("f", O_CREATE | O_RDWR)) < 0)
		fail("dirs", "create");
	close(fd);
	if(chdir("..") < 0)
		fail("dirs", "chdir ..");
	if(unlink("dd") >= 0)
		fail("dirs", "a full directory removed");
	if(unlink("dd/f") < 0 || unlink("dd") < 0)
		fail("dirs", "unlink");
	print("dirs ok\n");
}

// the memory grown by 64 KB, used, given back
void
mem(void)
{
	char *p;
	int i;

	p = sbrk(65536);
	if(p == (char*)-1){
		fail("mem", "sbrk");
		return;
	}
	for(i = 0; i < 65536; i += 4096)
		p[i] = i / 4096;
	for(i = 0; i < 65536; i += 4096)
		if(p[i] != i / 4096)
			fail("mem", "the bytes");
	if(sbrk(-65536) == (char*)-1)
		fail("mem", "sbrk back");
	print("mem ok\n");
}

// a child running echo; a child storing into the kernel, killed
void
execs(void)
{
	char *argv[3];
	int status, pid;

	argv[0] = "echo";
	argv[1] = "hello from exec";
	argv[2] = 0;
	if((pid = fork()) == 0){
		exec("echo", argv);
		exit(7);
	}
	status = -1;
	wait(&status);
	if(status != 0)
		fail("execs", "echo");
	if(fork() == 0){
		*(int*)0x1000 = 1;
		exit(0);
	}
	status = 0;
	wait(&status);
	if(status != -1)
		fail("execs", "a store into the kernel not killed");
	print("execs ok\n");
}

void
main(void)
{
	forks();
	pipes();
	files();
	dirs();
	mem();
	execs();
	if(failed)
		print("usertests: %d FAILED\n", failed);
	else
		print("usertests: ALL OK\n");
	exit(failed);
}
