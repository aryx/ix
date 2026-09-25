// Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
//
// t6, tiny-os's free kernel, for tiny-machine, in C (tiny-c -tm) and a
// page of assembly. v6 (../v6/) is xv6's kind of kernel: fork and exec,
// a kernel stack per process, pages, inodes, spinlocks. t6 keeps what a
// user and a developer get from it (processes, programs from a disk, a
// shell with pipes and redirections, files and directories, the
// console, protection between processes, the same libc and tools) and
// takes other roads, each an idea of operating systems research:
//
//     ./tiny-machine t6            (at the top of ix; or make run here)
//     $ echo hello | wc; ls; mkdir d; cd d; echo x > f; cd ..; cat d/f
//     $ t6tests
//
// - {b One kernel stack; a call that must wait runs again.} A trap saves
//   the registers in the process's struct (entry.tm), the kernel runs on
//   its one stack, and leaves by resume, loading a process's registers:
//   no kernel stack per process, no swtch, no sleep in the kernel. A
//   call that must wait records what for and returns BLOCKED: the pc
//   goes back onto its sys, and the call runs again, from its start,
//   when the process is woken (proc.c's trap). So a call is written to
//   be rerun: it has done nothing when it blocks, or it returns what it
//   did, a short write (libc's print loops). Mach 3's continuations,
//   Fluke's atomic calls, seL4's one stack.
// - {b spawn, and no fork.} spawn(path, argv, map) makes a process
//   running a program, its descriptors 0, 1 and 2 the caller's map[0],
//   map[1], map[2], and none else: nothing is inherited. The shell
//   opens what a command gets and names it; no child is left holding a
//   pipe's end, the bug of fork's inheritance (a pipe that never ends).
//   Descriptors are capabilities, given, never ambient.
// - {b A partition a process, relocated.} Fourteen partitions of 1 MB,
//   a process's addresses its own (tiny-machine's window relocating,
//   status's bit 16); no pages. So a t6 program is a tiny-cpu program,
//   linked at 0, its arguments where tiny-cpu puts them.
// - {b A FAT, in memory} (file.c). A file is its directory entry, a
//   directory a file of entries; no inodes, no bitmap, no buffer cache
//   (the disk is instant). The current directory is a path, ".." is
//   resolved by its text: no "." or ".." on the disk.
// - {b A lottery for the scheduler.} Each process holds tickets
//   (tickets(n)); a draw among the ready ones picks who runs, at each
//   timer interrupt and each block: a share of the machine is a share
//   of the tickets, no priorities to tune. The draws are xorshift's,
//   the same every run.
// - {b One core, no locks}: the kernel runs with the interrupts off,
//   but in its idle loop. The price is v6's readiness for several
//   cores, given up on purpose.
//
// Kept from v6: the machine, the toolchain, libc (whose exit, write and
// read are sys 0, 1, 2 on tiny-cpu, v6 and t6), the user programs that
// use only calls in common (mkdir, rm, wc). Changed: spawn for fork and
// exec, the partitions for pages, the FAT for inodes, the lottery for
// round robin, 14 system calls (exit write read spawn wait getpid sbrk
// open close pipe mkdir unlink chdir tickets). Dropped: dup (spawn's
// map does its work), kill, fstat (a directory's entries tell a file's
// type and size), several cores. 1,756 lines of code with the user
// side, v6's 2,781.
//
// The test: make check, t6tests (spawns, pipes, capabilities: a child
// given nothing can write nowhere, files, directories with "..", sbrk,
// a fault killed, the lottery: the child of 9 tickets ends before the
// child of 1) and a script through the shell, against check.expected.
//
// Exercises, each cheap in this design:
// - the FAT twice on the disk (MS-DOS keeps two) and a crash between
//   two writes survived; or a directory's change committed at once,
//   copy-on-write, as TinyDatabase.ml's tree;
// - tickets lent: a process waiting on another lends it its tickets
//   (Waldspurger's transfers), so a server runs at its clients' share;
// - spawn's map widened to any descriptors (posix_spawn's file actions);
// - a partition's size chosen at spawn: variable partitions (OS/360's
//   MVT), and their fragmentation, the reason pages came.
//
// References (all from memory): R. Draves, B. Bershad, R. Rashid, R.
// Dean, "Using Continuations to Implement Thread Management and
// Communication in Operating Systems" (SOSP 1991); B. Ford, M. Hibler,
// J. Lepreau, R. McGrath, P. Tullmann, "Interface and Execution Models
// in the Fluke Kernel" (OSDI 1999); G. Klein et al., "seL4: Formal
// Verification of an OS Kernel" (SOSP 2009); A. Baumann, J. Appavoo,
// O. Krieger, T. Roscoe, "A fork() in the road" (HotOS 2019); R.
// Watson, J. Anderson, B. Laurie, K. Kennaway, "Capsicum: Practical
// Capabilities for UNIX" (USENIX Security 2010); J. Dennis and E. Van
// Horn, "Programming Semantics for Multiprogrammed Computations" (CACM
// 1966); P. Denning, "Virtual Memory" (Computing Surveys 1970), and
// IBM's OS/360 MFT (1966); T. Paterson's 86-DOS (1980) and its FAT; R.
// Pike, "Lexical File Names in Plan 9, or Getting Dot-Dot Right"
// (USENIX 2000); C. Waldspurger and W. Weihl, "Lottery Scheduling:
// Flexible Proportional-Share Resource Management" (OSDI 1994); G.
// Marsaglia, "Xorshift RNGs" (Journal of Statistical Software 2003).
//
// This file: the console's output, printf, the strings, and the boot.
#include "t6.h"

