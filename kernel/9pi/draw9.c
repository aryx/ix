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
#include <memlayer.h>
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

/*****************************************************************************/
/* The draw device's (#i: Devdraw.ml parses the messages, these do their
 * calls; a's ints as the message has them, a 32-bit chan or colour as
 * its two 16-bit halves: an OCaml int is 31 bits) */
/*****************************************************************************/

#define R(a) Rect((a)[0], (a)[1], (a)[2], (a)[3])
#define P(a) Pt((a)[0], (a)[1])
#define U32(a) ((ulong)(a)[0] << 16 | (ulong)(a)[1] & 0xFFFF)

/* hwdraw (9pi's screen.c's): a drawing on the screen's memory first
 * hides the cursor where it goes (Swcursor.avoid, drawglue.c's) */
void (*d9_avoid)(int x0, int y0, int x1, int y1);

int hwdraw(Memdrawparam *par)
{
  Memimage *dst, *src, *mask;

  if((dst = par->dst) == nil || dst->data == nil)
    return 0;
  if((src = par->src) == nil || src->data == nil)
    return 0;
  if((mask = par->mask) == nil || mask->data == nil)
    return 0;
  if(d9_avoid == nil || screen == nil)
    return 0;
  if(dst->data->bdata == screen->data->bdata)
    d9_avoid(par->r.min.x, par->r.min.y, par->r.max.x, par->r.max.y);
  if(src->data->bdata == screen->data->bdata)
    d9_avoid(par->sr.min.x, par->sr.min.y, par->sr.max.x, par->sr.max.y);
  if(mask->data->bdata == screen->data->bdata)
    d9_avoid(par->mr.min.x, par->mr.min.y, par->mr.max.x, par->mr.max.y);
  return 0;
}

/* hooks.c's other function (left out with its hwdraw) */
int memdraw_iprint(char *fmt, ...) { USED(fmt); return -1; }

/* makescreenimage: the draw device's screen, another image on the
 * screen's memory */
void *d9_screenimage(void)
{
  Memdata *md;
  Memimage *i;

  md = mallocz(sizeof *md, 1);
  if(md == nil)
    return nil;
  md->allocd = 1;
  md->bdata = screen->data->bdata;
  md->base = nil;
  md->ref = 1;
  i = allocmemimaged(screen->r, screen->chan, md);
  if(i == nil)
    free(md);
  return i;
}

/* 'b', an image: a = r[4] chan[2] repl clipr[4] value[2] */
void *d9_allocimage(int *a)
{
  Memimage *i;

  i = allocmemimage(R(a), U32(a+4));
  if(i == nil)
    return nil;
  if(a[6])
    i->flags |= Frepl;
  i->clipr = R(a+7);
  if(!a[6])
    rectclip(&i->clipr, R(a));
  memfillcolor(i, U32(a+11));
  return i;
}

/* 'c': a = repl clipr[4] (repl only ever set); 's': clipr[4] */
void d9_setrepl(void *m) { ((Memimage*)m)->flags |= Frepl; }
void d9_setclipr(void *m, int *a) { ((Memimage*)m)->clipr = R(a); }

/* image info: a = chan[2] repl r[4] clipr[4] depth layer; its chan's
 * name in s (chantostr) */
void d9_info(void *m, int *a, char *s)
{
  Memimage *i = m;

  a[0] = i->chan >> 16;
  a[1] = i->chan & 0xFFFF;
  a[2] = (i->flags & Frepl) == Frepl;
  a[3] = i->r.min.x; a[4] = i->r.min.y; a[5] = i->r.max.x; a[6] = i->r.max.y;
  a[7] = i->clipr.min.x; a[8] = i->clipr.min.y; a[9] = i->clipr.max.x; a[10] = i->clipr.max.y;
  a[11] = i->depth;
  a[12] = i->layer != nil;
  chantostr(s, i->chan);
}

/* 'd' (and the font's 'l', 's'): a = r[4] p[2] q[2] op */
void d9_drawop(void *dst, void *src, void *mask, int *a)
{
  memdraw(dst, R(a), src, P(a+4), mask, P(a+6), a[8]);
}

/* 'L': a = p0[2] p1[2] end0 end1 radius sp[2] op */
void d9_line(void *dst, void *src, int *a)
{
  memline(dst, P(a), P(a+2), a[4], a[5], a[6], src, P(a+7), a[9]);
}

/* 'p', 'P': a = end0 end1 radius sp[2] op fill n pts[2n] (P's end0 its
 * winding rule) */
int d9_poly(void *dst, void *src, int *a)
{
  Point *pp;
  int k, n = a[7];

  pp = malloc(n * sizeof(Point));
  if(pp == nil)
    return -1;
  for(k = 0; k < n; k++)
    pp[k] = P(a+8+2*k);
  if(a[6])
    memfillpoly(dst, pp, n, a[0], src, P(a+3), a[5]);
  else
    mempoly(dst, pp, n, a[0], a[1], a[2], src, P(a+3), a[5]);
  free(pp);
  return 0;
}

