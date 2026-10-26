/* CPU5 CoreMark port. Reuse the original port in this translation unit so the
 * timing, formatting, CRC validation and formal-score rules cannot diverge
 * between platforms; only the timing boundary and the schema4 platform report
 * are wrapped.
 *
 * CPU5 statistics contract: schema4 exposes ten exclusive 64-bit cycle classes
 * and a START/STOP snapshot bank pair frozen by the same AXI read edge as
 * cycle_count/instret_count. The window relation is one-directional: the mtime
 * interval lives strictly inside the statistics interval because start_time
 * reads the START bank before the timer and stop_time reads the timer before
 * the STOP bank. */
#define start_time cpu5_coremark_base_start_time
#define stop_time cpu5_coremark_base_stop_time
#define portable_init cpu5_coremark_base_portable_init
#define portable_fini cpu5_coremark_base_portable_fini
#include "core_portme.c"
#undef start_time
#undef stop_time
#undef portable_init
#undef portable_fini
#include "coremark_cpu5_stats.h"

/* Bounded slack allowed between the mtime interval and the enclosing
 * statistics interval: two Local-MMIO snapshots, the coherent 64-bit mtime
 * read (high/low/high) and the retirement of both marker instructions. */
#define CPU5_COREMARK_MAX_TICK_GAP 256u

volatile ee_u32 cpu5_coremark_platform_failed;
volatile ee_u32 cpu5_coremark_stats_valid;
volatile ee_u32 cpu5_coremark_cycle_profile_valid;
volatile ee_u32 cpu5_coremark_mode_seen;
volatile ee_u32 cpu5_coremark_bp_mode_seen;
volatile ee_u32 cpu5_coremark_backend_seen;
volatile ee_u32 cpu5_coremark_schema_seen;
volatile ee_u64 cpu5_coremark_cycle_delta;
volatile ee_u64 cpu5_coremark_instret_delta;
volatile ee_u64 cpu5_coremark_cycle_profile_sum;
volatile ee_u64 cpu5_coremark_tick_gap;
volatile ee_u64 cpu5_coremark_cycle_profile_delta[CPU5_COREMARK_PROFILE_FIELDS];
volatile ee_u32 cpu5_coremark_icache_delta[5];
volatile ee_u32 cpu5_coremark_dcache_delta[7];
volatile ee_u32 cpu5_coremark_btb_delta[CPU5_COREMARK_BP_BANK_WORDS];

static const char *const cpu5_coremark_cycle_names[CPU5_COREMARK_PROFILE_FIELDS] = {
    "work_other", "ifetch_wait", "data_read_wait", "data_write_wait",
    "local_mmio_wait", "redirect_wait", "mul_wait", "div_wait",
    "load_use_wait", "id_hazard_wait"
};

static void cpu5_coremark_fail(void)
{
    cpu5_coremark_platform_failed = coremark_failed = 1u;
}

void start_time(void)
{
    /* One MMIO read atomically freezes every START field. Nothing but the
     * enclosing timer read happens between this marker and the STOP marker. */
    if (cpu5_coremark_read(0u) != CPU5_COREMARK_STATS_ID)
        cpu5_coremark_fail();
    cpu5_coremark_base_start_time();
}

void stop_time(void)
{
    cpu5_coremark_base_stop_time();
    if (cpu5_coremark_read(4u) != CPU5_COREMARK_STATS_ID)
        cpu5_coremark_fail();
}

