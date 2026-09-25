ENTRY(_ustart)
SECTIONS { . = 0; .text : { *(.text*) } .rodata : { *(.rodata*) } .data : { *(.data*) } .bss : { *(.bss*) } }
