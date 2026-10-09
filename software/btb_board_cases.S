    .option norvc
    .option norelax
    .section .text.btb_board_cases,"ax",@progbits
    .balign 4
    .globl btb_board_cases
    .type btb_board_cases, @function

    /* Both outcomes of each real RV32I conditional branch instruction. */
    .macro BRANCH_PAIR opcode, tr1, tr2, fr1, fr2, mask
    \opcode \tr1, \tr2, 1f
    ori a0, a0, \mask
1:  \opcode \fr1, \fr2, 2f
    jal zero, 3f
2:  ori a0, a0, \mask
3:
    .endm

btb_board_cases:
    addi sp, sp, -16
    sw ra, 12(sp)
    sw s0, 4(sp)
    sw s1, 0(sp)
    li a0, 0
    li t0, -1
    li t1, 1
    BRANCH_PAIR beq, t0, t0, t0, t1, 1
    BRANCH_PAIR bne, t0, t1, t0, t0, 2
    BRANCH_PAIR blt, t0, t1, t1, t0, 4
    BRANCH_PAIR bge, t1, t0, t0, t1, 8
    BRANCH_PAIR bltu, t1, t0, t0, t1, 16
    BRANCH_PAIR bgeu, t0, t1, t1, t0, 32

    /* A JAL must skip the poison and write the sequential PC to its link. */
    la t2, .Ljal_link
    jal t3, .Ljal_target
.Ljal_link:
    ori a0, a0, 64
    jal zero, .Ljal_end
.Ljal_target:
    beq t3, t2, .Ljal_end
    ori a0, a0, 64
.Ljal_end:

    /* JALR remains a resolved redirect; bit 0 is cleared by the ISA. */
    la t0, .Ljalr_target
    ori t0, t0, 1
    la t2, .Ljalr_link
    jalr t3, 0(t0)
.Ljalr_link:
    ori a0, a0, 128
    jal zero, .Ljalr_end
.Ljalr_target:
    beq t3, t2, .Ljalr_end
    ori a0, a0, 128
.Ljalr_end:

    /* Repeated taken branch trains its counter; its final exit is false. */
    li t0, 64
    li t1, 0
.Ltrained_loop:
    addi t1, t1, 1
    addi t0, t0, -1
    bne t0, zero, .Ltrained_loop
    li t2, 64
    beq t1, t2, .Lalternating_begin
    ori a0, a0, 256
.Lalternating_begin:
    li t0, 8
    li t1, 0
    li t2, 0
.Lalternating_loop:
    xori t1, t1, 1
    beq t1, zero, .Lalternating_skip
    addi t2, t2, 1
.Lalternating_skip:
    addi t0, t0, -1
    bne t0, zero, .Lalternating_loop
    li t3, 4
    beq t2, t3, .Lconflicts_begin
    ori a0, a0, 256
.Lconflicts_begin:
    mv s0, a0
    li s1, 8
.Lconflicts_loop:
    call btb_conflict_a
    li t0, 0x11
    beq a0, t0, .Lconflict_b_call
    ori s0, s0, 512
.Lconflict_b_call:
    call btb_conflict_b
    li t0, 0x22
    beq a0, t0, .Lconflict_next
    ori s0, s0, 512
.Lconflict_next:
    addi s1, s1, -1
    bne s1, zero, .Lconflicts_loop
    mv a0, s0
    lw s1, 0(sp)
    lw s0, 4(sp)
    lw ra, 12(sp)
    addi sp, sp, 16
    ret
    .size btb_board_cases, .-btb_board_cases

    /* Branch PC +8 in these two blocks has the same PC[7:2] BTB index,
     * while their full PC tags and branch targets are different. */
    .balign 256
    .globl btb_conflict_a
    .globl btb_conflict_a_branch
    .type btb_conflict_a, @function
btb_conflict_a:
    li t0, 8
.Lconflict_a_loop:
    addi t0, t0, -1
btb_conflict_a_branch:
    bne t0, zero, .Lconflict_a_loop
    li a0, 0x11
    ret
    .size btb_conflict_a, .-btb_conflict_a

    .balign 256
    .globl btb_conflict_b
    .globl btb_conflict_b_branch
    .type btb_conflict_b, @function
btb_conflict_b:
    li t0, 8
.Lconflict_b_loop:
    addi t0, t0, -1
btb_conflict_b_branch:
    bne t0, zero, .Lconflict_b_loop
    li a0, 0x22
    ret
    .size btb_conflict_b, .-btb_conflict_b

    /* Fatal unexpected-trap path, never return or advance mepc. Reset SP
     * before calling C because the fault may have interrupted stack setup. */
    .balign 4
    .globl btb_board_trap_entry
    .type btb_board_trap_entry, @function
btb_board_trap_entry:
    csrr a0, mcause
    csrr a1, mepc
    csrr a2, mtval
    la sp, __stack_top
    tail btb_board_trap_fail
    .size btb_board_trap_entry, .-btb_board_trap_entry
