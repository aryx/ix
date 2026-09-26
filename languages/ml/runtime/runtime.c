/* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 */
/* mini-ml's runtime (plan_ml.md, decision 5; the tutorial's section
 * 11), in C for mini-cc and goken's libc, on arm and arm64: the
 * allocator and Cheney's copying collector, the primitives the stdlib
 * names, the channels, the uncaught exception, and main. No assembly:
 * the code mini-ml generates calls ml_alloc and the others with 5c's
 * and 7c's convention, and main calls ml_start (the start object's).
 *
 * A value is a word: an integer n as 2n+1, or the address of a block's
 * first field, the block's header the word before it (its size in
 * words << 10, its tag in the low byte: 247 a closure, 252 a string,
 * 253 a float, whose fields hold no value). The roots: the value
 * stack, from its base to ml_vsp (the ML code stores its top there
 * before calling C), and the units' globals (ml_units, the start
 * object's table of each unit's). A C function that allocates pushes
 * its values on the value stack first, and reads them back: the
 * collector moves them. A static block (a string, a closure, an
 * exception) is outside the heap, and the collector leaves it.
 *
 * ocaml-light's names are kept (format_int, make_vect, caml_flush...),
 * and its behavior on arm64, the contract: stdout's buffer is 4096
 * bytes, flushed by flush and at exit, lost on an uncaught exception;
 * an index out of bounds a fatal error. Floats are for phase 7: their
 * primitives here fail when called. */

#include <u.h>
#include <libc.h>

typedef intptr value;
typedef uintptr uvalue;

#define W ((value)sizeof(value))
#define Val_int(n) ((((value)(n)) << 1) + 1)
#define Int_val(v) ((v) >> 1)
#define Val_unit Val_int(0)
#define Val_bool(b) ((b) ? Val_int(1) : Val_int(0))
#define Val_false Val_int(0)
#define Field(v, i) (((value*)(v))[i])
#define Hd(v) (((value*)(v))[-1])
#define Wosize(v) (((uvalue)Hd(v)) >> 10)
#define Tag(v) (Hd(v) & 255)
#define Is_int(v) (((v) & 1) != 0)
#define Bytes(v) ((uchar*)(v))
#define Double_val(v) (*(double*)(v))
#define Closure_tag 247
#define String_tag 252
#define Double_tag 253

extern void ml_start(value*);
extern void ml_raise(value);
extern value ml_units[];

value *ml_vsp;
void *ml_handler;

void failwith(char*);
static void raise_with(value*, char*);
static void raise_const(value*);

static void
fatal(char *msg)
{
	write(2, msg, strlen(msg));
	exit(2);
}

static void
unsupported(char *what)
{
	write(2, "mini-ml: ", 9);
	write(2, what, strlen(what));
	fatal(": not in the runtime yet\n");
}

/*****************************************************************************/
/* The heap: two halves in the bss, Cheney's collector */
/*****************************************************************************/

#define MAXHEAP 8388608         /* a half's words */
#define STACK 4194304           /* the value stack's */

static value space0[MAXHEAP];
static value space1[MAXHEAP];
static value vstack[STACK];
static value *from;             /* the heap: from..limit, allocated up to hp */
static value *other;
static value *hp;
static value *limit;
static value size;
static value *lo;               /* the collector's: the space collected, */
static value *hi;
static value *next;             /* and where the next copy goes */

/* the named values of Callback.register, roots too */
#define NAMED 64
static value named_names[NAMED];
static value named_values[NAMED];
static int nnamed;

/* a value's copy in to-space: an integer or a pointer outside the space
 * collected as is; a copied block's header is 0, its first field the
 * copy's address (every block has a field: an empty array is static) */
static value
copy(value v)
{
	value *p, *q;
	value h, n, i;

	p = (value*)v;
	if(Is_int(v) || p < lo || p >= hi)
		return v;
	h = p[-1];
	if(h == 0)
		return p[0];
	n = ((uvalue)h) >> 10;
	q = next + 1;
	q[-1] = h;
	for(i = 0; i < n; i++)
		q[i] = p[i];
	next = q + n;
	p[-1] = 0;
	p[0] = (value)q;
	return (value)q;
}

/* the roots copied, then the copies scanned, breadth first, scan
 * chasing next; the halves swapped */
