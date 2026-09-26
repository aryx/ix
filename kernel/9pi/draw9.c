/* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 */
/* mini-9pi's C pixel libraries' side (plan_9pi.md, decision 4:
 * principia's libmemdraw, libmemlayer and libdraw's geometry, compiled
 * by gcc -fplan9-extensions with principia's own headers, linked into
 * the kernel as 9pi links them): what they need of a Plan 9 libc that
 * kernel/lib's C library does not have (print, werrstr, mallocz, qsort,
 * chartorune, ctype, 64-bit division, the image pool...), stubs for
 * libdraw's Display functions the kernel never calls, and a small plain
 * C interface over memdraw for the OCaml kernel (d9_*: drawglue.c makes
 * them OCaml primitives; the two apart, Plan 9's headers and OCaml's
 * do not mix). */

#include <u.h>
#include <libc.h>
#include <ctype.h>
#include <draw.h>
#include <memdraw.h>
#include <pool.h>

/*****************************************************************************/
/* A Plan 9 libc, enough for the libraries */
/*****************************************************************************/

void uart_putc_raw(int c);

void *calloc(unsigned long, unsigned long);

void *mallocz(ulong n, int clr) { return clr ? calloc(1, n) : malloc(n); }
void setmalloctag(void *v, ulong pc) { USED(v, pc); }
uintptr getcallerpc(void *x) { USED(x); return 0; }
int _tas(int *p) { int v = *p; *p = 1; return v; }
int abs(int a) { return a < 0 ? -a : a; }

int atoi(char *s)
{
  int n = 0, neg = 0;
  while (*s == ' ' || *s == '\t') s++;
  if (*s == '-') { neg = 1; s++; } else if (*s == '+') s++;
  while (*s >= '0' && *s <= '9') n = n * 10 + *s++ - '0';
  return neg ? -n : n;
}

char *strchr(char *s, int c)
{
  for (;; s++) { if (*s == c) return s; if (*s == 0) return nil; }
}

char *strncpy(char *d, char *s, long n)
{
  long i;
  for (i = 0; i < n && s[i]; i++) d[i] = s[i];
  for (; i < n; i++) d[i] = 0;
  return d;
}

char *strdup(char *s)
{
  int n = strlen(s) + 1;
  char *t = malloc(n);
  if (t) memmove(t, s, n);
  return t;
}

/* an insertion sort (the libraries sort a few edges: fillpoly) */
void qsort(void *va, long n, long es, int (*cmp)(void*, void*))
{
  char *a = va, tmp[64];
  long i, j;
  if (es > sizeof tmp) return;
  for (i = 1; i < n; i++)
    for (j = i; j > 0 && cmp(a + (j - 1) * es, a + j * es) > 0; j--) {
      memmove(tmp, a + j * es, es);
      memmove(a + j * es, a + (j - 1) * es, es);
      memmove(a + (j - 1) * es, tmp, es);
    }
}

int chartorune(Rune *r, char *s)
{
  int c = (uchar)s[0];
  if (c < 0x80) { *r = c; return 1; }
  if ((c & 0xe0) == 0xc0 && ((uchar)s[1] & 0xc0) == 0x80) { *r = ((c & 0x1f) << 6) | (s[1] & 0x3f); return 2; }
  if ((c & 0xf0) == 0xe0 && ((uchar)s[1] & 0xc0) == 0x80 && ((uchar)s[2] & 0xc0) == 0x80) {
    *r = ((c & 0x0f) << 12) | ((s[1] & 0x3f) << 6) | (s[2] & 0x3f); return 3;
  }
  *r = Runeerror;
  return 1;
}

/* the errors the libraries report: kept for no one, their text on the
 * console (print: its format only, no argument: they are rare) */
