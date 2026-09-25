// Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
//
// tiny-os v6, xv6's kind of kernel for tiny-machine, in C (tiny-c -tm)
// and a page of assembly. xv6 (MIT, 2006-) is Unix's Sixth Edition
// redone for a teaching course; v6 is xv6 redone again, its ideas and
// its names on a machine designed to show them (pages, traps, a timer,
// a disk, and nothing else), in seven files where xv6 has thirty. t6
// (../t6/) is its free variant, which takes the other roads.
//
//     ./tiny-machine v6            (at the top of ix; or make run here)
//     $ echo hello | cat > f; cat f; ls; mkdir d; cd d; cd ..; rm f
//     $ usertests
//
// What it keeps of xv6, as xv6 has it:
//
// - {b Processes as Unix made them}: fork copies a process, exec
//   replaces its program, exit and wait end it; a shell is small because
//   these are two calls. Each process a kernel stack, a context switch
//   (swtch) between them, sleep and wakeup on a channel for what they
//   wait for.
// - {b Pages}: Sv32's two levels, a page table a process, fork copying
//   the pages, sbrk growing them, a stray access a fault that kills.
// - {b The file system in layers}: the disk's blocks, a buffer cache
//   (one process a block at a time), inodes (a file's blocks: 12 direct,
//   one indirect), directories (names to inodes), paths; pipes; the
//   console a device, through devsw's table of function pointers.
// - {b Spinlocks and multicore readiness}: locks on an atomic swap
//   (amoswap), push_off and pop_off counting, cpus[] by the core's
//   number, a lock order; one core today, the code right for more.
//
// Where it departs, each for a reason:
//
// - {b The kernel in every page table} (xv6's x86 way, not its RISC-V
//   one): a trap changes no page table, so there is no trampoline page;
//   the kernel low and identity-mapped, where the machine starts, a
//   process's space at 8 MB (vm.c).
// - {b swtch saves two registers}, sp and lr: tiny-c's callee may use
//   every register, so its caller has saved what it needs (entry.tm).
// - {b A kernel that is not preemptible}, Unix V6's: interrupts are on in
//   user mode and in the scheduler's idle loop only; one lock for the
//   process table (xv6's x86 version). Fewer places for a race.
// - {b The disk polled}, as tiny-machine moves a block at once; no
//   virtio. {b Interrupts by ip and ie}, a bit a source, no PLIC. {b An
//   a.out} of three words (a magic, the size, the entry), no ELF.
// - {b No log}, {b no links}: a crash between two writes may leave the
//   disk inconsistent (Unix's before fsck), a file has one name.
//
// Dropped from xv6: the log, link and link counts, sleep, uptime, ELF,
// virtio, the PLIC, the trampoline, kernel preemption, 64 bits. 18
// system calls (exit write read fork wait kill getpid sbrk exec open
// close dup pipe fstat chdir mkdir unlink mknod), exit, write and read
// first, tiny-cpu's own, so a program runs on both. 2,781 lines of code
// with the user side, against the 2,000 aimed at (plan_tiny_os.md).
//
// The test: make check, usertests (fork and wait, pipes, files,
// directories, sbrk, exec, a store into the kernel killed) and a script
// through the shell, against check.expected.
//
// Exercises, each in xv6's own way:
// - the log back (xv6's log.c): a system call's writes to the disk
//   atomic, and a crash test (the machine halted between two writes);
// - links and link counts (xv6's link, nlink);
// - fork copy-on-write: the pages shared read-only, copied at the first
//   write's fault (Mach, 4.4BSD);
// - sbrk lazy: pages given at their first fault;
// - several cores: tiny-machine with N of them, stepped in an order a
//   seed draws, so that a race comes back (plan_tiny_os.md, phase 5).
//
// References (all from memory): D. Ritchie and K. Thompson, "The UNIX
// Time-Sharing System" (CACM 1974); J. Lions, "A Commentary on the
// UNIX Operating System" (1977), the Sixth Edition line by line; M.
// Bach, "The Design of the UNIX Operating System" (1986), the buffer
// cache and sleep and wakeup; R. Cox, F. Kaashoek, R. Morris, "xv6: a
// simple, Unix-like teaching operating system" (MIT, the book and the
// code, 2006-); the RISC-V privileged specification, Sv32; its
// riscv32 fork (~/xv6/forks/riscv32), v6's model.
//
// This file: the start, and what every part uses: printf and panic,
// the strings, the pages' allocator, the spinlocks (xv6's main.c,
// printf.c, string.c, kalloc.c and spinlock.c).
#include "defs.h"

struct cpu cpus[NCPU];

// the console's output, and the machine's halt: the devices' registers,
// at the same address with the pages off (the machine wraps it to the
// top of memory) or on (the devices' page, mapped there)
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

// %d %u %x %s %c %p %%; the arguments walked from fmt's address, as
// tiny-c passes them in memory
void
printf(char *fmt, ...)
{
	int *ap;
	char tmp[12], *s;
	uint v, base;
	int n;

	ap = (int*)&fmt + 1;
	for(; *fmt; fmt++){
		if(*fmt != '%'){
			consputc(*fmt);
			continue;
		}
		fmt++;
		if(*fmt == 's'){
			s = (char*)*ap++;
			if(s == 0)
				s = "(null)";
			for(; *s; s++)
				consputc(*s);
		} else if(*fmt == 'c'){
			consputc(*ap++);
		} else if(*fmt == 'd' || *fmt == 'u' || *fmt == 'x' || *fmt == 'p'){
			v = *ap++;
			base = 10;
			if(*fmt == 'x' || *fmt == 'p')
				base = 16;
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
		} else
			consputc(*fmt);
	}
}