static void
collect(void)
{
	value *scan, *v, *roots;
	value n, i, u, h;

	lo = from;
	hi = limit;
	next = other;
	for(v = vstack; v < ml_vsp; v++)
		*v = copy(*v);
	for(u = 1; u <= ml_units[0]; u++){
		roots = (value*)ml_units[u];
		for(i = 1; i <= roots[0]; i++){
			v = (value*)roots[i];
			*v = copy(*v);
		}
	}
	for(i = 0; i < nnamed; i++){
		named_names[i] = copy(named_names[i]);
		named_values[i] = copy(named_values[i]);
	}
	for(scan = other; scan < next; scan = scan + n + 1){
		h = *scan;
		n = ((uvalue)h) >> 10;
		if((h & 255) < 251)
			for(i = 1; i <= n; i++)
				scan[i] = copy(scan[i]);
	}
	other = from;
	from = lo == space0 ? space1 : space0;
	hp = next;
}

/* if less than half is free after, the heap grows, up to its halves */
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

/* Gc's: a collection, whichever was asked */
value gc_full_major(value u) { gc(0); return u; }
value gc_major(value u) { gc(0); return u; }
value gc_minor(value u) { gc(0); return u; }
value gc_compaction(value u) { gc(0); return u; }

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

/*****************************************************************************/
/* Strings: the last byte the number of padding bytes before it */
/*****************************************************************************/

static value
string_alloc(value len)
{
	value w, s;

	w = len / W + 1;
	s = ml_alloc(w, String_tag);
	Field(s, w - 1) = 0;
	Bytes(s)[w * W - 1] = w * W - 1 - len;
	return s;
}

static value
length(value s)
{
	return Wosize(s) * W - 1 - Bytes(s)[Wosize(s) * W - 1];
}

/* a C string as an ML one */
static value
ml_string(char *s)
{
	value r, n;

	n = strlen(s);
	r = string_alloc(n);
	memmove(Bytes(r), s, n);
	return r;
}

value
ml_string_length(value s)
{
	return Val_int(length(s));
}

static void
bound(value s, value i)
{
	if(i < 0 || i >= length(s))
		fatal("Fatal error: out-of-bound access in array or string\n");
}

value
ml_string_get(value s, value i)
{
	bound(s, Int_val(i));
	return Val_int(Bytes(s)[Int_val(i)]);
}

value
ml_string_set(value s, value i, value c)
{
	bound(s, Int_val(i));
	Bytes(s)[Int_val(i)] = Int_val(c);
	return Val_unit;
}

void
caml_array_bound_error(void)
{
	fatal("Fatal error: out-of-bound access in array or string\n");
}

value
create_string(value n)
{
	return string_alloc(Int_val(n));
}

value
blit_string(value s1, value o1, value s2, value o2, value n)
{
	memmove(Bytes(s2) + Int_val(o2), Bytes(s1) + Int_val(o1), Int_val(n));
	return Val_unit;
}

value
fill_string(value s, value o, value n, value c)
{
	value i;

	for(i = 0; i < Int_val(n); i++)
		Bytes(s)[Int_val(o) + i] = Int_val(c);
	return Val_unit;
}

value
is_printable(value c)
{
	c = Int_val(c);
	return Val_bool(c >= 32 && c < 127);
}

value
caml_string_equal(value a, value b)
{
	value n;

	n = length(a);
	if(n != length(b))
		return Val_false;
	return Val_bool(memcmp(Bytes(a), Bytes(b), n) == 0);
}

/* n's digits, in base b, at the end of buf; where they start */
static int
digits(uvalue n, int b, int upper, char *buf, int end)
{
	int d;

	do {
		d = n % b;
		buf[--end] = d < 10 ? '0' + d : (upper ? 'A' : 'a') + d - 10;
		n = n / b;
	} while(n != 0);
	return end;
}

