/* RV32I, linked at zero; exact words are in d0_causal_common.hex. */
.option norvc
.option norelax
.section .text
.globl _start
_start:
    lui x1, 0x10
    addi x2, x0, 0x123
    sw x2, 0(x1)          /* write miss */
    lw x3, 0(x1)          /* refill, expected 0x123 */
    addi x2, x0, 0x7e
    sb x2, 1(x1)          /* byte write hit */
    lhu x4, 0(x1)         /* expected 0x7e23 */
    addi x2, x0, 0x456
    sh x2, 2(x1)          /* halfword write hit */
    lw x5, 0(x1)          /* expected 0x04567e23 */
    sw x2, 32(x1)         /* word write miss */
    lw x6, 32(x1)         /* refill, expected 0x456 */
    sw x2, 4(x1)          /* word write hit */
    lw x7, 4(x1)          /* expected 0x456 */
    addi x31, x0, 1       /* completion marker at PC 56 */
1:  jal x0, 1b
.rept 240
    .word 0x00000013
.endr