void
consputc(int c)
{
	*(char*)CONS_OUT = c;
}

void
halt(int status)
{
	*(int*)HALT = status;
}

// %d %u %x %s %c, the arguments walked from fmt's address
void
printf(char *fmt, ...)
{
	int *ap, n;
	char tmp[12], *s;
	uint v, base;

	ap = (int*)&fmt + 1;
	for(; *fmt; fmt++){
		if(*fmt != '%'){
			consputc(*fmt);
			continue;
		}
		fmt++;
		if(*fmt == 's'){
			for(s = (char*)*ap++; *s; s++)
				consputc(*s);
		} else if(*fmt == 'c')
			consputc(*ap++);
		else {
			v = *ap++;
			base = *fmt == 'x' ? 16 : 10;
			if(*fmt == 'd' && (int)v < 0){
				consputc('-');
				v = -v;
			}
			n = 0;
			do {
				tmp[n++] = "0123456789abcdef"[v % base];
				v = v / base;
			} while(v);
			while(n > 0)
				consputc(tmp[--n]);
		}
	}
}

void
panic(char *s)
{
	printf("panic: %s\n", s);
	halt(1);
}

// by words when it can (a partition zeroed by bytes is a million stores)
void*
memset(void *p, int c, uint n)
{
	char *d;
	int *w;

	if(c == 0 && (((uint)p | n) & 3) == 0){
		for(w = p; n > 0; n -= 4)
			*w++ = 0;
		return p;
	}
	for(d = p; n > 0; n--)
		*d++ = c;
	return p;
}

void*
memmove(void *dst, void *src, uint n)
{
	char *d, *s;

	d = dst;
	s = src;
	if(s < d && s + n > d)
		for(d += n, s += n; n > 0; n--)
			*--d = *--s;
	else
		for(; n > 0; n--)
			*d++ = *s++;
	return dst;
}

int
strcmp(char *a, char *b)
{
	for(; *a && *a == *b; a++, b++)
		;
	return (*a & 255) - (*b & 255);
}

int
strlen(char *s)
{
	int n;

	for(n = 0; s[n]; n++)
		;
	return n;
}

char*
strcpy(char *d, char *s)
{
	char *r;

	for(r = d; *s; )
		*d++ = *s++;
	*d = 0;
	return r;
}

void spawn1(struct proc *p, char *path);
void schedule(void);

// the disk's table, the trap vector, the timer, then /init, the first
// process, and the scheduler: from here on the kernel runs only on traps
void
main(void)
{
	fsinit();
	w_tvec((uint)trapvec);
	w_ie(I_TIMER | I_CONSOLE);
	w_timecmp(r_time() + TICK);
	printf("t6: tiny-os's free kernel, %d partitions of %d KB\n", NPROC, PART / 1024);
	spawn1(0, "/init");
	schedule();
}
