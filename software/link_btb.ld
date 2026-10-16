/* BTB board only: retain the shared memory map and fill executable gaps
 * with RV32I NOPs. Keep software/link.ld unchanged for other firmware. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 0x00008000
    RAM (rwx) : ORIGIN = 0x00010000, LENGTH = 0x00004000
}

SECTIONS
{
    .text :
    {
        /* GNU ld uses this byte pattern in alignment gaps: 13 00 00 00.
         * On RV32 little-endian this is ADDI x0,x0,0 (0x00000013).
         * The conflict routines require 256-byte input-section alignment. */
        FILL(0x13000000)
        KEEP(*(.text.start))
        *(.text .text.*)
        . = ALIGN(4);
    } > ROM

    .data :
    {
        . = ALIGN(4);
        *(.rodata .rodata.*)
        *(.data .data.*)
        *(.sdata .sdata.*)
        . = ALIGN(4);
    } > RAM

    .bss (NOLOAD) :
    {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > RAM

    /* Last RAM word is reserved for the simulator completion protocol. */
    .tohost 0x00013ffc (NOLOAD) :
    {
        tohost = .;
        LONG(0)
    } > RAM

    __stack_top = 0x00013fe0;

    /DISCARD/ :
    {
        *(.comment)
        *(.eh_frame*)
        *(.riscv.attributes)
    }
}

ASSERT(SIZEOF(.text) <= LENGTH(ROM), "ROM overflow")
ASSERT(__bss_end <= __stack_top, "RAM overflow: .bss collides with stack")
