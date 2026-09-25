// Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
//
// tiny-os v6: processes, the scheduler, sleep and wakeup, the traps and
// the system calls (xv6's proc.c, trap.c, syscall.c and sysproc.c; the
// ideas, and their references: main.c).
// One lock for the process table (xv6's x86 version), right on several
// cores. The kernel is not preemptible (Unix V6's): a process in it runs
// until it sleeps or returns to user mode, where the timer preempts it;
// interrupts are on only there and in the scheduler's idle loop.
#include "defs.h"

struct proc proc[NPROC];
struct spinlock ptable_lock;
struct proc *initproc;
int nextpid = 1;

void
procinit(void)
{
	initlock(&ptable_lock, "ptable");
}

struct proc*
myproc(void)
{
	struct proc *p;

	push_off();
	p = mycpu()->proc;
	pop_off();
	return p;
}

// an unused slot, its kernel stack and its page table; the context
// starts in forkret, which releases the table's lock and goes to user
// mode
struct proc*
allocproc(void)
{
	struct proc *p;

	acquire(&ptable_lock);
	for(p = proc; p < &proc[NPROC]; p++)
		if(p->state == UNUSED)
			break;
	if(p == &proc[NPROC]){
		release(&ptable_lock);
		return 0;
	}
	p->state = EMBRYO;
	p->pid = nextpid++;
	release(&ptable_lock);
	if((p->kstack = kalloc()) == 0 || (p->pagetable = uvmcreate()) == 0){
		if(p->kstack)
			kfree(p->kstack);
		p->state = UNUSED;
		return 0;
	}
	memset(p->tf, 0, sizeof p->tf);
	p->tf[17] = (uint)p->kstack + PGSIZE;
	p->context.sp = (uint)p->kstack + PGSIZE;
	p->context.lr = (uint)forkret;
	p->sz = 0;
	p->killed = 0;
	p->xstate = 0;
	return p;
}

// with the table's lock
void
freeproc(struct proc *p)
{
	kfree(p->kstack);
	uvmfree(p->pagetable, p->sz);
	p->kstack = 0;
	p->pagetable = 0;
	p->pid = 0;
	p->parent = 0;
	p->chan = 0;
	p->state = UNUSED;
}

// the first process: exec("/init"), in five words of TinyCPU (xv6's
// initcode.S) and the path, copied to its first page

void
userinit(void)
{
	struct proc *p;
	uint pa;
	char *path;
	uint code[8];

	p = allocproc();
	initproc = p;
	uvmalloc(p->pagetable, 0, PGSIZE);
	pa = walkaddr(p->pagetable, USERBASE);
	// "/init" at USERBASE + 64; then: r1 = its address, r2 = 0 (no
	// argument), sys 8 (exec); if it returns, sys 0 (exit)
	path = (char*)(pa + 64);
	safestrcpy(path, "/init", 8);
	code[0] = 0x20100080;             // lui  r1, 0x80       r1 = 0x800000
	code[1] = 0x17110040;             // ori  r1, r1, 64     + 64
	code[2] = 0x11200000;             // addi r2, r0, 0
	code[3] = 0x3f000008;             // sys  8
	code[4] = 0x3f000000;             // sys  0
	memmove((char*)pa, (char*)code, 20);
	p->sz = PGSIZE;
	p->tf[16] = USERBASE;
	p->tf[14] = USERTOP;
	safestrcpy(p->name, "initcode", 16);
	p->cwd = namei("/");
	p->state = RUNNABLE;
}

int
growproc(int n)
{
	struct proc *p;
	uint sz;

	p = myproc();
	sz = p->sz;
	if(n > 0){
		if((sz = uvmalloc(p->pagetable, sz, sz + n)) == 0)
			return -1;
	} else if(n < 0){
		uvmunmap(p->pagetable, sz + n, sz);
		sz = sz + n;
	}
	p->sz = sz;
	return 0;
}