/* printf's integers: %[-0 +]width[d i u x X o], as C's */
value
format_int(value fmt, value arg)
{
	char buf[96];
	uchar *f;
	int i, start, left, zero, sign, space, width, neg, b, upper, len, pad, k;
	value n;
	uvalue u;

	f = Bytes(fmt);
	left = zero = sign = space = width = 0;
	for(i = 1; f[i] == '-' || f[i] == '0' || f[i] == '+' || f[i] == ' '; i++)
		switch(f[i]){
		case '-': left = 1; break;
		case '0': zero = 1; break;
		case '+': sign = 1; break;
		case ' ': space = 1; break;
		}
	while(f[i] >= '0' && f[i] <= '9')
		width = width * 10 + f[i++] - '0';
	while(f[i] == 'l' || f[i] == 'n' || f[i] == 'L')
		i++;
	n = Int_val(arg);
	b = 10; upper = 0; neg = 0;
	switch(f[i]){
	case 'x': b = 16; break;
	case 'X': b = 16; upper = 1; break;
	case 'o': b = 8; break;
	}
	if((f[i] == 'd' || f[i] == 'i') && n < 0){
		neg = 1;
		u = -(uvalue)n;
	}else if(b != 10 || f[i] == 'u')
		u = (uvalue)n & (((uvalue)1 << (8 * W - 1)) - 1);   /* 31 or 63 bits, as ocaml-light's */
	else
		u = n;
	start = digits(u, b, upper, buf, 64);
	if(neg)
		buf[--start] = '-';
	else if(sign)
		buf[--start] = '+';
	else if(space)
		buf[--start] = ' ';
	len = 64 - start;
	pad = width > len ? width - len : 0;
	k = 0;
	if(pad > 0 && !left && !zero)
		for(; k < pad; k++) buf[k] = ' ';
	if(pad > 0 && zero && !left){
		/* the sign first, then the zeros */
		if(neg || sign || space){
			buf[k++] = buf[start++];
			len--;
		}
		for(i = 0; i < pad; i++) buf[k++] = '0';
	}
	memmove(buf + k, buf + start, len);
	k += len;
	if(pad > 0 && left)
		for(i = 0; i < pad; i++) buf[k++] = ' ';
	buf[k] = 0;
	return ml_string(buf);
}

value
int_of_string(value s)
{
	uchar *p;
	value n, neg, b, d, len, i;

	p = Bytes(s);
	len = length(s);
	i = 0; neg = 0; n = 0; b = 10;
	if(i < len && p[i] == '-'){ neg = 1; i++; }
	if(i + 1 < len && p[i] == '0'){
		switch(p[i + 1]){
		case 'x': case 'X': b = 16; i += 2; break;
		case 'o': case 'O': b = 8; i += 2; break;
		case 'b': case 'B': b = 2; i += 2; break;
		}
	}
	if(i == len)
		goto bad;
	for(; i < len; i++){
		if(p[i] == '_')
			continue;
		if(p[i] >= '0' && p[i] <= '9') d = p[i] - '0';
		else if(p[i] >= 'a' && p[i] <= 'f') d = p[i] - 'a' + 10;
		else if(p[i] >= 'A' && p[i] <= 'F') d = p[i] - 'A' + 10;
		else goto bad;
		if(d >= b)
			goto bad;
		n = n * b + d;
	}
	return Val_int(neg ? -n : n);
bad:
	failwith("int_of_string");
	return Val_unit;
}

/*****************************************************************************/
/* Exceptions: the predefined, raising from C, the uncaught one */
/*****************************************************************************/

/* an exception is a block with its name, a static one; its value a
 * block [the exception; its arguments] */
value caml_exn_Match_failure[2];
value caml_exn_Assert_failure[2];
value caml_exn_Out_of_memory[2];
value caml_exn_Stack_overflow[2];
value caml_exn_Invalid_argument[2];
value caml_exn_Failure[2];
value caml_exn_Not_found[2];
value caml_exn_Sys_error[2];
value caml_exn_End_of_file[2];
value caml_exn_Division_by_zero[2];
value caml_atom0[1];            /* the empty array's header */

static value names[10][4];

static void
exception(value *e, value *name, char *s)
{
	value n;

	n = strlen(s);
	name[0] = (((n / W) + 1) << 10) | String_tag;
	memmove(name + 1, s, n);
	Bytes(name + 1)[((n / W) + 1) * W - 1] = ((n / W) + 1) * W - 1 - n;
	e[0] = (1 << 10) | 0;
	e[1] = (value)(name + 1);
}