static char errbuf[ERRMAX];
void werrstr(char *fmt, ...) { strncpy(errbuf, fmt, sizeof errbuf - 1); }
/* principia's libc.h: print and _assert are function pointers */
static int p9print(char *fmt, ...) { char *p; for (p = fmt; *p; p++) uart_putc_raw(*p); return 0; }
int (*print)(char*, ...) = p9print;
int sprint(char *buf, char *fmt, ...) { strcpy(buf, fmt); return strlen(buf); }
long readn(int fd, void *a, long n) { USED(fd, a, n); return -1; }
static void p9assert(char *s) { print("assert failed: "); print(s); print("\n"); for(;;); }
void (*_assert)(char*) = p9assert;
int fmtinstall(int c, int (*f)(Fmt*)) { USED(c, f); return 0; }

uchar _ctype[256] = {
  _C, _C, _C, _C, _C, _C, _C, _C,
  _C, _S|_C, _S|_C, _S|_C, _S|_C, _S|_C, _C, _C,
  _C, _C, _C, _C, _C, _C, _C, _C,
  _C, _C, _C, _C, _C, _C, _C, _C,
  _S|_B, _P, _P, _P, _P, _P, _P, _P,
  _P, _P, _P, _P, _P, _P, _P, _P,
  _N|_X, _N|_X, _N|_X, _N|_X, _N|_X, _N|_X, _N|_X, _N|_X,
  _N|_X, _N|_X, _P, _P, _P, _P, _P, _P,
  _P, _U|_X, _U|_X, _U|_X, _U|_X, _U|_X, _U|_X, _U,
  _U, _U, _U, _U, _U, _U, _U, _U,
  _U, _U, _U, _U, _U, _U, _U, _U,
  _U, _U, _U, _P, _P, _P, _P, _P,
  _P, _L|_X, _L|_X, _L|_X, _L|_X, _L|_X, _L|_X, _L,
  _L, _L, _L, _L, _L, _L, _L, _L,
  _L, _L, _L, _L, _L, _L, _L, _L,
  _L, _L, _L, _P, _P, _P, _P, _C,
};

/* 64-bit division, as the ABI's __aeabi_ldivmod returns it (quotient
 * in r0:r1, remainder in r2:r3), by shifts and subtractions (the
 * compiler's own 64-bit division would call it again) */
static uvlong udiv64(uvlong n, uvlong d, uvlong *rem)
{
  uvlong q = 0;
  int i;
  if (d == 0) { *rem = n; return 0; }
  for (i = 63; i >= 0; i--)
    if ((n >> i) >= d) { n -= d << i; q |= 1ULL << i; }
  *rem = n;
  return q;
}

vlong __ldivmod_helper(vlong n, vlong d, vlong *rem)
{
  int neg = 0, rneg = n < 0;
  uvlong un = n < 0 ? -(uvlong)n : n, ud = d < 0 ? -(uvlong)d : d, r;
  vlong q;
  if ((n < 0) != (d < 0)) neg = 1;
  q = udiv64(un, ud, &r);
  *rem = rneg ? -(vlong)r : (vlong)r;
  return neg ? -q : q;
}

uvlong __uldivmod_helper(uvlong n, uvlong d, uvlong *rem) { return udiv64(n, d, rem); }

__asm__(
  ".global __aeabi_ldivmod\n"
  "__aeabi_ldivmod:\n"
  "  push {r4, lr}\n"
  "  sub sp, sp, #16\n"
  "  add r4, sp, #8\n"
  "  str r4, [sp]\n"
  "  bl __ldivmod_helper\n"
  "  ldr r2, [sp, #8]\n"
  "  ldr r3, [sp, #12]\n"
  "  add sp, sp, #16\n"
  "  pop {r4, pc}\n"
  ".global __aeabi_uldivmod\n"
  "__aeabi_uldivmod:\n"
  "  push {r4, lr}\n"
  "  sub sp, sp, #16\n"
  "  add r4, sp, #8\n"
  "  str r4, [sp]\n"
  "  bl __uldivmod_helper\n"
  "  ldr r2, [sp, #8]\n"
  "  ldr r3, [sp, #12]\n"
  "  add sp, sp, #16\n"
  "  pop {r4, pc}\n");