int
fork(void)
{
	int i, pid;
	struct proc *np, *p;

	p = myproc();
	if((np = allocproc()) == 0)
		return -1;
	if(uvmcopy(p->pagetable, np->pagetable, p->sz) < 0){
		acquire(&ptable_lock);
		freeproc(np);
		release(&ptable_lock);
		return -1;
	}
	np->sz = p->sz;
	memmove(np->tf, p->tf, 17 * 4);
	np->tf[1] = 0;
	for(i = 0; i < NOFILE; i++)
		if(p->ofile[i])
			np->ofile[i] = filedup(p->ofile[i]);
	np->cwd = idup(p->cwd);
	safestrcpy(np->name, p->name, 16);
	pid = np->pid;
	acquire(&ptable_lock);
	np->parent = p;
	np->state = RUNNABLE;
	release(&ptable_lock);
	return pid;
}

// with the table's lock
void
wakeup1(void *chan)
{
	struct proc *p;

	for(p = proc; p < &proc[NPROC]; p++)
		if(p->state == SLEEPING && p->chan == chan)
			p->state = RUNNABLE;
}

// init's end is the machine's: its status is the halt's
void
exit(int status)
{
	struct proc *p, *q;
	int fd;

	p = myproc();
	if(p == initproc)
		halt(status);
	for(fd = 0; fd < NOFILE; fd++)
		if(p->ofile[fd]){
			fileclose(p->ofile[fd]);
			p->ofile[fd] = 0;
		}
	iput(p->cwd);
	p->cwd = 0;
	acquire(&ptable_lock);
	wakeup1(p->parent);
	for(q = proc; q < &proc[NPROC]; q++)
		if(q->parent == p){
			q->parent = initproc;
			if(q->state == ZOMBIE)
				wakeup1(initproc);
		}
	p->xstate = status;
	p->state = ZOMBIE;
	sched();
	panic("zombie exit");
}

int
wait(uint addr)
{
	struct proc *p, *q;
	int kids, pid;

	p = myproc();
	acquire(&ptable_lock);
	for(;;){
		kids = 0;
		for(q = proc; q < &proc[NPROC]; q++){
			if(q->parent != p)
				continue;
			kids = 1;
			if(q->state == ZOMBIE){
				pid = q->pid;
				if(addr != 0 && copyout(p->pagetable, addr, (char*)&q->xstate, 4) < 0){
					release(&ptable_lock);
					return -1;
				}
				freeproc(q);
				release(&ptable_lock);
				return pid;
			}
		}
		if(!kids || p->killed){
			release(&ptable_lock);
			return -1;
		}
		sleep(p, &ptable_lock);
	}
}

// each core's loop: a runnable process, its page table, a switch to it;
// interrupts on between two looks, the kernel's only interruptible place
void
scheduler(void)
{
	struct proc *p;
	struct cpu *c;

	c = mycpu();
	c->proc = 0;
	for(;;){
		intr_on();
		acquire(&ptable_lock);
		for(p = proc; p < &proc[NPROC]; p++){
			if(p->state != RUNNABLE)
				continue;
			p->state = RUNNING;
			c->proc = p;
			w_satp(SATP_ON | ((uint)p->pagetable >> 12));
			swtch(&c->context, &p->context);
			c->proc = 0;
		}
		release(&ptable_lock);
	}
}

// to the scheduler, with the table's lock and nothing else
void
sched(void)
{
	int intena;
	struct proc *p;

	p = myproc();
	if(!holding(&ptable_lock))
		panic("sched: lock");
	if(mycpu()->noff != 1)
		panic("sched: locks");
	if(p->state == RUNNING)
		panic("sched: running");
	intena = mycpu()->intena;
	swtch(&p->context, &mycpu()->context);
	mycpu()->intena = intena;
}

void
yield(void)
{
	acquire(&ptable_lock);
	myproc()->state = RUNNABLE;
	sched();
	release(&ptable_lock);
}

// a new process's first step, from the scheduler's swtch
void
forkret(void)
{
	release(&ptable_lock);
	usertrapret();
}

