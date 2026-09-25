/* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 */
/* mini-xv6, step 2 (plan_kernel.md): the machine as OCaml sees it. The
 * primitives Main.ml declares [external] (the memory's words and bytes,
 * the console, entering user mode, halting), and the other direction:
 * start.s's trap entry calls trap(), which calls the OCaml function the
 * kernel registered as "trap". libc.c is the C library the runtime
 * needs; this is the kernel's own C, as small as the machine allows. */

#include <mlvalues.h>
#include <callback.h>

/* start.s's: the user's registers at the trap; back to user mode */
unsigned trapframe[17];
void user_return(void);
void exit(int status);

/*****************************************************************************/
/* The primitives */
/*****************************************************************************/

/* the memory: an address and a value as OCaml ints (the Pi1's addresses
 * all below 1GB fit, plan_kernel.md decision 3; a word's bit 31 is lost:
 * Int32 when it matters) */
value mem_get8(value a) { return Val_int(*(volatile unsigned char *)Long_val(a)); }
value mem_get32(value a) { return Val_int(*(volatile unsigned *)Long_val(a)); }
value mem_set32(value a, value v) { *(volatile unsigned *)Long_val(a) = Long_val(v); return Val_unit; }

/* the trap frame's address */
value trapframe_addr(value unit) { (void)unit; return Val_int((unsigned)trapframe); }

/* the console: the PL011, a character at a time */
value uart_putc(value c)
{
  while (*(volatile unsigned *)0x20201018 & 0x20)
    ;
  *(volatile unsigned *)0x20201000 = Int_val(c) & 0xff;
  return Val_unit;
}

value machine_halt(value unit) { (void)unit; exit(0); return Val_unit; }

/* to user mode at pc with stack sp, IRQs masked (no interrupt yet):
 * the trap frame set, then start.s's way back from a trap. It does not
 * return: the user's system calls come back through trap() */
value user_enter(value pc, value sp)
{
  int i;
  for (i = 0; i < 13; i++) trapframe[i] = 0;
  trapframe[13] = Long_val(sp);
  trapframe[14] = 0;
  trapframe[15] = Long_val(pc);
  trapframe[16] = 0x10 | 0x80 | 0x40;   /* USR, I and F masked */
  user_return();
  return Val_unit;
}

/*****************************************************************************/
/* The traps */
/*****************************************************************************/

/* a system call: the kernel's OCaml handler, registered by name */
void trap(void)
{
  static value *handler = NULL;
  if (handler == NULL) handler = caml_named_value("trap");
  callback(*handler, Val_unit);
}

/* a fault: the machine stops, saying which and where */
static void puts_(const char *s) { while (*s) uart_putc(Val_int(*s++)); }

void kfault(int kind, unsigned lr)
{
  static const char *names[] = { "", "undefined instruction", "prefetch abort", "data abort" };
  char hex[9];
  int i;
  for (i = 0; i < 8; i++) hex[i] = "0123456789abcdef"[(lr >> (28 - 4 * i)) & 15];
  hex[8] = 0;
  puts_("mini-xv6: ");
  puts_(names[kind]);
  puts_(", lr ");
  puts_(hex);
  puts_("\n");
  exit(3);
}

/* the user program's entry and stack (user.s) */
void user_main(void);
extern char user_stack_top[];
value user_entry(value unit) { (void)unit; return Val_int((unsigned)user_main); }
value user_stack(value unit) { (void)unit; return Val_int((unsigned)user_stack_top); }