void portable_init(core_portable *portable, int *argc, char *argv[])
{
    ee_u32 i;
    cpu5_coremark_base_portable_init(portable, argc, argv);
    cpu5_coremark_platform_failed = 0u;
    cpu5_coremark_stats_valid = 0u;
    cpu5_coremark_cycle_profile_valid = 0u;
    cpu5_coremark_cycle_delta = 0u;
    cpu5_coremark_instret_delta = 0u;
    cpu5_coremark_cycle_profile_sum = 0u;
    cpu5_coremark_tick_gap = 0u;
    for (i = 0u; i < CPU5_COREMARK_PROFILE_FIELDS; ++i)
        cpu5_coremark_cycle_profile_delta[i] = 0u;
    for (i = 0u; i < 5u; ++i) cpu5_coremark_icache_delta[i] = 0u;
    for (i = 0u; i < 7u; ++i) cpu5_coremark_dcache_delta[i] = 0u;
    for (i = 0u; i < CPU5_COREMARK_BP_BANK_WORDS; ++i)
        cpu5_coremark_btb_delta[i] = 0u;
    /* These probes are outside the measured window: they only prove that the
     * image is paired with the hardware it was built for. Reading word 0 also
     * freezes a START bank, and it is the only snapshot trigger this port
     * performs outside the window: the measured window then keeps exactly two
     * START edges (probe, start_time) and one STOP edge (stop_time). */
    cpu5_coremark_mode_seen = cpu5_coremark_read(8u);
    cpu5_coremark_bp_mode_seen = cpu5_coremark_read(20u);
    cpu5_coremark_schema_seen = cpu5_coremark_read(24u);
    cpu5_coremark_backend_seen = 0u;
    if (cpu5_coremark_read(0u) != CPU5_COREMARK_STATS_ID ||
        cpu5_coremark_mode_seen != CPU5_COREMARK_CACHE_ENABLE ||
        cpu5_coremark_read(12u) != CPU5_COREMARK_CACHE_GEOMETRY ||
        cpu5_coremark_read(16u) != CPU5_COREMARK_CACHE_GEOMETRY ||
        cpu5_coremark_bp_mode_seen != CPU5_COREMARK_BP_CONFIG ||
        cpu5_coremark_schema_seen != CPU5_COREMARK_STATS_SCHEMA ||
        sizeof(ee_u64) != 8u || sizeof(double) != 8u) {
        cpu5_coremark_fail();
        ee_printf("ERROR: CPU5 CoreMark hardware configuration mismatch\n");
    }
    /* The backend identity word distinguishes the two data paths and is read in
     * BOTH directions. Checking it only for D0 images would let an AXI image run
     * on D0 hardware (or the reverse) and still report a pass, because the same
     * program image is loaded into whichever backend the top wires up. */
    cpu5_coremark_backend_seen = cpu5_coremark_read(28u);
    if (cpu5_coremark_backend_seen != CPU5_COREMARK_BACKEND_ID) {
        cpu5_coremark_fail();
        ee_printf("ERROR: CPU5 CoreMark data backend mismatch\n");
    }
}

