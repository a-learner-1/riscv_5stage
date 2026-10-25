#ifndef CPU5_STATS_H
#define CPU5_STATS_H
/* Independent CPU5 schema4/profile2 ABI. The original CoreMark header stays
 * schema3/profile1 and must reject these generated configuration values. */
#if !defined(CPU5_STATS_HW_SCHEMA) || !defined(CPU5_STATS_PROFILE_SCHEMA) || \
    !defined(CPU5_STATS_FIELDS) || !defined(CPU5_STATS_COUNTER_BITS) || \
    !defined(CPU5_STATS_WINDOW_BYTES)
#error "CPU5 Stats requires an explicit generated ABI configuration"
#endif
#if CPU5_STATS_HW_SCHEMA != 4 || CPU5_STATS_PROFILE_SCHEMA != 2 || \
    CPU5_STATS_FIELDS != 10 || CPU5_STATS_COUNTER_BITS != 64 || \
    CPU5_STATS_WINDOW_BYTES != 0x200
#error "CPU5 Stats requires schema4/profile2/ten 64-bit fields/0x200 window"
#endif
typedef unsigned int cpu5_stats_u32;
typedef unsigned long long cpu5_stats_u64;
#define CPU5_STATS_BASE 0x30000000u
#define CPU5_STATS_ID 0x434d4158u

static inline cpu5_stats_u32 cpu5_stats_read(cpu5_stats_u32 offset)
{
    return *(volatile cpu5_stats_u32 *)(CPU5_STATS_BASE + offset);
}
static inline cpu5_stats_u32 cpu5_stats_profile_offset(cpu5_stats_u32 stop,
                                                     cpu5_stats_u32 field)
{
    /* Fields 6..9 occupy separate banks. 0x130..13c/0x170..17c stay holes. */
    if (field < 6u)
        return (stop ? 0x140u : 0x100u) + field * 8u;
    return (stop ? 0x1c0u : 0x180u) + (field - 6u) * 8u;
}
static inline cpu5_stats_u64 cpu5_stats_join(cpu5_stats_u32 low,
                                          cpu5_stats_u32 high)
{
    return ((cpu5_stats_u64)high << 32) | low;
}
static inline cpu5_stats_u64 cpu5_stats_read64(cpu5_stats_u32 offset)
{
    cpu5_stats_u32 low=cpu5_stats_read(offset);
    cpu5_stats_u32 high=cpu5_stats_read(offset+4u);
    return cpu5_stats_join(low,high);
}
#endif
