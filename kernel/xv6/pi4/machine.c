/* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 */
/* mini-xv6 on the Pi4 (plan_kernel.md): the machine as the OCaml kernel
 * sees it (Machine.ml's externals, the Pi1's names): physical memory
 * by physical address (KERNBASE added here: OCaml never holds a
 * kernel's address), the user's translation table (TTBR0), the PL011,
 * the ARM generic timer (the virtual one, as xv6 arm64-pi4), the
 * GIC-400 in front of both, the file system's image; and the
 * exceptions from EL0 (start.s), as runtime.c's user_fault wants them. */

#include <mlvalues.h>
#include <alloc.h>
#include <string.h>
#include "board.h"

void exit(int status);
extern unsigned long *cur_tf;
void user_fault(int ec, unsigned long esr, unsigned long elr, unsigned long far);
void irq(void);

#define P2V(pa) ((volatile unsigned char *)((unsigned long)(pa) + KERNBASE))
#define REG(pa) (*(volatile unsigned *)P2V(pa))

/*****************************************************************************/
/* The primitives */
/*****************************************************************************/

/* physical memory: bytes, halves, words, doublewords (OCaml's ints have
 * 63 bits: a doubleword's top bit lost, none of the kernel's page table
 * entries has it) */
value phys_get8(value pa) { return Val_long(*P2V(Long_val(pa))); }
value phys_set8(value pa, value v) { *P2V(Long_val(pa)) = Long_val(v); return Val_unit; }
value phys_get16(value pa) { return Val_long(*(volatile unsigned short *)P2V(Long_val(pa))); }
value phys_set16(value pa, value v) { *(volatile unsigned short *)P2V(Long_val(pa)) = Long_val(v); return Val_unit; }
value phys_get32(value pa) { return Val_long(*(volatile unsigned *)P2V(Long_val(pa))); }
value phys_set32(value pa, value v) { *(volatile unsigned *)P2V(Long_val(pa)) = Long_val(v); return Val_unit; }
value phys_get64(value pa) { return Val_long(*(volatile unsigned long *)P2V(Long_val(pa))); }
value phys_set64(value pa, value v) { *(volatile unsigned long *)P2V(Long_val(pa)) = Long_val(v); return Val_unit; }
value phys_zero(value pa, value n)
{
  volatile unsigned long *p = (volatile unsigned long *)P2V(Long_val(pa));
  long i;
  for (i = 0; i < Long_val(n) / 8; i++) p[i] = 0;
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

/* the user's translation table: TTBR0 at [pa] (0: the empty one), the
 * TLB emptied, the instruction cache too (exec wrote the program
 * through the data side: on the real Pi4 the data cache would need a
 * clean to the point of unification first; the emulators have none) */
extern char empty_pgdir[];
value mmu_switch(value pa)
{
  unsigned long t = Long_val(pa) ? (unsigned long)Long_val(pa) : (unsigned long)empty_pgdir - KERNBASE;
  __asm__ volatile("msr ttbr0_el1, %0; isb; tlbi vmalle1; ic iallu; dsb sy; isb" : : "r"(t));
  return Val_unit;
}

/* the file system's image (start.s): its physical address and size */
extern char fs_image[], fs_image_end[];
value fs_base(value unit) { (void)unit; return Val_long((unsigned long)fs_image - KERNBASE); }
value fs_size(value unit) { (void)unit; return Val_long(fs_image_end - fs_image); }

/*****************************************************************************/
/* The PL011, the GIC-400 */
/*****************************************************************************/

#define UART 0xFE201000UL
#define GICD 0xFF841000UL                /* the distributor */
#define GICC 0xFF842000UL                /* the CPU interface */
#define UART_IRQ 153                     /* an SPI */
#define TIMER_IRQ 27                     /* the virtual timer's PPI */

value uart_putc(value c)
{
  while (REG(UART + 0x18) & 0x20)        /* FR: the transmit FIFO full */
    ;
  REG(UART) = Long_val(c) & 0xff;
  return Val_unit;
}

value uart_getc(value unit) { (void)unit; return Val_long((REG(UART + 0x18) & 0x10) ? -1 : (long)(REG(UART) & 0xff)); }

/* an interrupt to CPU 0 at the highest priority, enabled */
static void gic_enable(int irq)
{
  *(volatile unsigned char *)P2V(GICD + 0x400 + irq) = 0;       /* IPRIORITYR */
  if (irq >= 32) *(volatile unsigned char *)P2V(GICD + 0x800 + irq) = 1;   /* ITARGETSR */
  REG(GICD + 0x100 + 4 * (irq / 32)) = 1u << (irq % 32);         /* ISENABLER */
}

value uart_rx_enable(value unit)
{
  (void)unit;
  REG(UART + 0x38) = 1 << 4;             /* IMSC: RXIM */
  gic_enable(UART_IRQ);
  return Val_unit;
}

value machine_halt(value unit) { (void)unit; exit(0); return Val_unit; }

/* the board's start, before OCaml's (start.s): the PL011 on (nothing
 * else on the Pi4 turns it on, and QEMU drops what a disabled one is
 * sent), the GIC's distributor and CPU interface on, every priority
 * let through */
void board_init(void)
{
  REG(UART + 0x30) = 0x301;              /* CR: UARTEN, TXE, RXE */
  REG(GICD) = 1;                         /* GICD_CTLR */
  REG(GICC + 0x04) = 0xff;               /* GICC_PMR */
  REG(GICC) = 1;                         /* GICC_CTLR */
}

/*****************************************************************************/
/* The timer */
/*****************************************************************************/

/* the next tick in [us] microseconds: the virtual timer's value, from
 * its frequency; its interrupt on */
value timer_arm(value us)
{
  unsigned long f, t;
  __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(f));
  t = f / 1000000 * Long_val(us);
  __asm__ volatile("msr cntv_tval_el0, %0; msr cntv_ctl_el0, %1; isb" : : "r"(t), "r"(1UL));
  gic_enable(TIMER_IRQ);
  return Val_unit;
}

