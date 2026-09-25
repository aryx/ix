/* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 */
/* What ocaml-light's runtime asks of a C library, bare-metal on the Pi1
 * (plan_kernel.md, step 1), as ~/xix/kernel/fakes.c did for the
 * bytecode runtime: writes to stdout and stderr go to the PL011, malloc
 * takes the RAM after the kernel (a bump pointer: the runtime frees
 * little, and its heap only grows), sprintf formats the integers
 * (string_of_int, Printf), and the rest -- files, signals, the maths,
 * reading floats -- panics, naming itself: nothing mini-xv6 runs calls
 * it yet. The list is what the linker reported undefined. */

#include <stdarg.h>
#include <stddef.h>

void kmain(void);
void caml_main(char **argv);

/*****************************************************************************/
/* The console: the PL011 */
/*****************************************************************************/

#define UART_DR ((volatile unsigned int *)0x20201000)
#define UART_FR ((volatile unsigned int *)0x20201018)

static void putc_(char c)
{
  while (*UART_FR & 0x20)          /* the transmit FIFO full */
    ;
  *UART_DR = (unsigned char)c;
}

static void puts_(const char *s) { while (*s) putc_(*s++); }

void exit(int status);

static void panic(const char *what)
{
  puts_("mini-xv6: panic: ");
  puts_(what);
  puts_("\n");
  exit(2);
}

void exit(int status)
{
  (void)status;
  for (;;)
    __asm__ volatile("mcr p15, 0, %0, c7, c0, 4" : : "r"(0));      /* wait for an interrupt: none comes */
}

void abort(void) { panic("abort"); }

/*****************************************************************************/
/* Memory */
/*****************************************************************************/

extern char end[];
static char *brk_ = end;
#define HEAP_LIMIT ((char *)0x10000000)  /* 256MB of the Pi1's 512 */

/* a block: its size in the word before it (realloc needs it) */
void *malloc(size_t n)
{
  char *p = (char *)(((size_t)brk_ + 7) & ~(size_t)7) + 8;
  if (p + n > HEAP_LIMIT) return NULL;
  ((size_t *)p)[-1] = n;
  brk_ = p + n;
  return p;
}

void free(void *p) { (void)p; }

void *memcpy(void *d, const void *s, size_t n)
{
  char *dd = d; const char *ss = s;
  while (n--) *dd++ = *ss++;
  return d;
}

void *memmove(void *d, const void *s, size_t n)
{
  char *dd = d; const char *ss = s;
  if (dd < ss) while (n--) *dd++ = *ss++;
  else { dd += n; ss += n; while (n--) *--dd = *--ss; }
  return d;
}

void *memset(void *d, int c, size_t n)
{
  char *dd = d;
  while (n--) *dd++ = (char)c;
  return d;
}

void bcopy(const void *s, void *d, size_t n) { memmove(d, s, n); }

int memcmp(const void *a, const void *b, size_t n)
{
  const unsigned char *x = a, *y = b;
  for (; n; n--, x++, y++) if (*x != *y) return *x - *y;
  return 0;
}

void *realloc(void *p, size_t n)
{
  void *q = malloc(n);
  if (p && q) { size_t old = ((size_t *)p)[-1]; memcpy(q, p, old < n ? old : n); }
  return q;
}

void *calloc(size_t k, size_t n) { void *p = malloc(k * n); if (p) memset(p, 0, k * n); return p; }

size_t strlen(const char *s) { size_t n = 0; while (s[n]) n++; return n; }
int strcmp(const char *a, const char *b) { while (*a && *a == *b) a++, b++; return (unsigned char)*a - (unsigned char)*b; }
char *strcpy(char *d, const char *s) { char *r = d; while ((*d++ = *s++)) ; return r; }

