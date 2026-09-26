/* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 */
/* TinyML's runtime, compiled by tiny-c: the allocator and Cheney's
 * copying collector, the primitives the prelude names, stdout's
 * buffer, the uncaught exception, and main.
 *
 * A value is a word: an integer n as 2n+1, or the address of a block's
 * first field, the block's header the word before it (its size in
 * words << 10, its tag in the low byte: 247 a closure, 252 a string,
 * whose fields hold no value). The roots are the value stack, from its
 * base to ml_vsp (which the ML code stores before calling C), and the
 * program's globals (ml_globals, ml_nglobals, written by tiny-ml). A C
 * function that allocates pushes its values on the value stack first,
 * and reads them back: the collector moves them. */

typedef long long value;
typedef unsigned char uchar;

extern long write(int, void*, long);
extern void exit(int);
extern char *getenv(char*);
extern int atoi(char*);

extern void ml_start(value*);
extern value ml_globals[];
extern value ml_nglobals;

value *ml_vsp;
void *ml_handler;

static value vstack[1 << 22];  /* 32MB, in the bss, not malloc's 64MB */
#define MAXHEAP 8388608       /* words, a half's */
static value space0[MAXHEAP];
static value space1[MAXHEAP];
static value *from;           /* the heap: from..limit, allocated up to hp */
static value *other;          /* the other half */
static value *hp;
static value *limit;
static value size;
static value *lo;             /* the collector's: the space collected, */
static value *hi;
static value *next;           /* and where the next copy goes */

static void
fatal(char *msg)
{
	long n;

	for(n = 0; msg[n] != 0; n++)
		;
	write(2, msg, n);
	exit(2);
}

/* a value's copy in to-space: an integer or a pointer outside the space
 * collected (a static block) as is; a copied block's header is 0, its
 * first field the copy's address */
static value
copy(value v)
{
	value *p;
	value *q;
	value h;
	value n;
	value i;

	p = (value*)v;
	if((v & 1) != 0 || p < lo || p >= hi)
		return v;
	h = p[-1];
	if(h == 0)
		return p[0];
	n = h >> 10;
	q = next + 1;
	q[-1] = h;
	for(i = 0; i < n; i++)
		q[i] = p[i];
	next = q + n;
	p[-1] = 0;
	p[0] = (value)q;
	return (value)q;
}

/* Cheney: the roots copied, then the copies scanned, breadth first,
 * scan chasing next; the halves swapped */
static void
collect(void)
{
	value *to;
	value *scan;
	value *v;
	value n;
	value i;
	value h;

	to = other;
	lo = from;
	hi = limit;
	next = to;
	for(v = vstack; v < ml_vsp; v++)
		*v = copy(*v);
	for(i = 0; i < ml_nglobals; i++)
		ml_globals[i] = copy(ml_globals[i]);
	for(scan = to; scan < next; scan = scan + n + 1){
		h = *scan;
		n = h >> 10;
		if((h & 255) < 251)
			for(i = 1; i <= n; i++)
				scan[i] = copy(scan[i]);
	}
	other = from;
	from = to;
	hp = next;
}

/* if less than half is free after, the heap grows: its halves are
 * the bss's, as big as it can be, and size the part in use (goken's
 * malloc is a bump allocator of 64MB whose free is a no-op, and its
 * sbrk fails under Linux's ASLR: plan_bugs_goken.md) */
static void
gc(value need)
{
	collect();
	while((hp - from + need) * 2 > size && size < MAXHEAP)
		size = size * 2;
	if(size > MAXHEAP)
		size = MAXHEAP;
	limit = from + size;
	if(hp + need > limit)
		fatal("Fatal error: out of memory\n");
}

value
ml_alloc(value n, value tag)
{
	value *p;

	if(hp + n + 1 > limit)
		gc(n + 1);
	p = hp + 1;
	p[-1] = (n << 10) | tag;
	hp = p + n;
	return (value)p;
}

static void
push(value v)
{
	*ml_vsp = v;
	ml_vsp++;
}

static value
pop(void)
{
	ml_vsp--;
	return *ml_vsp;
}

static value
wosize(value v)
{
	return ((value*)v)[-1] >> 10;
}

/* strings: the last byte the number of padding bytes before it */
static value
string_alloc(value len)
{
	value w;
	value s;

	w = len / 8 + 1;
	s = ml_alloc(w, 252);
	((value*)s)[w - 1] = 0;
	((uchar*)s)[w * 8 - 1] = w * 8 - 1 - len;
	return s;
}

static value
length(value s)
{
	value w;

	w = wosize(s);
	return w * 8 - 1 - ((uchar*)s)[w * 8 - 1];
}

value
ml_string_length(value s)
{
	return length(s) * 2 + 1;
}

value
ml_string_get(value s, value i)
{
	i = i >> 1;
	if(i < 0 || i >= length(s))
		fatal("Fatal error: out-of-bound access in array or string\n");
	return ((uchar*)s)[i] * 2 + 1;
}

value
ml_string_make(value n, value c)
{
	value s;
	value i;

	n = n >> 1;
	s = string_alloc(n);
	for(i = 0; i < n; i++)
		((uchar*)s)[i] = c >> 1;
	return s;
}

value
ml_string_sub(value s, value ofs, value len)
{
	value r;
	value i;

	push(s);
	r = string_alloc(len >> 1);
	s = pop();
	for(i = 0; i < len >> 1; i++)
		((uchar*)r)[i] = ((uchar*)s)[(ofs >> 1) + i];
	return r;
}

