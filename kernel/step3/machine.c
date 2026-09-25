/* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 */
/* mini-xv6, step 3 (plan_kernel.md): the machine as OCaml sees it.
 * Step 2's primitives and trap, and the processes' side: each slot a
 * trap frame, a kernel stack and a context, which k_swtch switches.
 *
 * The runtime's view of the stack. OCaml's collector finds the values
 * a stack holds from a few globals, set when OCaml calls C
 * (caml_bottom_of_stack, caml_last_return_address: where OCaml's frames
 * stop; caml_gc_regs, caml_exception_pointer, local_roots). They
 * describe the running stack; each process's kernel stack has its own
 * values, kept in its context while it does not run: k_swtch saves them
 * with the registers and puts them back when the process resumes. And
 * the collector must see the stacks that do not run: scan_stacks,
 * installed as the runtime's scan_roots_hook (the one systhreads uses),
 * walks each with do_local_roots. */

#include <mlvalues.h>
#include <callback.h>
#include <memory.h>
#include <roots.h>
#include <stack.h>

#define NPROC 8
#define KSTACK 16384

void user_return(void);
void exit(int status);

/* the trap frames; start.s uses the running process's */
unsigned trapframes[NPROC][17];
unsigned *cur_tf;

/* a context: what swtch keeps (r4-r11, sp, lr, d8-d15), then the
 * runtime's view of the stack */
struct context {
  unsigned regs[10];
  unsigned long long vfp[8];
  char *bottom_of_stack;
  unsigned long last_return_address;
  value *gc_regs;
  char *exception_pointer;
  struct caml__roots_block *local_roots;
};

/* the processes' slots, and one more: the scheduler's, on the boot stack */
static struct context contexts[NPROC + 1];
static char kstacks[NPROC][KSTACK] __attribute__((aligned(8)));
static int current = NPROC;
static int started[NPROC + 1];

void swtch(struct context *from, struct context *to);

/*****************************************************************************/
/* The primitives */
/*****************************************************************************/

/* the memory: an address and a value as OCaml ints (the Pi1's addresses
 * all below 1GB fit, plan_kernel.md decision 3; a word's bit 31 is lost:
 * Int32 when it matters) */
value mem_get8(value a) { return Val_int(*(volatile unsigned char *)Long_val(a)); }
value mem_get32(value a) { return Val_int(*(volatile unsigned *)Long_val(a)); }
value mem_set32(value a, value v) { *(volatile unsigned *)Long_val(a) = Long_val(v); return Val_unit; }

/* the running process's trap frame's address */
value trapframe_addr(value unit) { (void)unit; return Val_int((unsigned)cur_tf); }

/* the console: the PL011, a character at a time */
value uart_putc(value c)
{
  while (*(volatile unsigned *)0x20201018 & 0x20)
    ;
  *(volatile unsigned *)0x20201000 = Int_val(c) & 0xff;
  return Val_unit;
}

value machine_halt(value unit) { (void)unit; exit(0); return Val_unit; }

/* back to user mode, from the running process's trap frame: from its
 * kernel stack, which the next trap finds where it is left */
value user_resume(value unit) { (void)unit; user_return(); return Val_unit; }

/*****************************************************************************/
/* The processes */
/*****************************************************************************/

static void save_view(struct context *c)
{
  c->bottom_of_stack = caml_bottom_of_stack;
  c->last_return_address = caml_last_return_address;
  c->gc_regs = caml_gc_regs;
  c->exception_pointer = caml_exception_pointer;
  c->local_roots = local_roots;
}

static void restore_view(struct context *c)
{
  caml_bottom_of_stack = c->bottom_of_stack;
  caml_last_return_address = c->last_return_address;
  caml_gc_regs = c->gc_regs;
  caml_exception_pointer = c->exception_pointer;
  local_roots = c->local_roots;
}

/* the collector's hook: the stacks that do not run (a process not yet
 * started has no OCaml frames) */
static void scan_stacks(scanning_action f)
{
  int i;
  for (i = 0; i <= NPROC; i++)
    if (i != current && started[i] && contexts[i].bottom_of_stack != NULL)
      do_local_roots(f, contexts[i].bottom_of_stack, contexts[i].last_return_address,
                     contexts[i].gc_regs, contexts[i].local_roots);
}

/* a new process's first run: its kernel stack empty, its view of it
 * empty, OCaml entered by a callback (whose link says: no frames
 * above) to "process_start", which enters user mode */
static void trampoline(void)
{
  static value *start = NULL;
  restore_view(&contexts[current]);
  if (start == NULL) start = caml_named_value("process_start");
  callback(*start, Val_int(current));
  exit(4);                     /* process_start never returns */
}

/* slot [p]: a process to start at pc with the user stack sp */
value proc_init(value p, value pc, value sp)
{
  int i = Int_val(p), k;
  struct context *c = &contexts[i];
  for (k = 0; k < 17; k++) trapframes[i][k] = 0;
  trapframes[i][13] = Long_val(sp);
  trapframes[i][15] = Long_val(pc);
  trapframes[i][16] = 0x10 | 0x80 | 0x40;          /* USR, I and F masked */
  for (k = 0; k < 10; k++) c->regs[k] = 0;
  c->regs[8] = (unsigned)(kstacks[i] + KSTACK);     /* sp */
  c->regs[9] = (unsigned)trampoline;               /* lr */
  c->bottom_of_stack = NULL; c->last_return_address = 0; c->gc_regs = NULL;
  c->exception_pointer = NULL; c->local_roots = NULL;
  started[i] = 1;
  return Val_unit;
}

/* from the running slot to [to] (a process, or NPROC the scheduler);
 * returns when something switches back */
value k_swtch(value to)
{
  int from = current, t = Int_val(to);
  static int hooked = 0;
  if (!hooked) { scan_roots_hook = scan_stacks; started[NPROC] = 1; hooked = 1; }
  save_view(&contexts[from]);
  current = t;
  if (t < NPROC) cur_tf = trapframes[t];
  swtch(&contexts[from], &contexts[t]);
  /* back in [from] */
  restore_view(&contexts[from]);
  return Val_unit;
}

value k_current(value unit) { (void)unit; return Val_int(current); }

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

/* the user program's entry (user.s), and a user stack per slot */
void user_main(void);
static char ustacks[NPROC][4096] __attribute__((aligned(8)));
value user_entry(value unit) { (void)unit; return Val_int((unsigned)user_main); }
value user_stack(value p) { return Val_int((unsigned)(ustacks[Int_val(p)] + 4096)); }
