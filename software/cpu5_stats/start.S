    .option norvc
    .option norelax
    .section .text.start,"ax",@progbits
    .globl _start
_start:
    lui sp,0x14
    addi sp,sp,-16
    /* Give the C prologue defined caller-owned callee-save values. CPU GPRs
       are not reset to zero; these are ordinary executed initialization ops. */
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
    call cpu5_smoke
1:  j 1b
