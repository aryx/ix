/* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 */
/* mini-xv6 (plan_kernel.md): the machine as the OCaml kernel sees it
 * (Machine.ml's externals), built up in kernel/step1-5/: physical
 * memory by physical address, the running process's trap frame, the
 * user's translation table, the kernel stacks and their switch (with
 * the runtime's view of the stack: step 3), the system timer, the
 * PL011's input, the file system's image; and the other direction,
 * start.s's traps calling the kernel's "trap", "irq", "fault". Physical
 * memory is reached by physical address, which fits an OCaml int: the
 * kernel's own addresses (KERNBASE and up) never reach OCaml.
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
#include <alloc.h>
#include <string.h>

#define NPROC 64                      /* xv6 arm-pi1's param.h */
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

#define KERNBASE 0x80000000u
#define P2V(pa) ((volatile unsigned char *)((unsigned)(pa) + KERNBASE))

/* physical memory: bytes and words (a word's bit 31 lost: Int32 when it
 * matters; the kernel's page table entries and addresses stay below) */
value phys_get8(value pa) { return Val_int(*P2V(Long_val(pa))); }
value phys_set8(value pa, value v) { *P2V(Long_val(pa)) = Long_val(v); return Val_unit; }
value phys_get32(value pa) { return Val_int(*(volatile unsigned *)P2V(Long_val(pa))); }
value phys_set32(value pa, value v) { *(volatile unsigned *)P2V(Long_val(pa)) = Long_val(v); return Val_unit; }
value phys_get16(value pa) { return Val_int(*(volatile unsigned short *)P2V(Long_val(pa))); }
value phys_set16(value pa, value v) { *(volatile unsigned short *)P2V(Long_val(pa)) = Long_val(v); return Val_unit; }
value phys_zero(value pa, value n)
{
  volatile unsigned *p = (volatile unsigned *)P2V(Long_val(pa));
  int i;
  for (i = 0; i < Long_val(n) / 4; i++) p[i] = 0;
  return Val_unit;
}

/* bytes between OCaml and physical memory: a page copied, a string
 * written, one read */
value phys_copy(value dst, value src, value n)
{
  memmove((void *)P2V(Long_val(dst)), (void *)P2V(Long_val(src)), Long_val(n));
  return Val_unit;
}
value phys_write(value pa, value s)
{
  memmove((void *)P2V(Long_val(pa)), String_val(s), string_length(s));
  return Val_unit;
}
value phys_read(value pa, value n)
{
  value s = alloc_string(Long_val(n));
  memmove(String_val(s), (void *)P2V(Long_val(pa)), Long_val(n));
  return s;
}

/* the running process's trap frame, word n */
value tf_get(value n) { return Val_int(cur_tf[Int_val(n)]); }
/* a word whose top bits matter (the CPSR's flags): an Int32 */
value tf_get32(value n) { return copy_int32(cur_tf[Int_val(n)]); }
value tf_set(value n, value v) { cur_tf[Int_val(n)] = Long_val(v); return Val_unit; }

/* the user's translation table: TTBR0 at [pa] (0: the empty one), the
 * TLB emptied */
extern char empty_pgdir[];
value mmu_switch(value pa)
{
  unsigned t = Long_val(pa) ? (unsigned)Long_val(pa) : (unsigned)empty_pgdir - KERNBASE;
  __asm__ volatile("mcr p15, 0, %0, c2, c0, 0" : : "r"(t));
  __asm__ volatile("mcr p15, 0, %0, c8, c7, 0" : : "r"(0));
  return Val_unit;
}

/* the file system's image (start.s): its physical address and size */
extern char fs_image[], fs_image_end[];
value fs_base(value unit) { (void)unit; return Val_int((unsigned)fs_image - KERNBASE); }
value fs_size(value unit) { (void)unit; return Val_int(fs_image_end - fs_image); }

/* the console: the PL011, at 0xFE201000 now */
value uart_putc(value c)
{
  while (*(volatile unsigned *)0xFE201018 & 0x20)
    ;
  *(volatile unsigned *)0xFE201000 = Int_val(c) & 0xff;
  return Val_unit;
}

/* the PL011's input: a character or -1; its receive interrupt (the
 * controller's IRQ 57, bank 2's bit 25) on */
#define UART ((volatile unsigned *)0xFE201000)
value uart_getc(value unit) { (void)unit; return Val_int((UART[6] & 0x10) ? -1 : (int)(UART[0] & 0xff)); }
value uart_rx_enable(value unit)
{
  (void)unit;
  UART[14] = 1 << 4;                               /* IMSC: RXIM */
  ((volatile unsigned *)0xFE00B200)[5] = 1 << 25;  /* enable IRQs 2: 57 */
  return Val_unit;
}