long strtol(const char *s, char **endp, int base)
{
  long v = 0; int neg = 0;
  while (*s == ' ') s++;
  if (*s == '-' || *s == '+') neg = *s++ == '-';
  if (base == 0) base = (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) ? (s += 2, 16) : 10;
  for (;; s++) {
    int d = *s >= '0' && *s <= '9' ? *s - '0' : *s >= 'a' && *s <= 'z' ? *s - 'a' + 10 : *s >= 'A' && *s <= 'Z' ? *s - 'A' + 10 : 99;
    if (d >= base) break;
    v = v * base + d;
  }
  if (endp) *endp = (char *)s;
  return neg ? -v : v;
}

/*****************************************************************************/
/* Division: the Pi1's ARMv6 has no divide instruction, and the
 * compilers call these (ARM's run-time ABI). Not libgcc's: the armhf
 * one is Thumb-2, for ARMv7, and an ARMv6 cannot run it (the runtime's
 * first division jumped into Thumb and took an undefined instruction).
 * A quotient and remainder come back in r0 and r1: a 64-bit result's
 * two halves. */
/*****************************************************************************/

static unsigned long long udivmod(unsigned n, unsigned d)
{
  unsigned q = 0, r = 0;
  int i;
  if (d == 0) panic("division by zero");
  for (i = 31; i >= 0; i--) {
    r = (r << 1) | ((n >> i) & 1);
    if (r >= d) { r -= d; q |= 1u << i; }
  }
  return ((unsigned long long)r << 32) | q;
}

unsigned __aeabi_uidiv(unsigned n, unsigned d) { return (unsigned)udivmod(n, d); }
unsigned long long __aeabi_uidivmod(unsigned n, unsigned d) { return udivmod(n, d); }

/* signed: the quotient toward zero, the remainder of the dividend's sign */
unsigned long long __aeabi_idivmod(int n, int d)
{
  unsigned long long qr = udivmod(n < 0 ? -(unsigned)n : (unsigned)n, d < 0 ? -(unsigned)d : (unsigned)d);
  unsigned q = (unsigned)qr, r = (unsigned)(qr >> 32);
  if ((n < 0) != (d < 0)) q = -q;
  if (n < 0) r = -r;
  return ((unsigned long long)r << 32) | q;
}

int __aeabi_idiv(int n, int d) { return (int)(unsigned)__aeabi_idivmod(n, d); }

/* the older names, which ocaml-light's arm backend calls for / and mod */
int __divsi3(int n, int d) { return __aeabi_idiv(n, d); }
int __modsi3(int n, int d) { return (int)(__aeabi_idivmod(n, d) >> 32); }

/*****************************************************************************/
/* Formatting: the integers, as the runtime's formats ask (flags, width,
 * precision, l); no floats */
/*****************************************************************************/

