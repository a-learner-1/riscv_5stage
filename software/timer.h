#ifndef RISCV_3STAGE_TIMER_H
#define RISCV_3STAGE_TIMER_H

#include "mmio.h"
typedef unsigned long long timer_u64;

#define MMIO_MTIME_LO_ADDR    0x20000040u
#define MMIO_MTIME_HI_ADDR    0x20000044u
#define MMIO_MTIMECMP_LO_ADDR 0x20000048u
#define MMIO_MTIMECMP_HI_ADDR 0x2000004cu
#define TIMER_MTIE_MASK 0x80u
#define TIMER_MTIP_MASK 0x80u
#define TIMER_MIE_MASK  0x08u

/* RV32 coherent 64-bit counter read: retry if the high word changed. */
static inline timer_u64 timer_read_time(void)
{
    uint32_t hi, lo, again;
    do {
        hi = MMIO_REG32(MMIO_MTIME_HI_ADDR);
        lo = MMIO_REG32(MMIO_MTIME_LO_ADDR);
        again = MMIO_REG32(MMIO_MTIME_HI_ADDR);
    } while (hi != again);
    return ((timer_u64)hi << 32) | lo;
}

/* Prevent an intermediate smaller comparison value while writing RV32
 * halves: low=all ones, then final high, then final low. */
static inline void timer_write_compare(timer_u64 value)
{
    MMIO_REG32(MMIO_MTIMECMP_LO_ADDR) = 0xffffffffu;
    MMIO_REG32(MMIO_MTIMECMP_HI_ADDR) = (uint32_t)(value >> 32);
    MMIO_REG32(MMIO_MTIMECMP_LO_ADDR) = (uint32_t)value;
}

static inline void timer_cancel(void)
{
    timer_write_compare(~(timer_u64)0);
}

#endif