value machine_halt(value unit) { (void)unit; exit(0); return Val_unit; }

/* back to user mode, from the running process's trap frame */
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

/* slot [p]'s kernel side: a fresh kernel stack, entered at the
 * trampoline (its first switch) */
value proc_context(value p)
{
  int i = Int_val(p), k;
  struct context *c = &contexts[i];
  for (k = 0; k < 10; k++) c->regs[k] = 0;
  c->regs[8] = (unsigned)(kstacks[i] + KSTACK);     /* sp */
  c->regs[9] = (unsigned)trampoline;               /* lr */
  c->bottom_of_stack = NULL; c->last_return_address = 0; c->gc_regs = NULL;
  c->exception_pointer = NULL; c->local_roots = NULL;
  started[i] = 1;
  return Val_unit;
}

/* slot [p]'s trap frame: zeros, user mode, IRQs on (xv6's userinit) */
value tf_init(value p)
{
  int i = Int_val(p), k;
  for (k = 0; k < 17; k++) trapframes[i][k] = 0;
  trapframes[i][16] = 0x10;                        /* USR, IRQs and FIQs on (xv6 arm-pi1's: no FIQ is ever enabled) */
  return Val_unit;
}

/* fork: the running process's trap frame copied to slot [p]'s, but r0:
 * 0, fork's result in the child */
value tf_copy(value p)
{
  int k;
  for (k = 0; k < 17; k++) trapframes[Int_val(p)][k] = cur_tf[k];
  trapframes[Int_val(p)][0] = 0;
  return Val_unit;
}

/* a slot no longer used: the collector need not look at its stack */
value proc_free(value p) { started[Int_val(p)] = 0; return Val_unit; }

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

/*****************************************************************************/
/* The timer */
/*****************************************************************************/

#define TIMER ((volatile unsigned *)0xFE003000)    /* CS, CLO, CHI, C0-C3 */
#define INTC ((volatile unsigned *)0xFE00B200)     /* basic pending, pending 1 ... */

/* the next tick in [us] microseconds: compare 3's match cleared, the
 * compare set; its IRQ (3) enabled */
value timer_arm(value us)
{
  TIMER[0] = 1 << 3;
  TIMER[6] = TIMER[1] + Long_val(us);
  INTC[4] = 1 << 3;                               /* enable IRQs 1 */
  return Val_unit;
}

value timer_pending(value unit) { (void)unit; return Val_bool((TIMER[0] & (1 << 3)) != 0); }

/* wait for an interrupt, IRQs masked: wfi returns when one is pending */
value wait_interrupt(value unit) { (void)unit; __asm__ volatile("wfi"); return Val_unit; }

/* a user's IRQ (start.s's irq_entry) */
void irq(void)
{
  static value *handler = NULL;
  if (handler == NULL) handler = caml_named_value("irq");
  callback(*handler, Val_unit);
}

/* a user's fault (start.s's aborts from user mode): the kernel's
 * "fault" with the kind (2 prefetch, 3 data), the address and the
 * status (FAR and FSR, CP15 c6 and c5) */
void user_fault(int kind)
{
  static value *handler = NULL;
  unsigned far, fsr;
  if (kind == 3) {
    __asm__ volatile("mrc p15, 0, %0, c6, c0, 0" : "=r"(far));
    __asm__ volatile("mrc p15, 0, %0, c5, c0, 0" : "=r"(fsr));
  } else {
    __asm__ volatile("mrc p15, 0, %0, c6, c0, 2" : "=r"(far));
    __asm__ volatile("mrc p15, 0, %0, c5, c0, 1" : "=r"(fsr));
  }
  if (handler == NULL) handler = caml_named_value("fault");
  /* the address may be the kernel's (0x80000000 and up): an Int32, made
   * right before the call (nothing allocates in between) */
  callback3(*handler, Val_int(kind), copy_int32(far), Val_int(fsr));
}

/* a kernel's fault: the machine stops, saying which and where */
static void puts_(const char *s) { while (*s) uart_putc(Val_int(*s++)); }

static void puthex(unsigned v)
{
  char hex[9];
  int i;
  for (i = 0; i < 8; i++) hex[i] = "0123456789abcdef"[(v >> (28 - 4 * i)) & 15];
  hex[8] = 0;
  puts_(hex);
}

void kfault(int kind, unsigned lr)
{
  static const char *names[] = { "", "undefined instruction", "prefetch abort", "data abort" };
  unsigned far;
  __asm__ volatile("mrc p15, 0, %0, c6, c0, 0" : "=r"(far));
  puts_("mini-xv6: in the kernel, ");
  puts_(names[kind]);
  puts_(", lr ");
  puthex(lr);
  puts_(", far ");
  puthex(far);
  puts_("\n");
  exit(3);
}
