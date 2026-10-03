/* Addresses differ by 1024 bytes: same set, different tags in 2x64x16 cache.
 * Every function crosses two lines. A/B/A/C/A/B checks conflicting calls and
 * returns without changing the RV32I ABI or benchmark source. */
.option norvc
.section .text.icache_workload,"ax",@progbits
.balign 1024
.global icache_a
icache_a:
    addi a0,a0,1
    .rept 8
    nop
    .endr
    ret
.balign 1024
.global icache_b
icache_b:
    addi a0,a0,2
    .rept 8
    nop
    .endr
    ret
.balign 1024
.global icache_c
icache_c:
    addi a0,a0,4
    .rept 8
    nop
    .endr
    ret
