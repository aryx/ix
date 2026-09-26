/* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 */
/* mini-9pi's OCaml primitives over draw9.c's d9_* (the pixel
 * libraries): an image a C pointer (Memimage*), kept by OCaml as it is
 * (outside its heap: ocaml-light's collector leaves it alone),
 * rectangles and points as tuples of ints. */

#include <mlvalues.h>
#include <alloc.h>
#include <memory.h>
#include <callback.h>
#include "board.h"


int d9_init(unsigned long fb, int w, int h);
void *d9_screen(void);
void *d9_white(void);
void *d9_black(void);
void *d9_opaque(void);
void *d9_color16(int b0, int b1);
void d9_free(void *m);
void d9_draw(void *dst, int x0, int y0, int x1, int y1, void *src, int sx, int sy, void *mask, int mx, int my);
int d9_string(void *dst, int x, int y, void *src, int sx, int sy, char *s);
int d9_fontheight(void);
int d9_stringwidth(char *s);
void *d9_alloc(int x0, int y0, int x1, int y1, unsigned long chan);
int d9_load(void *m, unsigned char *data, int n);
extern void (*d9_avoid)(int x0, int y0, int x1, int y1);
void *d9_screenimage(void);
void *d9_allocimage(int *a);
void d9_setrepl(void *m);
void d9_setclipr(void *m, int *a);
void d9_info(void *m, int *a, char *s);
void d9_drawop(void *dst, void *src, void *mask, int *a);
void d9_line(void *dst, void *src, int *a);
int d9_poly(void *dst, void *src, int *a);
void d9_ellipse(void *dst, void *src, int *a);
int d9_memload(void *dst, int *a, unsigned char *data, int n);
int d9_unloadsize(void *m, int *a);
int d9_unload(void *m, int *a, unsigned char *data, int n);
extern void (*d9_refresh)(int refx, int x0, int y0, int x1, int y1);
void *d9_memscreen(void *image, void *fill);
void d9_freememscreen(void *s);
void d9_memscreenchan(void *s, int *a);
void *d9_lalloc(void *s, int *a);
void d9_lsetrefresh(void *m, int refx);
void d9_layerinfo(void *m, int *a);
void d9_lfree(void *m, int delete);
int d9_ltofront(void **lp, int nw, int front);
int d9_lorigin(void *m, int *a);
value uart_putc(value c);

/* A drawing on the screen calls Swcursor.avoid back (hwdraw): the
 * collector may then run, and move OCaml's values. So a primitive takes
 * what it needs of its arguments (ints, strings copied: cstring, ints)
 * before it draws. */
static char *cstring(value s)
{
  int n = string_length(s);
  char *c = malloc(n + 1);

  memmove(c, String_val(s), n);
  c[n] = 0;
  return c;
}

/* an int array's ints (malloc'ed) */
static int *ints(value a)
{
  int k, n = Wosize_val(a);
  int *c = malloc((n + 1) * sizeof(int));

  for (k = 0; k < n; k++) c[k] = Int_val(Field(a, k));
  return c;
}

static void avoid(int x0, int y0, int x1, int y1)
{
  static value *f;
  value r;

  if (f == 0) f = caml_named_value("swcursor_avoid");
  if (f == 0) return;
  r = alloc_tuple(4);
  Field(r, 0) = Val_int(x0); Field(r, 1) = Val_int(y0); Field(r, 2) = Val_int(x1); Field(r, 3) = Val_int(y1);
  callback(*f, r);
}

/* drawrefresh's: Devdraw.ml's refresh, [| refx r[4] |] */
static void refresh(int refx, int x0, int y0, int x1, int y1)
{
  static value *f;
  value r;

  if (f == 0) f = caml_named_value("draw_refresh");
  if (f == 0) return;
  r = alloc_tuple(5);
  Field(r, 0) = Val_int(refx);
  Field(r, 1) = Val_int(x0); Field(r, 2) = Val_int(y0); Field(r, 3) = Val_int(x1); Field(r, 4) = Val_int(y1);
  callback(*f, r);
}

/* the libraries' messages (draw9.c's print) on the serial console */
void uart_putc_raw(int c) { uart_putc(Val_int(c)); }

/* the screen on the framebuffer at physical address [pa] */
value draw_init(value pa, value w, value h)
{
  d9_avoid = avoid;
  d9_refresh = refresh;
  return Val_bool(d9_init((unsigned long)Long_val(pa) + KERNBASE, Int_val(w), Int_val(h)) == 0);
}

value draw_screen(value unit) { (void)unit; return (value)d9_screen(); }
value draw_white(value unit) { (void)unit; return (value)d9_white(); }
value draw_black(value unit) { (void)unit; return (value)d9_black(); }
value draw_opaque(value unit) { (void)unit; return (value)d9_opaque(); }
value draw_color16(value b0, value b1) { return (value)d9_color16(Int_val(b0), Int_val(b1)); }
value draw_free(value m) { d9_free((void *)m); return Val_unit; }

/* [draw dst (x0, y0, x1, y1) src (sx, sy, mx, my) mask] */
value draw_draw(value dst, value r, value src, value pts, value mask)
{
  d9_draw((void *)dst, Int_val(Field(r, 0)), Int_val(Field(r, 1)), Int_val(Field(r, 2)), Int_val(Field(r, 3)),
          (void *)src, Int_val(Field(pts, 0)), Int_val(Field(pts, 1)),
          (void *)mask, Int_val(Field(pts, 2)), Int_val(Field(pts, 3)));
  return Val_unit;
}

