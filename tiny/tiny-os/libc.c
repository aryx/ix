// Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
//
// The libc of tiny-c -tm's programs, compiled by tiny-c -tm: the part
// of Plan 9's that TinyC_tests/libc.h declares, in the C TinyC takes.
// print's verbs: %d %u %x %s %c %%, with l (ignored: a long is an int
// here); no widths, no long long (TinyCPU is 32 bits). %u is a verb,
// as in goken's libc (built without PLAN9PORT, its fmt.c), the
// reference the tests compare with: %ud is the number, then a d. A
// variadic function walks its arguments from its last named one: they
// are in memory, 4 bytes each (start.tm).

typedef unsigned long ulong;

extern int write(int, char*, int);

// fmt with the arguments at ap, into out; its length
static int
format(char *out, char *fmt, int *ap)
{
	char *o, *s, tmp[12];
	int n;
	unsigned v, base;

	o = out;
	for(; *fmt; fmt++){
		if(*fmt != '%'){
			*o++ = *fmt;
			continue;
		}
		fmt++;
		while(*fmt == 'l')
			fmt++;
		switch(*fmt){
		case 'd':
		case 'u':
		case 'x':
			v = *ap++;
			base = 10;
			if(*fmt == 'x')
				base = 16;
			if(*fmt == 'd' && (int)v < 0){
				*o++ = '-';
				v = -v;
			}
			n = 0;
			do {
				tmp[n++] = "0123456789abcdef"[v % base];
				v = v / base;
			} while(v);
			while(n > 0)
				*o++ = tmp[--n];
			break;
		case 's':
			s = (char*)*ap++;
			if(s == 0)
				s = "<nil>";
			while(*s)
				*o++ = *s++;
			break;
		case 'c':
			*o++ = *ap++;
			break;
		default:
			*o++ = *fmt;
		}
	}
	*o = 0;
	return o - out;
}

int
print(char *fmt, ...)
{
	char buf[1024];

	return write(1, buf, format(buf, fmt, (int*)&fmt + 1));
}

int
sprint(char *buf, char *fmt, ...)
{
	return format(buf, fmt, (int*)&fmt + 1);
}

long
strlen(char *s)
{
	char *p;

	for(p = s; *p; p++)
		;
	return p - s;
}

char*
strcpy(char *d, char *s)
{
	char *p;

	p = d;
	while(*p++ = *s++)
		;
	return d;
}

int
strcmp(char *a, char *b)
{
	for(; *a && *a == *b; a++, b++)
		;
	return (*a & 255) - (*b & 255);
}

void*
memset(void *p, int c, ulong n)
{
	char *q;

	for(q = p; n > 0; n--)
		*q++ = c;
	return p;
}

int
atoi(char *s)
{
	int n, neg;

	n = 0;
	neg = 0;
	while(*s == ' ')
		s++;
	if(*s == '-'){
		neg = 1;
		s++;
	}
	while(*s >= '0' && *s <= '9')
		n = n * 10 + *s++ - '0';
	if(neg)
		return -n;
	return n;
}

// the heap: a bump of an array, never given back
static char heap[65536];
static char *brk = heap;

void*
malloc(ulong n)
{
	char *p;

	p = brk;
	brk = brk + ((n + 7) & ~7);
	if(brk > heap + sizeof heap)
		return 0;
	return p;
}

void
free(void *p)
{
}