void portable_fini(core_portable *portable)
{
    ee_u32 first[CPU5_COREMARK_BANK_WORDS], last[CPU5_COREMARK_BANK_WORDS];
    ee_u32 i;
    ee_u64 profile_sum = 0u;
    for (i = 0u; i < CPU5_COREMARK_BANK_WORDS; ++i) {
        first[i] = cpu5_coremark_read(CPU5_COREMARK_START_BANK + 4u * i);
        last[i] = cpu5_coremark_read(CPU5_COREMARK_STOP_BANK + 4u * i);
    }
    cpu5_coremark_cycle_delta = cpu5_coremark_join(last[0], last[1]) -
                               cpu5_coremark_join(first[0], first[1]);
    cpu5_coremark_instret_delta = cpu5_coremark_join(last[2], last[3]) -
                                 cpu5_coremark_join(first[2], first[3]);
    /* Every Cache or BP counter advances at most once per cycle, so a 32-bit
     * difference tolerates one low-word wrap but never a window >= 2^32. */
    cpu5_coremark_stats_valid = !cpu5_coremark_platform_failed &&
        cpu5_coremark_cycle_delta > 0u &&
        cpu5_coremark_cycle_delta < ((ee_u64)1u << 32) &&
        cpu5_coremark_instret_delta > 0u;
    for (i = 0u; i < 5u; ++i)
        cpu5_coremark_icache_delta[i] = last[4u + i] - first[4u + i];
    for (i = 0u; i < 7u; ++i)
        cpu5_coremark_dcache_delta[i] = last[9u + i] - first[9u + i];
    for (i = 0u; i < CPU5_COREMARK_BP_BANK_WORDS; ++i)
        cpu5_coremark_btb_delta[i] =
            cpu5_coremark_read(CPU5_COREMARK_BP_STOP_BANK + 4u * i) -
            cpu5_coremark_read(CPU5_COREMARK_BP_START_BANK + 4u * i);
    cpu5_coremark_cycle_profile_valid = cpu5_coremark_stats_valid;
    for (i = 0u; i < CPU5_COREMARK_PROFILE_FIELDS; ++i) {
        ee_u32 offset = cpu5_coremark_profile_offset(0u, i);
        ee_u64 begin_count = cpu5_coremark_join(
            cpu5_coremark_read(offset), cpu5_coremark_read(offset + 4u));
        ee_u64 end_offset = cpu5_coremark_profile_offset(1u, i);
        ee_u64 end_count = cpu5_coremark_join(
            cpu5_coremark_read(end_offset), cpu5_coremark_read(end_offset + 4u));
        ee_u64 delta = end_count - begin_count;
        ee_u64 next_sum = profile_sum + delta;
        cpu5_coremark_cycle_profile_delta[i] = delta;
        if (delta > cpu5_coremark_cycle_delta || next_sum < profile_sum)
            cpu5_coremark_cycle_profile_valid = 0u;
        profile_sum = next_sum;
    }
    cpu5_coremark_cycle_profile_sum = profile_sum;
    if (profile_sum != cpu5_coremark_cycle_delta)
        cpu5_coremark_cycle_profile_valid = 0u;
    /* The mtime interval is strictly inside the statistics interval. The gap
     * is two Local-MMIO markers plus the coherent 64-bit timer read, so it is
     * nonzero but bounded; a wider gap means the window is not the algorithm. */
    if (coremark_elapsed_ticks == 0u ||
        coremark_elapsed_ticks > cpu5_coremark_cycle_delta ||
        cpu5_coremark_cycle_delta - coremark_elapsed_ticks >
            (ee_u64)CPU5_COREMARK_MAX_TICK_GAP)
        cpu5_coremark_cycle_profile_valid = 0u;
    else
        cpu5_coremark_tick_gap = cpu5_coremark_cycle_delta - coremark_elapsed_ticks;
    if (!cpu5_coremark_cycle_profile_valid) {
        cpu5_coremark_stats_valid = 0u;
        cpu5_coremark_fail();
        ee_printf("ERROR: CPU5 CoreMark cycle profile partition mismatch\n");
    }

    ee_printf("COREMARK platform=%s\n", CPU5_COREMARK_PLATFORM_NAME);
    ee_printf("COREMARK isa=rv32im\n");
    ee_printf("COREMARK data_backend=%s\n", CPU5_COREMARK_D0_BRAM ? "bram" : "axi");
    ee_printf("COREMARK backend_id=%u\n", cpu5_coremark_backend_seen);
    ee_printf("COREMARK cache_enable=%u\n", cpu5_coremark_mode_seen);
    ee_printf("COREMARK cache_geometry=%u\n", cpu5_coremark_read(12u));
    ee_printf("COREMARK branch_pred_enable=%u\n", CPU5_COREMARK_BP_ENABLE);
    ee_printf("COREMARK btb_entries=%u\n", CPU5_COREMARK_BTB_ENTRIES);
    ee_printf("COREMARK btb_config=%u\n", cpu5_coremark_bp_mode_seen);
    ee_printf("COREMARK stats_schema=%u\n", cpu5_coremark_schema_seen);
    ee_printf("COREMARK cycle_profile_schema=%u\n", CPU5_COREMARK_PROFILE_SCHEMA);
    ee_printf("COREMARK counter_window=START-before-mtime;STOP-after-mtime;includes-boundary-overhead\n");
    ee_printf("COREMARK counter_valid=%u\n", cpu5_coremark_stats_valid);
    ee_printf("COREMARK counter_cycles=%llu\n", cpu5_coremark_cycle_delta);
    ee_printf("COREMARK counter_retired=%llu\n", cpu5_coremark_instret_delta);
    if (cpu5_coremark_stats_valid)
        ee_printf("COREMARK counter_cpi=%.9f\n",
                  (double)cpu5_coremark_cycle_delta / (double)cpu5_coremark_instret_delta);
    else
        ee_printf("COREMARK counter_cpi=unavailable\n");
    ee_printf("COREMARK cycle_profile_valid=%u\n", cpu5_coremark_cycle_profile_valid);
    for (i = 0u; i < CPU5_COREMARK_PROFILE_FIELDS; ++i)
        ee_printf("COREMARK cycle_%s=%llu\n", cpu5_coremark_cycle_names[i],
                  cpu5_coremark_cycle_profile_delta[i]);
    ee_printf("COREMARK cycle_profile_sum=%llu\n", cpu5_coremark_cycle_profile_sum);
    ee_printf("COREMARK window_tick_gap=%llu\n", cpu5_coremark_tick_gap);
    ee_printf("COREMARK icache_access=%u\n", cpu5_coremark_icache_delta[0]);
    ee_printf("COREMARK icache_hit=%u\n", cpu5_coremark_icache_delta[1]);
    ee_printf("COREMARK icache_miss=%u\n", cpu5_coremark_icache_delta[2]);
    ee_printf("COREMARK icache_refill_words=%u\n", cpu5_coremark_icache_delta[3]);
    ee_printf("COREMARK icache_errors=%u\n", cpu5_coremark_icache_delta[4]);
    ee_printf("COREMARK dcache_access=%u\n", cpu5_coremark_dcache_delta[0]);
    ee_printf("COREMARK dcache_hit=%u\n", cpu5_coremark_dcache_delta[1]);
    ee_printf("COREMARK dcache_miss=%u\n", cpu5_coremark_dcache_delta[2]);
    ee_printf("COREMARK dcache_refill_words=%u\n", cpu5_coremark_dcache_delta[3]);
    ee_printf("COREMARK dcache_errors=%u\n", cpu5_coremark_dcache_delta[4]);
    ee_printf("COREMARK dcache_write=%u\n", cpu5_coremark_dcache_delta[5]);
    ee_printf("COREMARK dcache_bypass=%u\n", cpu5_coremark_dcache_delta[6]);
    ee_printf("COREMARK bp_lookup=%u\n", cpu5_coremark_btb_delta[0]);
    ee_printf("COREMARK bp_hit=%u\n", cpu5_coremark_btb_delta[1]);
    ee_printf("COREMARK bp_predicted_taken=%u\n", cpu5_coremark_btb_delta[2]);
    ee_printf("COREMARK bp_resolved=%u\n", cpu5_coremark_btb_delta[3]);
    ee_printf("COREMARK bp_next_pc_mismatch=%u\n", cpu5_coremark_btb_delta[4]);
    ee_printf("COREMARK bp_direction_error=%u\n", cpu5_coremark_btb_delta[5]);
    ee_printf("COREMARK bp_target_error=%u\n", cpu5_coremark_btb_delta[6]);
    /* Fetch lookups include requests later flushed, and next-PC mismatches
     * include JALR and stale ordinary-instruction predictions; their quotient
     * is not a branch misprediction rate. */
    ee_printf("COREMARK cache_state=%s\n", ITERATIONS == 0
              ? "automatic-calibration-warmed;no-explicit-flush"
              : "fixed-iterations;no-explicit-flush");
    ee_printf("COREMARK predictor_state=%s\n", CPU5_COREMARK_BP_ENABLE == 0
              ? "disabled" : (ITERATIONS == 0
              ? "automatic-calibration-trained;no-explicit-reset"
              : "fixed-iterations;no-explicit-reset"));
    /* The original fini prints the original timing/CRC fields, validates the
     * run, flushes UART, and writes tohost only after this extra report. */
    cpu5_coremark_base_portable_fini(portable);
}