value
ml_concat(value a, value b)
{
	value la;
	value lb;
	value s;
	value i;

	la = length(a);
	lb = length(b);
	push(a);
	push(b);
	s = string_alloc(la + lb);
	b = pop();
	a = pop();
	for(i = 0; i < la; i++)
		((uchar*)s)[i] = ((uchar*)a)[i];
	for(i = 0; i < lb; i++)
		((uchar*)s)[la + i] = ((uchar*)b)[i];
	return s;
}

/* n's digits at the end of buf; where they start */
static value
digits(value n, char *buf)
{
	value i;
	value d;
	value neg;

	neg = n < 0;
	i = 24;
	do {
		i--;
		d = n % 10;
		if(d < 0)
			d = -d;
		buf[i] = '0' + d;
		n = n / 10;
	} while(n != 0);
	if(neg){
		i--;
		buf[i] = '-';
	}
	return i;
}

value
ml_string_of_int(value v)
{
	char buf[24];
	value i;
	value k;
	value s;

	i = digits(v >> 1, buf);
	s = string_alloc(24 - i);
	for(k = 0; k < 24 - i; k++)
		((uchar*)s)[k] = buf[i + k];
	return s;
}

/* OCaml's compare: integers before blocks, then the tags, strings by
 * their bytes, the other blocks by their sizes then their fields */
static value
compare(value a, value b)
{
	value ta;
	value tb;
	value n;
	value m;
	value i;
	value c;
	uchar *p;
	uchar *q;

	if(a == b)
		return 0;
	if(a & 1){
		if(b & 1)
			return a < b ? -1 : 1;
		return -1;
	}
	if(b & 1)
		return 1;
	ta = ((value*)a)[-1] & 255;
	tb = ((value*)b)[-1] & 255;
	if(ta != tb)
		return ta < tb ? -1 : 1;
	if(ta == 252){
		n = length(a);
		m = length(b);
		p = (uchar*)a;
		q = (uchar*)b;
		for(i = 0; i < n && i < m; i++)
			if(p[i] != q[i])
				return p[i] < q[i] ? -1 : 1;
		return n < m ? -1 : n > m ? 1 : 0;
	}
	n = wosize(a);
	m = wosize(b);
	if(n != m)
		return n < m ? -1 : 1;
	for(i = 0; i < n; i++){
		c = compare(((value*)a)[i], ((value*)b)[i]);
		if(c != 0)
			return c;
	}
	return 0;
}

value
ml_compare(value a, value b)
{
	return compare(a, b) * 2 + 1;
}

value
ml_equal(value a, value b)
{
	return compare(a, b) == 0 ? 3 : 1;
}

/* stdout: ocaml-light's channel, a buffer written when full, flushed
 * by print_newline and at exit, lost on an uncaught exception */
static uchar obuf[4096];
static long olen;

static void
outc(value c)
{
	if(olen == 4096){
		write(1, obuf, 4096);
		olen = 0;
	}
	obuf[olen] = c;
	olen++;
}

static void
flush(void)
{
	if(olen > 0)
		write(1, obuf, olen);
	olen = 0;
}

value
ml_print_string(value s)
{
	value n;
	value i;

	n = length(s);
	for(i = 0; i < n; i++)
		outc(((uchar*)s)[i]);
	return 1;
}

value
ml_print_char(value c)
{
	outc(c >> 1);
	return 1;
}

value
ml_print_newline(value u)
{
	outc('\n');
	flush();
	return u;
}

value
ml_exit(value n)
{
	flush();
	exit(n >> 1);
	return 1;
}

/* an uncaught exception, as ocaml-light's printexc.c prints it: its
 * name, then its integer and string arguments (a single tuple's
 * fields, as Match_failure's) */
static char ebuf[256];
static long elen;

static void
eadd(char *s, value n)
{
	value i;

	for(i = 0; i < n && elen < 255; i++){
		ebuf[elen] = s[i];
		elen++;
	}
}

value
ml_uncaught(value exn)
{
	char buf[24];
	value b;
	value v;
	value i;
	value start;
	value name;

	name = ((value*)((value*)exn)[0])[0];
	eadd((char*)name, length(name));
	if(wosize(exn) >= 2){
		b = exn;
		start = 1;
		v = ((value*)exn)[1];
		if(wosize(exn) == 2 && (v & 1) == 0 && (((value*)v)[-1] & 255) == 0){
			b = v;
			start = 0;
		}
		eadd("(", 1);
		for(i = start; i < wosize(b); i++){
			if(i > start)
				eadd(", ", 2);
			v = ((value*)b)[i];
			if(v & 1)
				eadd(buf + digits(v >> 1, buf), 24 - digits(v >> 1, buf));
			else if((((value*)v)[-1] & 255) == 252){
				eadd("\"", 1);
				eadd((char*)v, length(v));
				eadd("\"", 1);
			}else
				eadd("_", 1);
		}
		eadd(")", 1);
	}
	write(2, "Fatal error: uncaught exception ", 32);
	write(2, ebuf, elen);
	write(2, "\n", 1);
	exit(2);
	return 1;
}

void
main(int argc, char *argv[])
{
	char *s;

	size = 1 << 18;
	s = getenv("ML_HEAP");
	if(s != 0)
		size = atoi(s);
	if(size < 16)
		size = 16;
	if(size > MAXHEAP)
		size = MAXHEAP;
	from = space0;
	other = space1;
	hp = from;
	limit = from + size;
	ml_vsp = vstack;
	ml_start(vstack);
	flush();
	exit(0);
}