// lk released while asleep, held again after
void
sleep(void *chan, struct spinlock *lk)
{
	struct proc *p;

	p = myproc();
	if(lk != &ptable_lock){
		acquire(&ptable_lock);
		release(lk);
	}
	p->chan = chan;
	p->state = SLEEPING;
	sched();
	p->chan = 0;
	if(lk != &ptable_lock){
		release(&ptable_lock);
		acquire(lk);
	}
}

void
wakeup(void *chan)
{
	acquire(&ptable_lock);
	wakeup1(chan);
	release(&ptable_lock);
}

int
kill(int pid)
{
	struct proc *p;

	acquire(&ptable_lock);
	for(p = proc; p < &proc[NPROC]; p++)
		if(p->pid == pid && p->state != UNUSED){
			p->killed = 1;
			if(p->state == SLEEPING)
				p->state = RUNNABLE;
			release(&ptable_lock);
			return 0;
		}
	release(&ptable_lock);
	return -1;
}

// ---------------------------------------------------------------- traps

// an interrupt's sources: the timer re-armed (its trap is the caller's
// yield), the console's bytes taken; the timer's bit returned
int
devintr(uint sources)
{
	if(sources & I_TIMER)
		w_timecmp(r_time() + TICK);
	if(sources & I_CONSOLE)
		consoleintr();
	return sources & I_TIMER;
}

// from user mode (entry.tm, the registers in the trap frame)
void
usertrap(void)
{
	struct proc *p;
	uint cause;
	int timer;

	p = myproc();
	cause = r_cause();
	timer = 0;
	if(cause == C_SYS){
		if(p->killed)
			exit(-1);
		syscall(r_tval());
	} else if(cause == C_INTR)
		timer = devintr(r_tval());
	else {
		printf("pid %d %s: trap %d at %x, %x\n", p->pid, p->name, cause, p->tf[16], r_tval());
		p->killed = 1;
	}
	if(p->killed)
		exit(-1);
	if(timer)
		yield();
	usertrapret();
}

void
usertrapret(void)
{
	userret(myproc()->tf);
}

// in the scheduler's idle loop
void
kerneltrap(void)
{
	if(r_cause() != C_INTR){
		printf("kerneltrap: cause %d, tval %x\n", r_cause(), r_tval());
		panic("kerneltrap");
	}
	devintr(r_tval());
}

// ---------------------------------------------------------------- system calls

// the arguments are the caller's r1, r2, r3 (usys.tm puts them there)
int
argint(int n)
{
	return myproc()->tf[1 + n];
}

int
argstr(int n, char *buf, int max)
{
	return copyinstr(myproc()->pagetable, buf, argint(n), max);
}

int sys_exit(void) { exit(argint(0)); return 0; }
int sys_fork(void) { return fork(); }
int sys_wait(void) { return wait(argint(0)); }
int sys_kill(void) { return kill(argint(0)); }
int sys_getpid(void) { return myproc()->pid; }

int
sys_sbrk(void)
{
	uint addr;

	addr = USERBASE + myproc()->sz;
	if(growproc(argint(0)) < 0)
		return -1;
	return addr;
}

// by their numbers, the machine's sys n: exit, write and read first,
// tiny-cpu's own three (a program runs on both)
int (*syscalls[])(void) = {
	sys_exit, sys_write, sys_read, sys_fork, sys_wait, sys_kill,
	sys_getpid, sys_sbrk, sys_exec, sys_open, sys_close, sys_dup,
	sys_pipe, sys_fstat, sys_chdir, sys_mkdir, sys_unlink, sys_mknod,
};

void
syscall(uint n)
{
	struct proc *p;

	p = myproc();
	if(n < sizeof syscalls / sizeof syscalls[0])
		p->tf[1] = syscalls[n]();
	else {
		printf("pid %d %s: unknown sys %d\n", p->pid, p->name, n);
		p->tf[1] = -1;
	}
}
