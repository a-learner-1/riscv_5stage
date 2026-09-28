    .option norvc
    .section .text.start,"ax",@progbits
    .globl _start
    .type _start, @function

/* Minimal RV32I bare-metal startup. */
_start:
    la sp, __stack_top

    /* Clear .bss so ordinary uninitialized C globals start at zero. */
    la t0, __bss_start
    la t1, __bss_end
1:
    bgeu t0, t1, 2f
    sw zero, 0(t0)
    addi t0, t0, 4
    jal zero, 1b

2:
    call main

    /* main returns 1 on pass and another value on failure. */
    la t0, tohost
    sw a0, 0(t0)
3:
    jal zero, 3b

    .size _start, .-_start