static void
init_exceptions(void)
{
	exception(caml_exn_Match_failure, names[0], "Match_failure");
	exception(caml_exn_Assert_failure, names[1], "Assert_failure");
	exception(caml_exn_Out_of_memory, names[2], "Out_of_memory");
	exception(caml_exn_Stack_overflow, names[3], "Stack_overflow");
	exception(caml_exn_Invalid_argument, names[4], "Invalid_argument");
	exception(caml_exn_Failure, names[5], "Failure");
	exception(caml_exn_Not_found, names[6], "Not_found");
	exception(caml_exn_Sys_error, names[7], "Sys_error");
	exception(caml_exn_End_of_file, names[8], "End_of_file");
	exception(caml_exn_Division_by_zero, names[9], "Division_by_zero");
}

/* raise e(msg) from C */
static void
raise_with(value *e, char *msg)
{
	value s, x;

	s = ml_string(msg);
	push(s);
	x = ml_alloc(2, 0);
	s = pop();
	Field(x, 0) = (value)(e + 1);
	Field(x, 1) = s;
	ml_raise(x);
}

/* raise a constant exception from C */
static void
raise_const(value *e)
{
	value x;

	x = ml_alloc(1, 0);
	Field(x, 0) = (value)(e + 1);
	ml_raise(x);
}

void
failwith(char *msg)
{
	raise_with(caml_exn_Failure, msg);
}

static char ebuf[256];
static int elen;

static void
eadd(char *s, int n)
{
	int i;

	for(i = 0; i < n && elen < 255; i++)
		ebuf[elen++] = s[i];
}

/* as ocaml-light's printexc.c: its name, then its integer and string
 * arguments (a single tuple's fields, as Match_failure's); stdout isn't
 * flushed */
