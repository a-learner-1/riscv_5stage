    .option norvc
    .section .text
    .globl _start

_start:
    lui  x1, 0x20000       /* x1 = MMIO base 0x20000000 */
    lw   x2, 0(x1)         /* read cycle counter */
    lw   x4, 4(x1)         /* read instret counter */
    addi x3, x0, 65        /* ASCII 'A' */
    sw   x3, 16(x1)        /* write simulation console */

finished:
    jal  x0, finished
