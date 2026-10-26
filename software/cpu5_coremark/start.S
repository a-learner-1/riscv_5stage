    .option norvc
    .option norelax
    .section .text.start,"ax",@progbits
    .globl _start
    .type _start, @function

_start:
    la sp, __stack_top
    /* CPU5 GPRs are not reset to zero. Give the C prologue defined
       caller-owned callee-save values through ordinary executed ops. */
    li s0,0
    li s1,0
    li s2,0
    li s3,0
    li s4,0
    li s5,0
    li s6,0
    li s7,0
    li s8,0
    li s9,0
    li s10,0
    li s11,0

    la t0, __bss_start
    la t1, __bss_end
1:
    bgeu t0, t1, 2f
    sw zero, 0(t0)
    addi t0, t0, 4
    jal zero, 1b

2:
    call main

    /* portable_fini writes the validation result to tohost. */
3:
    jal zero, 3b

    .size _start, .-_start