static int format(char *out, const char *fmt, va_list ap)
{
  char *o = out;
  for (; *fmt; fmt++) {
    if (*fmt != '%') { *o++ = *fmt; continue; }
    int left = 0, zero = 0, plus = 0, space = 0, alt = 0, width = 0, prec = -1;
    for (fmt++;; fmt++) {
      if (*fmt == '-') left = 1; else if (*fmt == '0') zero = 1; else if (*fmt == '+') plus = 1;
      else if (*fmt == ' ') space = 1; else if (*fmt == '#') alt = 1; else break;
    }
    if (*fmt == '*') { width = va_arg(ap, int); fmt++; } else while (*fmt >= '0' && *fmt <= '9') width = width * 10 + *fmt++ - '0';
    if (*fmt == '.') { prec = 0; fmt++; if (*fmt == '*') { prec = va_arg(ap, int); fmt++; } else while (*fmt >= '0' && *fmt <= '9') prec = prec * 10 + *fmt++ - '0'; }
    while (*fmt == 'l' || *fmt == 'h' || *fmt == 'z') fmt++;
    char buf[40], *b = buf + sizeof buf, sign = 0;
    const char *str = NULL; int len;
    switch (*fmt) {
    case 'd': case 'i': case 'u': case 'x': case 'X': case 'o': case 'p': {
      unsigned long u; int base = *fmt == 'o' ? 8 : (*fmt == 'x' || *fmt == 'X' || *fmt == 'p') ? 16 : 10;
      if (*fmt == 'd' || *fmt == 'i') { long v = va_arg(ap, long); if (v < 0) { sign = '-'; u = -(unsigned long)v; } else { u = v; if (plus) sign = '+'; else if (space) sign = ' '; } }
      else if (*fmt == 'p') { u = (unsigned long)va_arg(ap, void *); alt = 1; }
      else u = va_arg(ap, unsigned long);
      const char *digits = *fmt == 'X' ? "0123456789ABCDEF" : "0123456789abcdef";
      do { *--b = digits[u % base]; u /= base; } while (u);
      while (buf + sizeof buf - b < prec) *--b = '0';
      if (alt && base == 16) { *--b = *fmt == 'X' ? 'X' : 'x'; *--b = '0'; }
      if (alt && base == 8 && *b != '0') *--b = '0';
      str = b; len = buf + sizeof buf - b;
      break;
    }
    case 'c': buf[0] = (char)va_arg(ap, int); str = buf; len = 1; break;
    case 's': str = va_arg(ap, const char *); if (!str) str = "(null)"; len = strlen(str); if (prec >= 0 && prec < len) len = prec; break;
    case '%': str = "%"; len = 1; break;
    default: panic("printf: a float or an unknown conversion");
    }
    int pad = width - len - (sign ? 1 : 0);
    if (!left && !(zero && prec < 0)) while (pad-- > 0) *o++ = ' ';
    if (sign) *o++ = sign;
    if (!left && zero && prec < 0) while (pad-- > 0) *o++ = '0';
    while (len--) *o++ = *str++;
    if (left) while (pad-- > 0) *o++ = ' ';
  }
  *o = 0;
  return o - out;
}

int sprintf(char *out, const char *fmt, ...)
{
  va_list ap; va_start(ap, fmt);
  int n = format(out, fmt, ap);
  va_end(ap);
  return n;
}

/* the runtime's fatal errors and GC messages: to the console */
typedef struct { int fd; } FILE;
static FILE stderr_ = { 2 };
FILE *stderr = &stderr_;

int fprintf(FILE *f, const char *fmt, ...)
{
  char buf[512];
  va_list ap; va_start(ap, fmt);
  int n = format(buf, fmt, ap);
  va_end(ap);
  (void)f;
  puts_(buf);
  return n;
}

int fflush(FILE *f) { (void)f; return 0; }

/*****************************************************************************/
/* The system: stdout and stderr, and nothing else */
/*****************************************************************************/

int errno_;
int *__errno_location(void) { return &errno_; }

int write(int fd, const void *p, size_t n)
{
  const char *s = p;
  if (fd != 1 && fd != 2) panic("write: not stdout or stderr");
  for (size_t i = 0; i < n; i++) putc_(s[i]);
  return n;
}

char *getenv(const char *name) { (void)name; return NULL; }
int sigemptyset(void *set) { (void)set; return 0; }
int sigaction(int s, const void *a, void *o) { (void)s; (void)a; (void)o; return 0; }
int sigprocmask(int h, const void *s, void *o) { (void)h; (void)s; (void)o; return 0; }
long times(void *t) { (void)t; return 0; }
char *strerror(int e) { (void)e; return "error"; }

#define STUB(name) void name(void) { panic(#name); }
STUB(read) STUB(open64) STUB(close) STUB(lseek64) STUB(unlink) STUB(rename) STUB(chdir) STUB(getcwd)
STUB(system) STUB(__stat64_time64) STUB(__isoc99_sscanf) STUB(strtod)
STUB(acos) STUB(asin) STUB(atan) STUB(atan2) STUB(ceil) STUB(cos) STUB(cosh) STUB(exp) STUB(fabs)
STUB(floor) STUB(fmod) STUB(frexp) STUB(ldexp) STUB(log) STUB(log10) STUB(modf) STUB(pow) STUB(sin)
STUB(sinh) STUB(sqrt) STUB(tan) STUB(tanh)

/*****************************************************************************/
/* The start */
/*****************************************************************************/

void kmain(void)
{
  static char *argv[] = { "mini-xv6", NULL };
  caml_main(argv);
  exit(0);
}
