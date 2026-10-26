#ifndef COREMARK_CPU5_STATS_H
#define COREMARK_CPU5_STATS_H

/* CPU5 CoreMark identity: schema4/profile2 statistics, ten 64-bit exclusive
 * cycle classes and the CPU5 MMIO/UART/timer map. Generated build metadata
 * must describe the hardware this exact image runs on; the original
 * schema3/profile1 AXI CoreMark header must reject these values. */
#if !defined(CPU5_COREMARK_PLATFORM_NAME) || !defined(CPU5_COREMARK_CACHE_ENABLE) || \
    !defined(CPU5_COREMARK_D0_BRAM) || !defined(CPU5_COREMARK_BACKEND_ID) || \
    !defined(CPU5_COREMARK_BP_ENABLE) || !defined(CPU5_COREMARK_BTB_ENTRIES) || \
    !defined(CPU5_COREMARK_BP_CONFIG) || !defined(CPU5_COREMARK_CACHE_GEOMETRY) || \
    !defined(CPU5_COREMARK_STATS_SCHEMA) || !defined(CPU5_COREMARK_PROFILE_SCHEMA) || \
    !defined(CPU5_COREMARK_PROFILE_FIELDS) || !defined(CPU5_COREMARK_PROFILE_BITS) || \
    !defined(CPU5_COREMARK_WINDOW_BYTES) || !defined(CPU5_COREMARK_ENABLE_M)
#error "Use tools/build_cpu5_coremark_images.py for the CPU5 CoreMark port"
#endif
#if (CPU5_COREMARK_CACHE_ENABLE != 0 && CPU5_COREMARK_CACHE_ENABLE != 3) || \
    (CPU5_COREMARK_D0_BRAM != 0 && CPU5_COREMARK_D0_BRAM != 1) || \
    CPU5_COREMARK_BACKEND_ID != CPU5_COREMARK_D0_BRAM
#error "CPU5 CoreMark requires uniform I/D cache flags and a matching data backend id"
#endif
#if (CPU5_COREMARK_BP_ENABLE != 0 && CPU5_COREMARK_BP_ENABLE != 1) || \
    CPU5_COREMARK_BTB_ENTRIES < 1 || CPU5_COREMARK_BTB_ENTRIES > 1024 || \
    (CPU5_COREMARK_BTB_ENTRIES & (CPU5_COREMARK_BTB_ENTRIES - 1)) != 0 || \
    CPU5_COREMARK_BP_CONFIG != ((CPU5_COREMARK_BTB_ENTRIES << 16) | CPU5_COREMARK_BP_ENABLE)
#error "CPU5 CoreMark requires a power-of-two BTB that matches its configuration word"
#endif
#if CPU5_COREMARK_STATS_SCHEMA != 4 || CPU5_COREMARK_PROFILE_SCHEMA != 2 || \
    CPU5_COREMARK_PROFILE_FIELDS != 10 || CPU5_COREMARK_PROFILE_BITS != 64 || \
    CPU5_COREMARK_WINDOW_BYTES != 0x200
#error "CPU5 CoreMark requires schema4/profile2, ten 64-bit fields and a 0x200 window"
#endif
#if CPU5_COREMARK_ENABLE_M != 1
#error "CPU5 CoreMark firmware is built for RV32IM"
#endif

#define CPU5_COREMARK_STATS_BASE 0x30000000u
#define CPU5_COREMARK_STATS_ID   0x434d4158u
/* Sixteen snapshot words: four cycle/instret words, five I-Cache counters,
 * and seven D-Cache counters, all frozen on the same read edge. */
#define CPU5_COREMARK_START_BANK    0x40u
#define CPU5_COREMARK_STOP_BANK     0x80u
#define CPU5_COREMARK_BANK_WORDS    16u
#define CPU5_COREMARK_BP_START_BANK 0xc0u
#define CPU5_COREMARK_BP_STOP_BANK  0xe0u
#define CPU5_COREMARK_BP_BANK_WORDS 7u

static ee_u32 cpu5_coremark_read(ee_u32 offset)
{
    return *(volatile ee_u32 *)(ee_ptr_int)(CPU5_COREMARK_STATS_BASE + offset);
}

static ee_u64 cpu5_coremark_join(ee_u32 low, ee_u32 high)
{
    return ((ee_u64)high << 32) | low;
}

/* Fields 6..9 live in second banks; 0x130..13c and 0x170..17c stay holes. */
static ee_u32 cpu5_coremark_profile_offset(ee_u32 stop, ee_u32 field)
{
    if (field < 6u)
        return (stop ? 0x140u : 0x100u) + field * 8u;
    return (stop ? 0x1c0u : 0x180u) + (field - 6u) * 8u;
}

#endif