/* the image memory (imagmem, a Pool in the kernel; memimageinit sets
 * its move hook): malloc's */
static Pool imagpool = { .name = "Image" };
Pool *imagmem = &imagpool;
void *poolalloc(Pool *p, ulong n) { USED(p); return malloc(n); }
void poolfree(Pool *p, void *v) { USED(p); free(v); }

/* libdraw's Display side, referenced by defont.c and chan.c's
 * neighbours, never called by the kernel */
Image *allocimage(Display *d, Rectangle r, ulong chan, int repl, ulong col) { USED(d, r, chan, repl, col); return nil; }
int freeimage(Image *i) { USED(i); return 0; }
uchar *bufimage(Display *d, int n) { USED(d, n); return nil; }
void lockdisplay(Display *d) { USED(d); }
void unlockdisplay(Display *d) { USED(d); }
int unloadimage(Image *i, Rectangle r, uchar *data, int ndata) { USED(i, r, data, ndata); return -1; }
int fmtprint(Fmt *f, char *fmt, ...) { USED(f, fmt); return 0; }
int _ifmt(Fmt *f) { USED(f); return 0; }
/* libdraw's fmt.c's %P and %R (init.c installs them; fmtinstall is
 * nothing here) */
int Pfmt(Fmt *f) { USED(f); return 0; }
int Rfmt(Fmt *f) { USED(f); return 0; }

/*****************************************************************************/
/* The kernel's interface (d9_*) */
/*****************************************************************************/

static Memimage *screen;
static Memsubfont *d9font;

/* the screen: the framebuffer (its kernel address), w x h, RGB16 */
int d9_init(uintptr fb, int w, int h)
{
  Memdata *md = mallocz(sizeof *md, 1);
  md->bdata = (uchar*)fb;
  md->ref = 1;
  memimageinit();
  screen = allocmemimaged(Rect(0, 0, w, h), RGB16, md);
  if (screen == nil) return -1;
  d9font = getmemdefont();
  return 0;
}

void *d9_screen(void) { return screen; }
void *d9_white(void) { return memwhite; }
void *d9_black(void) { return memblack; }
void *d9_opaque(void) { return memopaque; }

/* a 1x1 replicated RGB16 colour, its two bytes (screenwin's orange) */
void *d9_color16(int b0, int b1)
{
  Memimage *m = allocmemimage(Rect(0, 0, 1, 1), RGB16);
  if (m == nil) return nil;
  m->flags |= Frepl;
  m->clipr = screen->r;
  m->data->bdata[0] = b0;
  m->data->bdata[1] = b1;
  return m;
}

void d9_free(void *m) { freememimage(m); }

/* memimagedraw(dst, r, src, sp, mask, mp, S) */
void d9_draw(void *dst, int x0, int y0, int x1, int y1, void *src, int sx, int sy, void *mask, int mx, int my)
{
  memimagedraw(dst, Rect(x0, y0, x1, y1), src, Pt(sx, sy), mask, Pt(mx, my), SoverD);
}

/* memimagestring(dst, p, src, sp, the default font, s): the point after */
int d9_string(void *dst, int x, int y, void *src, int sx, int sy, char *s)
{
  return memimagestring(dst, Pt(x, y), src, Pt(sx, sy), d9font, s).x;
}

int d9_fontheight(void) { return d9font->height; }
int d9_stringwidth(char *s) { return memsubfontwidth(d9font, s).x; }

/* an image of chan (0: the screen's), its memory zeroed */
void *d9_alloc(int x0, int y0, int x1, int y1, ulong chan)
{
  Memimage *m;

  m = allocmemimage(Rect(x0, y0, x1, y1), chan ? chan : screen->chan);
  if(m != nil)
    memfillcolor(m, DTransparent);
  return m;
}

/* its pixels' bytes (loadmemimage over its whole rectangle) */
int d9_load(void *m, uchar *data, int n)
{
  Memimage *i = m;
  return loadmemimage(i, i->r, data, n);
}
