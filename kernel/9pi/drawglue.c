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
value uart_putc(value c);

/* the libraries' messages (draw9.c's print) on the serial console */
void uart_putc_raw(int c) { uart_putc(Val_int(c)); }

/* the screen on the framebuffer at physical address [pa] */
value draw_init(value pa, value w, value h)
{
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
  return Val_int(d9_string((void *)dst, Int_val(Field(p, 0)), Int_val(Field(p, 1)), (void *)src, 0, 0, String_val(s)));
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
