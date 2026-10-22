ENTRY(_start)
MEMORY {
  ROM (rx) : ORIGIN = 0, LENGTH = 32K
  RAM (rw) : ORIGIN = 0x10000, LENGTH = 16K
}
SECTIONS {
  .text : { KEEP(*(.text.start)) *(.text*) *(.rodata*) } > ROM
  .data : { *(.data*) *(.sdata*) } > RAM
  .bss (NOLOAD) : { *(.bss*) *(.sbss*) *(COMMON) } > RAM
  _ram_end = .;
  ASSERT(_ram_end < 0x13000, "reserve at least 4KiB for stack")
  /DISCARD/ : { *(.comment) *(.riscv.attributes) *(.eh_frame*) }
}
