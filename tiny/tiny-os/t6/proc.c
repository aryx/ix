// Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
//
// t6: processes, the scheduler, the trap, the system calls on processes
// (the ideas, and their references: main.c).
//
// A process is its registers and its partition: no kernel stack of its
// own. The kernel runs on one stack, from the trap to resume; a system
// call that must wait records what it waits for and returns BLOCKED,
// the process's pc goes back onto its sys, and the call runs again,
// from its start, when the process is woken (a call is written to be
// rerun: it has done nothing when it blocks, or it returns what it has
// done, a short write). The scheduler is a lottery: each process holds
// tickets, and a draw picks who runs.
#include "t6.h"

struct proc proc[NPROC];
struct proc *cur;
int nextpid = 1;
uint seed = 2463534242;

void exit1(struct proc *p, int status);
void fileclose(struct file *f);
int loadfile(struct proc *p, char *path, char *mem, uint max);

// a process's partition: its window's base
uint
base(struct proc *p)
{
	return (p - proc + 1) * PART;
}

// a user address, n bytes long, as the kernel sees it (physical); 0 if
// it leaves the partition
uint
uaddr(struct proc *p, uint va, uint n)
{
	if(va >= PART || n > PART - va)
		return 0;
	return base(p) + va;
}

// a string from the user, its length; -1 if too long or not the user's
int
ustr(struct proc *p, uint va, char *dst, int max)
{
	int i;
	uint a;

	for(i = 0; i < max; i++){
		if((a = uaddr(p, va + i, 1)) == 0)
			return -1;
		if((dst[i] = *(char*)a) == 0)
			return i;
	}
	return -1;
}

int
block(void *chan)
{
	cur->state = WAITING;
	cur->chan = chan;
	return BLOCKED;
}

void
wakeup(void *chan)
{
	struct proc *p;

	for(p = proc; p < &proc[NPROC]; p++)
		if(p->state == WAITING && p->chan == chan)
			p->state = READY;
}

// a new process running the program at path, its arguments argv (the
// kernel's strings), its descriptors 0, 1, 2 its parent's map[0..2]
// (-1: none): what it is given, nothing else, no descriptor inherited
int
spawn(struct proc *parent, char *path, char **argv, int *map)
{
	struct proc *p;
	char *mem;
	int i, argc, size, len;
	uint top, sp, u[20];

	for(p = proc; p < &proc[NPROC] && p->state != FREE; p++)
		;
	if(p == &proc[NPROC])
		return -1;
	mem = (char*)base(p);
	if((size = loadfile(parent, path, mem, PART - STACK)) < 0)
		return -1;
	top = (size + 3) & ~3;
	memset(mem + size, 0, top - size);
	memzero(mem + top, PART - top);
	// the arguments as tiny-cpu leaves them: the strings at the top,
	// the pointers below, argc at sp and argv above it (start.tm's)
	top = PART;
	for(argc = 0; argv[argc] && argc < 16; argc++){
		len = strlen(argv[argc]);
		top = (top - len - 1) & ~3;
		memmove(mem + top, argv[argc], len + 1);
		u[2 + argc] = top;
	}
	u[2 + argc] = 0;
	sp = (top - (argc + 3) * 4) & ~7;
	u[0] = argc;
	u[1] = sp + 8;
	memmove(mem + sp, u, (argc + 3) * 4);
	memset(p->r, 0, sizeof p->r);
	p->r[14] = sp;
	p->pc = 0;
	p->pid = nextpid++;
	p->parent = parent;
	p->xstate = 0;
	p->brk = size;
	p->tickets = parent ? parent->tickets : 1;
	for(i = 0; i < NFD; i++)
		p->fd[i] = 0;
	for(i = 0; i < 3; i++)
		if(parent && map && map[i] >= 0 && map[i] < NFD && parent->fd[map[i]])
			p->fd[i] = filedup(parent->fd[map[i]]);
	strcpy(p->cwd, parent ? parent->cwd : "/");
	for(i = strlen(path); i > 0 && path[i - 1] != '/'; i--)
		;
	memmove(p->name, path + i, 15);
	p->name[15] = 0;
	p->state = READY;
	return p->pid;
}

// the first process: its descriptors are its own (init opens the console)
void
spawn1(struct proc *parent, char *path)
{
	char *argv[2];

	argv[0] = path;
	argv[1] = 0;
	if(spawn(parent, path, argv, 0) < 0)
		panic("no /init");
}

// init's end is the machine's
void
exit1(struct proc *p, int status)
{
	struct proc *q;
	int fd;

	if(p == &proc[0])
		halt(status);
	for(fd = 0; fd < NFD; fd++)
		if(p->fd[fd]){
			fileclose(p->fd[fd]);
			p->fd[fd] = 0;
		}
	for(q = proc; q < &proc[NPROC]; q++)
		if(q->state != FREE && q->parent == p)
			q->parent = &proc[0];
	p->xstate = status;
	p->state = ZOMBIE;
	wakeup(p->parent);
	wakeup(&proc[0]);
}