/* 'e', 'E': a = c[2] a b thick sp[2] op arc alpha phi */
void d9_ellipse(void *dst, void *src, int *a)
{
  if(a[8])
    memarc(dst, P(a), a[2], a[3], a[4], src, P(a+5), a[9], a[10], a[7]);
  else
    memellipse(dst, P(a), a[2], a[3], a[4], src, P(a+5), a[7]);
}

/* 'y', 'Y': a = r[4] compressed; the bytes used (-1: bad) */
int d9_memload(void *dst, int *a, uchar *data, int n)
{
  return memload(dst, R(a), data, n, a[4]);
}

/* 'r': the bytes r[4] of the image take; memunload's count */
int d9_unloadsize(void *m, int *a) { return bytesperline(R(a), ((Memimage*)m)->depth) * Dy(R(a)); }
int d9_unload(void *m, int *a, uchar *data, int n) { return memunload(m, R(a), data, n); }

/* Layers (windows): a screen (Memscreen) its image and fill; a window
 * a layer of it. A window refreshed by messages (Refmesg) has
 * drawrefresh as its function, its pointer a Refx's number in
 * Devdraw.ml's table (0: none), d9_refresh calling it back */
void (*d9_refresh)(int refx, int x0, int y0, int x1, int y1);

static void drawrefresh(Memimage *i, Rectangle r, void *v)
{
  USED(i);
  if(v == nil || d9_refresh == nil)
    return;
  d9_refresh((int)(uintptr)v, r.min.x, r.min.y, r.max.x, r.max.y);
}

/* drawinstallscreen's Memscreen: no windows yet */
void *d9_memscreen(void *image, void *fill)
{
  Memscreen *s;

  s = malloc(sizeof(Memscreen));
  if(s == nil)
    return nil;
  s->image = image;
  s->fill = fill;
  s->frontmost = nil;
  s->rearmost = nil;
  return s;
}

void d9_freememscreen(void *s) { free(s); }

/* its image's chan: a = chan[2] */
void d9_memscreenchan(void *s, int *a)
{
  ulong chan = ((Memscreen*)s)->image->chan;

  a[0] = chan >> 16;
  a[1] = chan & 0xFFFF;
}

/* 'b' on a screen: a = r[4] refresh clipr[4] value[2]; the window
 * with its refresh function (its pointer set by d9_lsetrefresh) */
void *d9_lalloc(void *s, int *a)
{
  Refreshfn reffn;
  Memimage *l;

  reffn = nil;
  switch(a[4]){
  case Refnone: reffn = memlnorefresh; break;
  case Refmesg: reffn = drawrefresh; break;
  }
  l = memlalloc(s, R(a), reffn, nil, U32(a+9));
  if(l == nil)
    return nil;
  l->clipr = R(a+5);
  rectclip(&l->clipr, R(a));
  return l;
}

/* memlsetrefresh(l, its function, refx) */
void d9_lsetrefresh(void *m, int refx)
{
  Memimage *l = m;

  memlsetrefresh(l, l->layer->refreshfn, (void*)(uintptr)refx);
}

/* a window's: a = refx (its Refx's number, 0 none) screenr[4] onscreen
 * (its screen's image the screen's memory) */
void d9_layerinfo(void *m, int *a)
{
  Memlayer *l = ((Memimage*)m)->layer;

  a[0] = l->refreshfn == drawrefresh ? (int)(uintptr)l->refreshptr : 0;
  a[1] = l->screenr.min.x; a[2] = l->screenr.min.y; a[3] = l->screenr.max.x; a[4] = l->screenr.max.y;
  a[5] = l->screen->image->data == screen->data;
}

/* drawfreedimage's: the pointer dropped, the window deleted (its
 * screen's images still good) or freed */
void d9_lfree(void *m, int delete)
{
  Memimage *l = m;

  l->layer->refreshptr = nil;
  if(delete)
    memldelete(l);
  else
    memlfree(l);
}

/* 't': to the front (or the rear) in order; -1 not windows, -2 not on
 * one screen */
int d9_ltofront(void **lp, int nw, int front)
{
  int j;

  if(((Memimage*)lp[0])->layer == nil)
    return -1;
  for(j = 1; j < nw; j++)
    if(((Memimage*)lp[j])->layer->screen != ((Memimage*)lp[0])->layer->screen)
      return -2;
  if(front)
    memltofrontn((Memimage**)lp, nw);
  else
    memltorearn((Memimage**)lp, nw);
  return 0;
}

/* 'o': a = log[2] scr[2]; memlorigin's: -1 failed, 1 moved */
int d9_lorigin(void *m, int *a) { return memlorigin(m, P(a), P(a+2)); }
