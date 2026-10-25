OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY {
  ROM (rx) : ORIGIN = 0x00000000, LENGTH = 0x8000
  RAM (rwx) : ORIGIN = 0x00010000, LENGTH = 0x4000
}
SECTIONS {
  .text : { KEEP(*(.text.start)) *(.text .text.*) . = ALIGN(4); } >ROM
  .rodata : { *(.rodata .rodata.*) } >ROM
  .data : { *(.data .data.*) *(.sdata .sdata.*) } >RAM
  .bss (NOLOAD) : { *(.bss .bss.*) *(.sbss .sbss.*) *(COMMON) } >RAM
  /DISCARD/ : { *(.comment) *(.eh_frame*) *(.riscv.attributes) }
}
ASSERT(SIZEOF(.text)+SIZEOF(.rodata)<=0x8000,"CPU5 Stats smoke ROM overflow")
ASSERT(SIZEOF(.rodata)==0 && SIZEOF(.data)==0 && SIZEOF(.bss)==0,"CPU5 Stats smoke must have no data image")
