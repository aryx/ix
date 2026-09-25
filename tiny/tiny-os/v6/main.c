// Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
//
// tiny-os v6: the start, and what every part uses: printf and panic,
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
