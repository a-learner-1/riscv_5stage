#ifndef COREMARK_AXI_STATS_H
#define COREMARK_AXI_STATS_H

/* Generated metadata must describe the actual dedicated AXI hardware. */
#if !defined(COREMARK_PLATFORM_NAME) || !defined(COREMARK_ENABLE_ICACHE) || \
    !defined(COREMARK_ENABLE_DCACHE) || !defined(COREMARK_AXI_STATS_BASE) || \
    !defined(COREMARK_AXI_STATS_ID) || !defined(COREMARK_AXI_CACHE_GEOMETRY)
#error "Use build_coremark_axi.bat for the dedicated AXI CoreMark port"
#endif
#if (COREMARK_ENABLE_ICACHE != 0 && COREMARK_ENABLE_ICACHE != 1) || \
    (COREMARK_ENABLE_DCACHE != 0 && COREMARK_ENABLE_DCACHE != 1)
#error "Cache switches must be zero or one"
#endif

#define COREMARK_AXI_EXPECTED_FLAGS \
    (COREMARK_ENABLE_ICACHE | (COREMARK_ENABLE_DCACHE << 1))
#define COREMARK_AXI_START_BANK 0x40u
#define COREMARK_AXI_STOP_BANK  0x80u
#define COREMARK_AXI_BANK_WORDS 16u

static ee_u32 coremark_axi_read(ee_u32 offset)
{
    return *(volatile ee_u32 *)(ee_ptr_int)(COREMARK_AXI_STATS_BASE + offset);
}

static ee_u64 coremark_axi_join(ee_u32 low, ee_u32 high)
{
    return ((ee_u64)high << 32) | low;
}
#endif
