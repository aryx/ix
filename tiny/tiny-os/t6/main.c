// Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
//
// t6: the console's output, printf, the strings, and the boot.
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
