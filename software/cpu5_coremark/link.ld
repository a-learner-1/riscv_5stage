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
        KEEP(*(.text.start))
        *(.text .text.*)
        . = ALIGN(4);
    } > ROM

    /* Read-only data joins the single initialized RAM image, keeping the
       two-image ROM/RAM flow of the frozen CPU5 CoreMark platform map. */
    .data :
    {
        . = ALIGN(4);
        __data_start = .;
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        *(.data .data.*)
        *(.sdata .sdata.*)
        . = ALIGN(4);
        __data_end = .;
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

ASSERT(SIZEOF(.text) <= LENGTH(ROM), "CPU5 CoreMark instruction ROM overflow")
ASSERT(__bss_end <= __stack_top, "CPU5 CoreMark RAM overflow: image collides with stack")
