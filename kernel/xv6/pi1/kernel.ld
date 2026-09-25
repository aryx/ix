/* mini-xv6's layout (plan_kernel.md, step 4): linked at KERNBASE
 * (0x80000000) + 0x8000, loaded at 0x8000 (where the Pi1's firmware puts
 * kernel.img: the raw image starts at the lowest load address). The
 * boot code (start.s, section .text.boot) runs first at the physical
 * addresses, the MMU off, and jumps to the linked ones once the MMU
 * maps them. Then the bss (the page tables, the vectors' page, the
 * stacks), and [end], where libc.c's malloc starts the OCaml heap. */
ENTRY(_start)
KERNBASE = 0x80000000;
SECTIONS
{
  . = KERNBASE + 0x8000;
  .text : AT(0x8000) { *(.text.boot) *(.text*) }
  .rodata : { *(.rodata*) }
  .data : { *(.data*) }
  . = ALIGN(16384);
  __bss_start = .;
  .bss : { *(.bss*) *(COMMON) }
  . = ALIGN(8);
  __bss_end = .;
  . = . + 0x1000;
  irq_stack_top = .;
  . = . + 0x1000;
  und_stack_top = .;
  . = . + 0x1000;
  abt_stack_top = .;
  . = . + 0x10000;
  stack_top = .;
  end = .;
}