value timer_pending(value unit)
{
  unsigned long c;
  (void)unit;
  __asm__ volatile("mrs %0, cntv_ctl_el0" : "=r"(c));
  return Val_bool((c & 5) == 5);         /* enabled, ISTATUS */
}

/* wait for an interrupt, IRQs masked: wfi returns when one is pending */
value wait_interrupt(value unit) { (void)unit; __asm__ volatile("wfi"); return Val_unit; }

/*****************************************************************************/
/* The exceptions from EL0 (start.s) */
/*****************************************************************************/

/* an IRQ: acknowledged and ended at the GIC first (the devices'
 * interrupts are levels: they stay until OCaml handles them, and the
 * GIC must not keep this one active while the process gives up the
 * CPU, the scheduler waiting for the next), then the kernel's "irq" */
void pi4_irq(void)
{
  unsigned iar = REG(GICC + 0x0c);       /* GICC_IAR */
  if ((iar & 0x3ff) != 1023) REG(GICC + 0x10) = iar;   /* GICC_EOIR */
  irq();
}

/* a synchronous exception other than a system call: the process's
 * fault, with ESR_EL1's class and syndrome, the pc, FAR_EL1 */
void user_abort64(unsigned long esr)
{
  unsigned long far;
  __asm__ volatile("mrs %0, far_el1" : "=r"(far));
  user_fault((int)(esr >> 26) & 0x3f, esr, cur_tf[32], far);
}

/* a kernel's exception: the machine stops, saying which and where */
static void puts_(const char *s) { while (*s) uart_putc(Val_long(*s++)); }

static void puthex(unsigned long v)
{
  char hex[17];
  int i;
  for (i = 0; i < 16; i++) hex[i] = "0123456789abcdef"[(v >> (60 - 4 * i)) & 15];
  hex[16] = 0;
  puts_(hex);
}

void kfault64(unsigned long esr, unsigned long elr, unsigned long far)
{
  puts_("mini-xv6: in the kernel, esr ");
  puthex(esr);
  puts_(", elr ");
  puthex(elr);
  puts_(", far ");
  puthex(far);
  puts_("\n");
  exit(3);
}
