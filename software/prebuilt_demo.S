/*
 * Prebuilt RV32I demo used when a RISC-V GCC toolchain is not installed yet.
 * The checked-in programs/toolchain_demo.hex is the machine-code image of
 * this source. It exercises a loop, forwarding, word memory, byte memory,
 * signed comparison branches and the tohost completion protocol.
 */
    .section .text
    .globl _start
_start:
    addi x9,  x0, 1020       /* tohost = 0x3fc */
    addi x1,  x0, 512        /* scratch = 0x200 */
    addi x2,  x0, 1          /* i = 1 */
    addi x3,  x0, 11         /* stop when i == 11 */
    addi x4,  x0, 0          /* sum = 0 */

sum_loop:
    add  x4,  x4, x2
    sw   x4,  0(x1)
    addi x2,  x2, 1
    blt  x2,  x3, sum_loop

    addi x5,  x0, 55
    bne  x4,  x5, fail

    addi x6,  x0, -1
    sb   x6,  4(x1)
    lbu  x7,  4(x1)
    addi x8,  x0, 255
    bne  x7,  x8, fail

pass:
    addi x10, x0, 1
    sw   x10, 0(x9)
1:
    jal  x0, 1b

fail:
    addi x10, x0, 2
    sw   x10, 0(x9)
2:
    jal  x0, 2b