// ---------------------------------------------------------------- the scheduler

void
run(struct proc *p)
{
	cur = p;
	w_base(base(p));
	w_bound(PART);
	resume(p);
}

// the lottery (Waldspurger and Weihl): a draw among the ready processes'
// tickets, by xorshift (the same draws every run); none ready, the
// interrupts let in, one instruction at a time, until one is
void
schedule(void)
{
	struct proc *p;
	uint total, draw;

	for(;;){
		total = 0;
		for(p = proc; p < &proc[NPROC]; p++)
			if(p->state == READY)
				total += p->tickets;
		if(total)
			break;
		intr_on();
		intr_off();
	}
	seed = seed ^ (seed << 13);
	seed = seed ^ (seed >> 17);
	seed = seed ^ (seed << 5);
	draw = seed % total;
	for(p = proc; ; p++)
		if(p->state == READY){
			if(draw < p->tickets)
				break;
			draw -= p->tickets;
		}
	run(p);
}

// an interrupt's sources: the timer re-armed (its one said), the
// console's bytes taken
int
devintr(uint sources)
{
	if(sources & I_CONSOLE)
		consoleintr();
	if(sources & I_TIMER){
		w_timecmp(r_time() + TICK);
		return 1;
	}
	return 0;
}

// in the idle loop (entry.tm)
void
interrupt(void)
{
	devintr(r_tval());
}

// ---------------------------------------------------------------- system calls

int
sys_exit(void)
{
	exit1(cur, cur->r[1]);
	return 0;
}

// spawn(path, argv, map): the strings and the map copied in
int
sys_spawn(void)
{
	char path[64], strs[512], *argv[17];
	int i, n, len, map[3];
	uint a;

	if(ustr(cur, cur->r[1], path, 64) < 0)
		return -1;
	n = 0;
	for(i = 0; i < 16; i++){
		if((a = uaddr(cur, cur->r[2] + 4 * i, 4)) == 0)
			return -1;
		if(*(uint*)a == 0)
			break;
		argv[i] = strs + n;
		if((len = ustr(cur, *(uint*)a, strs + n, 512 - n)) < 0)
			return -1;
		n += len + 1;
	}
	argv[i] = 0;
	for(i = 0; i < 3; i++)
		map[i] = -1;
	if(cur->r[3] != 0){
		if((a = uaddr(cur, cur->r[3], 12)) == 0)
			return -1;
		memmove(map, (char*)a, 12);
	}
	return spawn(cur, path, argv, map);
}

// wait(&status): a child's end, the child freed; blocked while it runs
int
sys_wait(void)
{
	struct proc *q;
	int kids, pid;
	uint a;

	kids = 0;
	for(q = proc; q < &proc[NPROC]; q++){
		if(q->state == FREE || q->parent != cur)
			continue;
		kids = 1;
		if(q->state == ZOMBIE){
			if(cur->r[1] && (a = uaddr(cur, cur->r[1], 4)) != 0)
				*(int*)a = q->xstate;
			pid = q->pid;
			q->state = FREE;
			return pid;
		}
	}
	if(!kids)
		return -1;
	return block(cur);
}

int
sys_getpid(void)
{
	return cur->pid;
}

// the program's end moved, below the stack's reserve; its old place
int
sys_sbrk(void)
{
	uint old;
	int n;

	old = cur->brk;
	n = cur->r[1];
	if((int)old + n < 0 || old + n > PART - STACK)
		return -1;
	if(n > 0)
		memset((char*)base(cur) + old, 0, n);
	cur->brk = old + n;
	return old;
}

// the lottery's tickets
int
sys_tickets(void)
{
	cur->tickets = (int)cur->r[1] > 0 ? cur->r[1] : 1;
	return 0;
}

// by their numbers, the machine's sys n: exit, write and read first,
// tiny-cpu's own (a program of both runs on either)
int (*calls[])(void) = {
	sys_exit, sys_write, sys_read, sys_spawn, sys_wait, sys_getpid, sys_sbrk,
	sys_open, sys_close, sys_pipe, sys_mkdir, sys_unlink, sys_chdir, sys_tickets,
};

// every trap from user mode (entry.tm): a system call, an interrupt, a
// fault; then the same process again, or the lottery's
void
trap(void)
{
	uint cause, n;
	int r, timer;

	cause = r_cause();
	timer = 0;
	if(cause == C_SYS){
		n = r_tval();
		r = n < sizeof calls / sizeof calls[0] ? calls[n]() : -1;
		if(r == BLOCKED)
			cur->pc -= 4;
		else if(cur->state != ZOMBIE)
			cur->r[1] = r;
	} else if(cause == C_INTR)
		timer = devintr(r_tval());
	else {
		printf("t6: %d %s: trap %d at %x, %x: killed\n", cur->pid, cur->name, cause, cur->pc, r_tval());
		exit1(cur, -1);
	}
	if(timer || cur->state != READY)
		schedule();
	run(cur);
}
