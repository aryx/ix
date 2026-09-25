/* mini-xv6's layout (plan_kernel.md): the image at 0x8000, where the
 * Pi1's firmware loads kernel.img; its bss; a 64KB stack; then [end],
 * where libc.c's malloc starts the OCaml heap. */
ENTRY(_start)
SECTIONS
{
  . = 0x8000;
  .text : { *(.text.start) *(.text*) }
  .rodata : { *(.rodata*) }
  .data : { *(.data*) }
  . = ALIGN(8);
  __bss_start = .;
  .bss : { *(.bss*) *(COMMON) }
  . = ALIGN(8);
  __bss_end = .;
  . = . + 0x10000;
  stack_top = .;
  end = .;
}
