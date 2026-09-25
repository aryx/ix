// Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
//
// t6's tests from the inside, each its name and ok, or FAIL and why.
// It spawns itself for its children (t6tests <role> <arg>): there is no
// fork to share its code with them.
#include "user.h"

int failed;
char *me = "/t6tests";

void
fail(char *test, char *why)
{
	print("FAIL %s: %s\n", test, why);
	failed++;
}

// itself as a child in a role, its descriptors the map
int
child(char *role, char *arg, int *map)
{
	char *argv[4];

	argv[0] = me;
	argv[1] = role;
	argv[2] = arg;
	argv[3] = 0;
	return spawn(me, argv, map);
}

// ten children, each exiting with its number
void
spawns(void)
{
	int i, status, sum, map[3];
	char arg[4];

	map[0] = map[1] = map[2] = -1;
	for(i = 0; i < 10; i++){
		sprint(arg, "%d", i);
		if(child("exit", arg, map) < 0)
			fail("spawns", "spawn");
	}
	sum = 0;
	for(i = 0; i < 10; i++){
		status = -1;
		wait(&status);
		sum += status;
	}
	if(wait(0) != -1 || sum != 45)
		fail("spawns", "the statuses");
	print("spawns ok\n");
}

// 3,000 bytes from a child through a pipe: its writes blocked when the
// pipe is full, and short; the end when the child, the only writer, ends
void
pipes(void)
{
	int p[2], map[3], n, i, total, bad;
	char buf[100];

	if(pipe(p) < 0){
		fail("pipes", "pipe");
		return;
	}
	map[0] = -1;
	map[1] = p[1];
	map[2] = -1;
	child("writer", "", map);
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

// nothing inherited: a file open here, a child given nothing
void
capabilities(void)
{
	int fd, map[3], status;

	fd = open("/cap", O_CREATE | O_RDWR);
	map[0] = map[1] = map[2] = -1;
	child("nofds", "", map);
	status = -1;
	wait(&status);
	if(status != 0)
		fail("capabilities", "a descriptor inherited");
	close(fd);
	unlink("/cap");
	print("capabilities ok\n");
}

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
	fd = open("tf", O_RDONLY);
	total = 0;
	while((n = read(fd, buf, 300)) > 0){
		for(i = 0; i < n; i++)
			if(buf[i] != '0' + (total + i) / 500)
				fail("files", "the bytes");
		total += n;
	}
	close(fd);
	if(total != 3000 || unlink("tf") < 0 || open("tf", O_RDONLY) >= 0)
		fail("files", "the size, or unlink");
	print("files ok\n");
}

void
dirs(void)
{
	int fd;

	if(mkdir("dd") < 0 || chdir("dd") < 0){
		fail("dirs", "mkdir");
		return;
	}
	fd = open("f", O_CREATE | O_RDWR);
	close(fd);
	if(chdir("..") < 0 || open("dd/f", O_RDONLY) < 0)
		fail("dirs", "chdir ..");
	if(unlink("dd") >= 0)
		fail("dirs", "a full directory removed");
	if(unlink("dd/../dd/f") < 0 || unlink("dd") < 0)
		fail("dirs", "unlink");
	print("dirs ok\n");
}

void
mem(void)
{
	char *p;
	int i;

	if((p = sbrk(65536)) == (char*)-1){
		fail("mem", "sbrk");
		return;
	}
	for(i = 0; i < 65536; i += 4096)
		p[i] = i / 4096;
	for(i = 0; i < 65536; i += 4096)
		if(p[i] != i / 4096)
			fail("mem", "the bytes");
	sbrk(-65536);
	print("mem ok\n");
}

// a child storing past its partition, killed
void
fault(void)
{
	int map[3], status;

	map[0] = map[1] = map[2] = -1;
	child("fault", "", map);
	status = 0;
	wait(&status);
	if(status != -1)
		fail("fault", "not killed");
	print("fault ok\n");
}

// the lottery: the same work for two children, 9 tickets against 1; the
// first to end tells (the draws are the same every run)
void
lottery(void)
{
	int map[3], a, first, status;

	map[0] = map[1] = map[2] = -1;
	a = child("spin", "9", map);
	child("spin", "1", map);
	first = wait(&status);
	wait(&status);
	if(first != a)
		fail("lottery", "the 1 ticket ended first");
	print("lottery ok\n");
}

void
main(int argc, char *argv[])
{
	int i, n, w;
	char buf[100];

	if(argc > 1 && strcmp(argv[1], "exit") == 0)
		exit(atoi(argv[2]));
	if(argc > 1 && strcmp(argv[1], "writer") == 0){
		for(i = 0; i < 30; i++){
			memset(buf, 'a' + i % 26, 100);
			for(n = 0; n < 100; n += w)
				if((w = write(1, buf + n, 100 - n)) <= 0)
					exit(1);
		}
		exit(0);
	}
	if(argc > 1 && strcmp(argv[1], "nofds") == 0){
		for(i = 0; i < 8; i++)
			if(write(i, "x", 1) >= 0)
				exit(1);
		exit(0);
	}
	if(argc > 1 && strcmp(argv[1], "fault") == 0){
		*(int*)0x200000 = 1;
		exit(0);
	}
	if(argc > 1 && strcmp(argv[1], "spin") == 0){
		tickets(atoi(argv[2]));
		for(i = n = 0; i < 100000; i++)
			n += i;
		exit(0);
	}
	spawns();
	pipes();
	capabilities();
	files();
	dirs();
	mem();
	fault();
	lottery();
	if(failed)
		print("t6tests: %d FAILED\n", failed);
	else
		print("t6tests: ALL OK\n");
	exit(failed);
}