void
panic(char *s)
{
	printf("panic: %s\n", s);
	halt(1);
}

// the strings; memset and memmove by words when they can (the machine
// counts instructions: a page zeroed by bytes is 4,096 stores)
void*
memset(void *p, int c, uint n)
{
	char *d;
	int *w;

	d = p;
	if(c == 0 && ((uint)d & 3) == 0 && (n & 3) == 0){
		for(w = (int*)d; n > 0; n -= 4)
			*w++ = 0;
		return p;
	}
	for(; n > 0; n--)
		*d++ = c;
	return p;
}

void*
memmove(void *dst, void *src, uint n)
{
	char *d, *s;
	int *wd, *ws;

	d = dst;
	s = src;
	if(s < d && s + n > d){
		for(d += n, s += n; n > 0; n--)
			*--d = *--s;
		return dst;
	}
	if((((uint)d | (uint)s | n) & 3) == 0){
		wd = (int*)d;
		ws = (int*)s;
		for(; n > 0; n -= 4)
			*wd++ = *ws++;
		return dst;
	}
	for(; n > 0; n--)
		*d++ = *s++;
	return dst;
}

int
strncmp(char *a, char *b, uint n)
{
	for(; n > 0 && *a && *a == *b; n--, a++, b++)
		;
	if(n == 0)
		return 0;
	return (*a & 255) - (*b & 255);
}

char*
safestrcpy(char *d, char *s, int n)
{
	char *r;

	r = d;
	for(; n > 1 && *s; n--)
		*d++ = *s++;
	*d = 0;
	return r;
}

int
strlen(char *s)
{
	int n;

	for(n = 0; s[n]; n++)
		;
	return n;
}

uint
pgroundup(uint a)
{
	return (a + PGSIZE - 1) & ~(PGSIZE - 1);
}

uint
pgrounddown(uint a)
{
	return a & ~(PGSIZE - 1);
}

// the spinlocks, on the machine's atomic swap; push_off and pop_off
// keep the interrupts off while a core holds one, counting (xv6's)
void
initlock(struct spinlock *lk, char *name)
{
	lk->locked = 0;
	lk->name = name;
	lk->cpu = 0;
}

struct cpu*
mycpu(void)
{
	return &cpus[r_hartid()];
}

void
push_off(void)
{
	int old;

	old = intr_get();
	intr_off();
	if(mycpu()->noff == 0)
		mycpu()->intena = old;
	mycpu()->noff++;
}

void
pop_off(void)
{
	struct cpu *c;

	c = mycpu();
	if(intr_get())
		panic("pop_off: interruptible");
	if(c->noff < 1)
		panic("pop_off");
	c->noff--;
	if(c->noff == 0 && c->intena)
		intr_on();
}

int
holding(struct spinlock *lk)
{
	return lk->locked && lk->cpu == mycpu();
}

void
acquire(struct spinlock *lk)
{
	push_off();
	if(holding(lk))
		panic(lk->name);
	while(amoswap(&lk->locked, 1) != 0)
		;
	lk->cpu = mycpu();
}

void
release(struct spinlock *lk)
{
	if(!holding(lk))
		panic("release");
	lk->cpu = 0;
	amoswap(&lk->locked, 0);
	pop_off();
}

// the pages' allocator: a list of the free pages, from the kernel's
// end to KERNTOP, each page's first word the next
struct spinlock kmem_lock;
int *kmem_free;

void
kfree(void *pa)
{
	int *r;

	if(((uint)pa % PGSIZE) != 0 || (char*)pa < end || (uint)pa >= KERNTOP)
		panic("kfree");
	r = pa;
	acquire(&kmem_lock);
	*r = (int)kmem_free;
	kmem_free = r;
	release(&kmem_lock);
}

void*
kalloc(void)
{
	int *r;

	acquire(&kmem_lock);
	r = kmem_free;
	if(r)
		kmem_free = (int*)*r;
	release(&kmem_lock);
	return r;
}

int
kfreecount(void)
{
	int n;
	int *r;

	n = 0;
	for(r = kmem_free; r; r = (int*)*r)
		n++;
	return n;
}

void
kinit(void)
{
	uint p;

	initlock(&kmem_lock, "kmem");
	for(p = pgroundup((uint)end); p + PGSIZE <= KERNTOP; p += PGSIZE)
		kfree((void*)p);
}

// the boot: the pages, the kernel's page table, the tables of
// processes and files, the file system, the first process; then the
// scheduler, for good
void
main(void)
{
	kinit();
	kvminit();
	procinit();
	fileinit();
	fsinit();
	w_tvec((uint)trapvec);
	w_ie(I_TIMER | I_CONSOLE);
	w_timecmp(r_time() + TICK);
	printf("tiny-os v6: %d free pages\n", kfreecount());
	userinit();
	scheduler();
}