/* [string dst (x, y) src s]: the x after it */
value draw_string(value dst, value p, value src, value s)
{
  int x = Int_val(Field(p, 0)), y = Int_val(Field(p, 1)), r;
  char *c = cstring(s);

  r = d9_string((void *)dst, x, y, (void *)src, 0, 0, c);
  free(c);
  return Val_int(r);
}

value draw_fontheight(value unit) { (void)unit; return Val_int(d9_fontheight()); }
value draw_stringwidth(value s) { return Val_int(d9_stringwidth(String_val(s))); }

/* [alloc (x0, y0, x1, y1) chan]: chan 0 the screen's */
value draw_alloc(value r, value chan)
{
  return (value)d9_alloc(Int_val(Field(r, 0)), Int_val(Field(r, 1)), Int_val(Field(r, 2)), Int_val(Field(r, 3)),
                         (unsigned long)Long_val(chan));
}

value draw_load(value m, value s)
{
  return Val_int(d9_load((void *)m, (unsigned char *)String_val(s), string_length(s)));
}

/*****************************************************************************/
/* The draw device's (Devdraw.ml): ints as int arrays, as d9_*'s */
/*****************************************************************************/

value draw_isnil(value m) { return Val_bool((void *)m == 0); }
value draw_screenimage(value unit) { (void)unit; return (value)d9_screenimage(); }

value draw_allocimage(value a)
{
  int *c = ints(a);
  void *m = d9_allocimage(c);

  free(c);
  return (value)m;
}

value draw_setrepl(value m) { d9_setrepl((void *)m); return Val_unit; }

value draw_setclipr(value m, value a)
{
  int *c = ints(a);

  d9_setclipr((void *)m, c);
  free(c);
  return Val_unit;
}

/* (chan's name, [| chan[2] repl r[4] clipr[4] depth layer |]) */
value draw_info(value m)
{
  int a[13], k;
  char s[32];
  value r = Val_unit, arr = Val_unit, str = Val_unit;

  d9_info((void *)m, a, s);
  Begin_roots3(r, arr, str);
    str = copy_string(s);
    arr = alloc_tuple(13);
    for (k = 0; k < 13; k++) Field(arr, k) = Val_int(a[k]);
    r = alloc_tuple(2);
    Field(r, 0) = str;
    Field(r, 1) = arr;
  End_roots();
  return r;
}

value draw_drawop(value dst, value src, value mask, value a)
{
  int *c = ints(a);

  d9_drawop((void *)dst, (void *)src, (void *)mask, c);
  free(c);
  return Val_unit;
}

value draw_line(value dst, value src, value a)
{
  int *c = ints(a);

  d9_line((void *)dst, (void *)src, c);
  free(c);
  return Val_unit;
}

value draw_poly(value dst, value src, value a)
{
  int *c = ints(a), r;

  r = d9_poly((void *)dst, (void *)src, c);
  free(c);
  return Val_int(r);
}

value draw_ellipse(value dst, value src, value a)
{
  int *c = ints(a);

  d9_ellipse((void *)dst, (void *)src, c);
  free(c);
  return Val_unit;
}

/* [memload dst a data]: the bytes used, -1 bad */
value draw_memload(value dst, value a, value data)
{
  int *c = ints(a), n = string_length(data), r;
  unsigned char *d = malloc(n + 1);

  memmove(d, String_val(data), n);
  r = d9_memload((void *)dst, c, d, n);
  free(d);
  free(c);
  return Val_int(r);
}

/* [unload m a]: r's pixels ("" when memunload fails) */
value draw_unload(value m, value a)
{
  int *c = ints(a), n, k;
  unsigned char *d;
  value s;

  n = d9_unloadsize((void *)m, c);
  d = malloc(n + 1);
  k = d9_unload((void *)m, c, d, n);
  free(c);
  if (k < 0) k = 0;
  s = alloc_string(k);
  memmove(String_val(s), d, k);
  free(d);
  return s;
}

/* layers */

value draw_memscreen(value image, value fill) { return (value)d9_memscreen((void *)image, (void *)fill); }
value draw_freememscreen(value s) { d9_freememscreen((void *)s); return Val_unit; }

/* its image's chan's halves */
value draw_memscreenchan(value s)
{
  int a[2];
  value r;

  d9_memscreenchan((void *)s, a);
  r = alloc_tuple(2);
  Field(r, 0) = Val_int(a[0]);
  Field(r, 1) = Val_int(a[1]);
  return r;
}

value draw_lalloc(value s, value a)
{
  int *c = ints(a);
  void *m = d9_lalloc((void *)s, c);

  free(c);
  return (value)m;
}

value draw_lsetrefresh(value m, value refx) { d9_lsetrefresh((void *)m, Int_val(refx)); return Val_unit; }

/* [| refx screenr[4] onscreen |] */
value draw_layerinfo(value m)
{
  int a[6], k;
  value r;

  d9_layerinfo((void *)m, a);
  r = alloc_tuple(6);
  for (k = 0; k < 6; k++) Field(r, k) = Val_int(a[k]);
  return r;
}

value draw_lfree(value m, value delete) { d9_lfree((void *)m, Bool_val(delete)); return Val_unit; }

/* [ltofront images front]: 0, -1 not windows, -2 not one screen */
value draw_ltofront(value imgs, value front)
{
  int k, n = Wosize_val(imgs), r;
  void **lp = malloc((n + 1) * sizeof(void *));

  for (k = 0; k < n; k++) lp[k] = (void *)Field(imgs, k);
  r = d9_ltofront(lp, n, Bool_val(front));
  free(lp);
  return Val_int(r);
}

value draw_lorigin(value m, value a)
{
  int *c = ints(a), r;

  r = d9_lorigin((void *)m, c);
  free(c);
  return Val_int(r);
}