value
ml_uncaught(value exn)
{
	char buf[64];
	value b, v, i, start, name;
	int s;

	name = Field(Field(exn, 0), 0);
	eadd((char*)Bytes(name), length(name));
	if(Wosize(exn) >= 2){
		b = exn;
		start = 1;
		v = Field(exn, 1);
		if(Wosize(exn) == 2 && !Is_int(v) && Tag(v) == 0){
			b = v;
			start = 0;
		}
		eadd("(", 1);
		for(i = start; i < Wosize(b); i++){
			if(i > start)
				eadd(", ", 2);
			v = Field(b, i);
			if(Is_int(v)){
				if(Int_val(v) < 0){
					s = digits(-(uvalue)Int_val(v), 10, 0, buf, 64);
					buf[--s] = '-';
				}else
					s = digits(Int_val(v), 10, 0, buf, 64);
				eadd(buf + s, 64 - s);
			}else if(Tag(v) == String_tag){
				eadd("\"", 1);
				eadd((char*)Bytes(v), length(v));
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
	return Val_unit;
}

/*****************************************************************************/
/* compare and hash */
/*****************************************************************************/

/* OCaml's compare: integers before blocks, then the tags, strings by
 * their bytes, the other blocks by their sizes then their fields */
static value
cmp(value a, value b)
{
	value ta, tb, n, m, i, c;

	if(a == b)
		return 0;
	if(Is_int(a)){
		if(Is_int(b))
			return a < b ? -1 : 1;
		return -1;
	}
	if(Is_int(b))
		return 1;
	ta = Tag(a);
	tb = Tag(b);
	if(ta != tb)
		return ta < tb ? -1 : 1;
	if(ta == String_tag){
		n = length(a);
		m = length(b);
		for(i = 0; i < n && i < m; i++)
			if(Bytes(a)[i] != Bytes(b)[i])
				return Bytes(a)[i] < Bytes(b)[i] ? -1 : 1;
		return n < m ? -1 : n > m ? 1 : 0;
	}
	if(ta == Double_tag){
		if(Double_val(a) < Double_val(b)) return -1;
		if(Double_val(a) > Double_val(b)) return 1;
		return 0;
	}
	if(ta == Closure_tag)
		raise_with(caml_exn_Invalid_argument, "equal: functional value");
	n = Wosize(a);
	m = Wosize(b);
	if(n != m)
		return n < m ? -1 : 1;
	for(i = 0; i < n; i++){
		c = cmp(Field(a, i), Field(b, i));
		if(c != 0)
			return c;
	}
	return 0;
}

value
compare(value a, value b)
{
	return Val_int(cmp(a, b));
}

/* Hashtbl.hash: a bounded walk, breadth first, as ocaml-light's hash.c
 * (count meaningful values, limit visited at most) */
static uvalue hash_acc;
static value hash_count, hash_limit;

#define Alpha 65599
#define Beta 19

static void
hash_rec(value v)
{
	value i;

	hash_limit--;
	if(hash_count < 0 || hash_limit < 0)
		return;
	if(Is_int(v)){
		hash_count--;
		hash_acc = hash_acc * Alpha + Int_val(v);
		return;
	}
	switch(Tag(v)){
	case String_tag:
		hash_count--;
		for(i = length(v) - 1; i >= 0; i--)
			hash_acc = hash_acc * Alpha + Bytes(v)[i];
		break;
	case Double_tag:
		hash_count--;
		for(i = W - 1; i >= 0; i--)
			hash_acc = hash_acc * Alpha + Bytes(v)[i];
		break;
	case Closure_tag:
		hash_count--;
		break;
	default:
		hash_count--;
		hash_acc = hash_acc * Beta + Tag(v);
		for(i = Wosize(v) - 1; i >= 0; i--)
			hash_rec(Field(v, i));
		break;
	}
}

value
hash_univ_param(value count, value limit, value obj)
{
	hash_acc = 0;
	hash_count = Int_val(count);
	hash_limit = Int_val(limit);
	hash_rec(obj);
	return Val_int(hash_acc & (((uvalue)1 << (8 * W - 2)) - 1));
}

/*****************************************************************************/
/* Arrays, Obj, Callback */
/*****************************************************************************/

value
make_vect(value n, value init)
{
	value a, i;

	n = Int_val(n);
	if(n < 0)
		raise_with(caml_exn_Invalid_argument, "Array.make");
	if(n == 0)
		return (value)(caml_atom0 + 1);
	push(init);
	a = ml_alloc(n, 0);
	init = pop();
	for(i = 0; i < n; i++)
		Field(a, i) = init;
	return a;
}

value
obj_tag(value v)
{
	return Is_int(v) ? Val_int(1000) : Val_int(Tag(v));
}

value
obj_is_block(value v)
{
	return Val_bool(!Is_int(v));
}

value
obj_block(value tag, value n)
{
	value b, i;

	b = ml_alloc(Int_val(n), Int_val(tag));
	for(i = 0; i < Int_val(n); i++)
		Field(b, i) = Val_unit;
	return b;
}


value
register_named_value(value name, value v)
{
	if(nnamed == NAMED)
		fatal("mini-ml: too many named values\n");
	named_names[nnamed] = name;
	named_values[nnamed] = v;
	nnamed++;
	return Val_unit;
}

/*****************************************************************************/
/* Channels: ocaml-light's io.c, a buffer written when full */
/*****************************************************************************/

typedef struct Chan Chan;
struct Chan {
	int fd;
	int len;                /* output: the bytes buffered; input: those left, */
	int pos;                /* from pos */
	vlong offset;
	uchar buf[4096];
};

value
caml_open_descriptor(value fd)
{
	Chan *c;

	c = malloc(sizeof(Chan));
	c->fd = Int_val(fd);
	c->len = 0;
	c->pos = 0;
	c->offset = 0;
	return (value)c;
}

static void
flush_chan(Chan *c)
{
	if(c->len > 0)
		write(c->fd, c->buf, c->len);
	c->offset += c->len;
	c->len = 0;
}

value
caml_flush(value ch)
{
	flush_chan((Chan*)ch);
	return Val_unit;
}

static void
putc_chan(Chan *c, int b)
{
	if(c->len == 4096)
		flush_chan(c);
	c->buf[c->len++] = b;
}

value
caml_output_char(value ch, value b)
{
	putc_chan((Chan*)ch, Int_val(b));
	return Val_unit;
}

value
caml_output(value ch, value s, value ofs, value len)
{
	value i;

	for(i = 0; i < Int_val(len); i++)
		putc_chan((Chan*)ch, Bytes(s)[Int_val(ofs) + i]);
	return Val_unit;
}

value
caml_output_int(value ch, value n)
{
	Chan *c;

	c = (Chan*)ch;
	n = Int_val(n);
	putc_chan(c, n >> 24);
	putc_chan(c, n >> 16);
	putc_chan(c, n >> 8);
	putc_chan(c, n);
	return Val_unit;
}

/* the next byte, or -1 at the end */
static int
getc_chan(Chan *c)
{
	long n;

	if(c->len == 0){
		n = read(c->fd, c->buf, 4096);
		if(n <= 0)
			return -1;
		c->offset += n;
		c->len = n;
		c->pos = 0;
	}
	c->len--;
	return c->buf[c->pos++];
}

value
caml_input_char(value ch)
{
	int b;

	b = getc_chan((Chan*)ch);
	if(b < 0)
		raise_const(caml_exn_End_of_file);
	return Val_int(b);
}

value
caml_input(value ch, value s, value ofs, value len)
{
	Chan *c;
	value n;
	int b;

	c = (Chan*)ch;
	n = 0;
	while(n < Int_val(len) && (n == 0 || c->len > 0)){
		b = getc_chan(c);
		if(b < 0)
			break;
		Bytes(s)[Int_val(ofs) + n] = b;
		n++;
	}
	return Val_int(n);
}

/* how far to the next newline (included), negated if the buffer ends
 * first: ocaml-light's input_scan_line, which input_line loops on */
value
caml_input_scan_line(value ch)
{
	Chan *c;
	int i;
	long n;

	c = (Chan*)ch;
	if(c->len == 0){
		n = read(c->fd, c->buf, 4096);
		if(n <= 0)
			return Val_int(0);
		c->offset += n;
		c->len = n;
		c->pos = 0;
	}
	for(i = 0; i < c->len; i++)
		if(c->buf[c->pos + i] == '\n')
			return Val_int(i + 1);
	return Val_int(-c->len);
}

value
caml_close_channel(value ch)
{
	Chan *c;

	c = (Chan*)ch;
	flush_chan(c);
	close(c->fd);
	return Val_unit;
}

value
caml_pos_out(value ch)
{
	return Val_int(((Chan*)ch)->offset + ((Chan*)ch)->len);
}

value
caml_pos_in(value ch)
{
	return Val_int(((Chan*)ch)->offset - ((Chan*)ch)->len);
}

/*****************************************************************************/
/* Sys */
/*****************************************************************************/

static int argc;
static char **argv;

value
sys_exit(value n)
{
	exit(Int_val(n));
	return Val_unit;
}

value
sys_get_argv(value unit)
{
	value a, s;
	int i;

	a = make_vect(Val_int(argc), Val_unit);
	for(i = 0; i < argc; i++){
		push(a);
		s = ml_string(argv[i]);
		a = pop();
		Field(a, i) = s;
	}
	return a;
}

value
sys_get_config(value unit)
{
	value r, s;

	s = ml_string("Plan9");
	push(s);
	r = ml_alloc(2, 0);
	s = pop();
	Field(r, 0) = s;
	Field(r, 1) = Val_int(8 * W);
	return r;
}

value
sys_getenv(value name)
{
	char *v;

	v = getenv((char*)Bytes(name));
	if(v == nil)
		raise_const(caml_exn_Not_found);
	return ml_string(v);
}

value
sys_open(value name, value flags, value perm)
{
	int fd;

	fd = open((char*)Bytes(name), 1);
	if(fd < 0)
		fd = create((char*)Bytes(name), 1, Int_val(perm));
	if(fd < 0)
		raise_with(caml_exn_Sys_error, (char*)Bytes(name));
	return Val_int(fd);
}

value
install_signal_handler(value sig, value action)
{
	return Val_int(0);
}

/*****************************************************************************/
/* Floats: boxed, a block of the double's bits (phase 7; on arm64: on
 * arm, mini-ld encodes 5c's FPA, not the Pi's VFP) */
/*****************************************************************************/

/* what goken's libc lacks, from what it has (not glibc's to the last
 * bit) */
static double ml_tan(double x) { return sin(x) / cos(x); }
static double ml_sinh(double x) { return (exp(x) - exp(-x)) / 2; }
static double ml_cosh(double x) { return (exp(x) + exp(-x)) / 2; }
static double ml_tanh(double x) { return ml_sinh(x) / ml_cosh(x); }
static double ml_fmod(double a, double b) { double i; modf(a / b, &i); return a - i * b; }

static value
copy_double(double d)
{
	value b;

	b = ml_alloc(sizeof(double) / W, Double_tag);
	*(double*)b = d;
	return b;
}

value caml_negfloat(value a) { return copy_double(-Double_val(a)); }
value caml_absfloat(value a) { return copy_double(Double_val(a) < 0 ? -Double_val(a) : Double_val(a)); }
value caml_floatofint(value n) { return copy_double((double)Int_val(n)); }
value caml_intoffloat(value a) { return Val_int((value)Double_val(a)); }
value caml_addfloat(value a, value b) { return copy_double(Double_val(a) + Double_val(b)); }
value caml_subfloat(value a, value b) { return copy_double(Double_val(a) - Double_val(b)); }
value caml_mulfloat(value a, value b) { return copy_double(Double_val(a) * Double_val(b)); }
value caml_divfloat(value a, value b) { return copy_double(Double_val(a) / Double_val(b)); }
value exp_float(value a) { return copy_double(exp(Double_val(a))); }
value log_float(value a) { return copy_double(log(Double_val(a))); }
value log10_float(value a) { return copy_double(log10(Double_val(a))); }
value sqrt_float(value a) { return copy_double(sqrt(Double_val(a))); }
value sin_float(value a) { return copy_double(sin(Double_val(a))); }
value cos_float(value a) { return copy_double(cos(Double_val(a))); }
value tan_float(value a) { return copy_double(ml_tan(Double_val(a))); }
value asin_float(value a) { return copy_double(asin(Double_val(a))); }
value acos_float(value a) { return copy_double(acos(Double_val(a))); }
value atan_float(value a) { return copy_double(atan(Double_val(a))); }
value sinh_float(value a) { return copy_double(ml_sinh(Double_val(a))); }
value cosh_float(value a) { return copy_double(ml_cosh(Double_val(a))); }
value tanh_float(value a) { return copy_double(ml_tanh(Double_val(a))); }
value ceil_float(value a) { return copy_double(ceil(Double_val(a))); }
value floor_float(value a) { return copy_double(floor(Double_val(a))); }
value atan2_float(value a, value b) { return copy_double(atan2(Double_val(a), Double_val(b))); }
value power_float(value a, value b) { return copy_double(pow(Double_val(a), Double_val(b))); }
value fmod_float(value a, value b) { return copy_double(ml_fmod(Double_val(a), Double_val(b))); }
value ldexp_float(value a, value n) { return copy_double(ldexp(Double_val(a), Int_val(n))); }

/* a pair of the result's parts: frexp's and modf's */
static value
pair(value a, value b)
{
	value r;

	push(a);
	push(b);
	r = ml_alloc(2, 0);
	Field(r, 1) = pop();
	Field(r, 0) = pop();
	return r;
}

value
frexp_float(value a)
{
	int e;
	double m;

	m = frexp(Double_val(a), &e);
	return pair(copy_double(m), Val_int(e));
}

value
modf_float(value a)
{
	double i, f;
	value fv;

	f = modf(Double_val(a), &i);
	fv = copy_double(f);
	push(fv);
	fv = copy_double(i);
	return pair(pop(), fv);
}

/* printf's floats, by libc's formatter: OCaml's format is C's */
value
format_float(value fmt, value a)
{
	char buf[128];

	snprint(buf, sizeof buf, (char*)Bytes(fmt), Double_val(a));
	return ml_string(buf);
}

value
float_of_string(value s)
{
	char *end;
	double d;

	d = strtod((char*)Bytes(s), &end);
	if(end != (char*)Bytes(s) + length(s) || length(s) == 0)
		failwith("float_of_string");
	return copy_double(d);
}

/*****************************************************************************/
/* Not yet: marshalling, and the others below */
/*****************************************************************************/

value sys_time(value u) { unsupported("Sys.time"); return u; }
value output_value(value c, value v) { unsupported("output_value"); return v; }
value input_value(value c) { unsupported("input_value"); return c; }

/* the stdlib's other externals, which a unit's closure of its externals
 * names (Lower's Iexternal): each fails when called. The list is the
 * stdlib's non-% primitives this file doesn't define (Int32, Int64, the
 * floats' functions, Gc, Weak, Digest, Lexing's and Parsing's engines,
 * marshalling, and some of Sys) */
value caml_channel_size(void) { unsupported("caml_channel_size"); return 0; }
value caml_get_exception_backtrace(void) { unsupported("caml_get_exception_backtrace"); return 0; }
value caml_input_int(void) { unsupported("caml_input_int"); return 0; }
value caml_seek_in(void) { unsupported("caml_seek_in"); return 0; }
value caml_seek_out(void) { unsupported("caml_seek_out"); return 0; }
value gc_get(void) { unsupported("gc_get"); return 0; }
value gc_set(void) { unsupported("gc_set"); return 0; }
value gc_stat(void) { unsupported("gc_stat"); return 0; }
value input_value_from_string(void) { unsupported("input_value_from_string"); return 0; }
value int32_add(void) { unsupported("int32_add"); return 0; }
value int32_and(void) { unsupported("int32_and"); return 0; }
value int32_div(void) { unsupported("int32_div"); return 0; }
value int32_format(void) { unsupported("int32_format"); return 0; }
value int32_mod(void) { unsupported("int32_mod"); return 0; }
value int32_mul(void) { unsupported("int32_mul"); return 0; }
value int32_neg(void) { unsupported("int32_neg"); return 0; }
value int32_of_int(void) { unsupported("int32_of_int"); return 0; }
value int32_of_string(void) { unsupported("int32_of_string"); return 0; }
value int32_or(void) { unsupported("int32_or"); return 0; }
value int32_shift_left(void) { unsupported("int32_shift_left"); return 0; }
value int32_shift_right(void) { unsupported("int32_shift_right"); return 0; }
value int32_shift_right_unsigned(void) { unsupported("int32_shift_right_unsigned"); return 0; }
value int32_sub(void) { unsupported("int32_sub"); return 0; }
value int32_to_int(void) { unsupported("int32_to_int"); return 0; }
value int32_xor(void) { unsupported("int32_xor"); return 0; }
value int64_add(void) { unsupported("int64_add"); return 0; }
value int64_and(void) { unsupported("int64_and"); return 0; }
value int64_div(void) { unsupported("int64_div"); return 0; }
value int64_format(void) { unsupported("int64_format"); return 0; }
value int64_mod(void) { unsupported("int64_mod"); return 0; }
value int64_mul(void) { unsupported("int64_mul"); return 0; }
value int64_neg(void) { unsupported("int64_neg"); return 0; }
value int64_of_int(void) { unsupported("int64_of_int"); return 0; }
value int64_of_int32(void) { unsupported("int64_of_int32"); return 0; }
value int64_of_string(void) { unsupported("int64_of_string"); return 0; }
value int64_or(void) { unsupported("int64_or"); return 0; }
value int64_shift_left(void) { unsupported("int64_shift_left"); return 0; }
value int64_shift_right(void) { unsupported("int64_shift_right"); return 0; }
value int64_shift_right_unsigned(void) { unsupported("int64_shift_right_unsigned"); return 0; }
value int64_sub(void) { unsupported("int64_sub"); return 0; }
value int64_to_int(void) { unsupported("int64_to_int"); return 0; }
value int64_to_int32(void) { unsupported("int64_to_int32"); return 0; }
value int64_xor(void) { unsupported("int64_xor"); return 0; }
value lex_engine(void) { unsupported("lex_engine"); return 0; }
value marshal_data_size(void) { unsupported("marshal_data_size"); return 0; }
value md5_chan(void) { unsupported("md5_chan"); return 0; }
value md5_string(void) { unsupported("md5_string"); return 0; }
value output_value_to_buffer(void) { unsupported("output_value_to_buffer"); return 0; }
value output_value_to_string(void) { unsupported("output_value_to_string"); return 0; }
value parse_engine(void) { unsupported("parse_engine"); return 0; }
value sys_chdir(void) { unsupported("sys_chdir"); return 0; }
value sys_close(void) { unsupported("sys_close"); return 0; }
value sys_file_exists(void) { unsupported("sys_file_exists"); return 0; }
value sys_getcwd(void) { unsupported("sys_getcwd"); return 0; }
value sys_is_directory(void) { unsupported("sys_is_directory"); return 0; }
value sys_remove(void) { unsupported("sys_remove"); return 0; }
value sys_rename(void) { unsupported("sys_rename"); return 0; }
value sys_system_command(void) { unsupported("sys_system_command"); return 0; }
value weak_create(void) { unsupported("weak_create"); return 0; }
value weak_get(void) { unsupported("weak_get"); return 0; }
value weak_set(void) { unsupported("weak_set"); return 0; }

/*****************************************************************************/
/* main */
/*****************************************************************************/

void
main(int ac, char *av[])
{
	char *s;

	argc = ac;
	argv = av;
	init_exceptions();
	caml_atom0[0] = 0;
	size = 1 << 18;
	s = getenv("ML_HEAP");
	if(s != nil)
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
	exit(0);
}
