/* Reuse the original port in this translation unit so timing, formatting,
 * CRC validation and formal-score rules cannot diverge between platforms.
 * Only the timing boundary hooks and platform reporting are wrapped. */
#define start_time coremark_axi_base_start_time
#define stop_time coremark_axi_base_stop_time
#define portable_init coremark_axi_base_portable_init
#define portable_fini coremark_axi_base_portable_fini
#include "core_portme.c"
#undef start_time
#undef stop_time
#undef portable_init
#undef portable_fini
#include "coremark_axi_stats.h"

volatile ee_u32 coremark_axi_stats_valid;
volatile ee_u32 coremark_axi_mode_seen;
volatile ee_u32 coremark_axi_btb_mode_seen;
volatile ee_u32 coremark_axi_platform_failed;
volatile ee_u64 coremark_axi_cycle_delta;
volatile ee_u64 coremark_axi_instret_delta;
volatile ee_u32 coremark_axi_icache_delta[5];
volatile ee_u32 coremark_axi_dcache_delta[7];
volatile ee_u32 coremark_axi_btb_delta[COREMARK_AXI_BP_BANK_WORDS];
volatile ee_u32 coremark_axi_cycle_profile_valid;
volatile ee_u64 coremark_axi_cycle_profile_delta[COREMARK_AXI_CYCLE_PROFILE_FIELDS];
volatile ee_u64 coremark_axi_cycle_profile_sum;

void start_time(void)
{
    /* One MMIO read atomically freezes every START field. No array reads or
     * UART output occur between this marker and the STOP marker. */
    if (coremark_axi_read(0u) != COREMARK_AXI_STATS_ID)
        coremark_axi_platform_failed = coremark_failed = 1u;
    coremark_axi_base_start_time();
}

void stop_time(void)
{
    coremark_axi_base_stop_time();
    if (coremark_axi_read(4u) != COREMARK_AXI_STATS_ID)
        coremark_axi_platform_failed = coremark_failed = 1u;
}

void portable_init(core_portable *portable, int *argc, char *argv[])
{
    ee_u32 i;
    coremark_axi_base_portable_init(portable, argc, argv);
    coremark_axi_stats_valid = coremark_axi_platform_failed = 0u;
    coremark_axi_cycle_delta = coremark_axi_instret_delta = 0u;
    coremark_axi_cycle_profile_valid = 0u;
    coremark_axi_cycle_profile_sum = 0u;
    for (i = 0u; i < COREMARK_AXI_CYCLE_PROFILE_FIELDS; ++i)
        coremark_axi_cycle_profile_delta[i] = 0u;
    for (i = 0u; i < 5u; ++i) coremark_axi_icache_delta[i] = 0u;
    for (i = 0u; i < 7u; ++i) coremark_axi_dcache_delta[i] = 0u;
    for (i = 0u; i < COREMARK_AXI_BP_BANK_WORDS; ++i)
        coremark_axi_btb_delta[i] = 0u;
    coremark_axi_mode_seen = coremark_axi_read(8u);
    coremark_axi_btb_mode_seen = coremark_axi_read(20u);
    if (coremark_axi_read(0u) != COREMARK_AXI_STATS_ID ||
        coremark_axi_mode_seen != COREMARK_AXI_EXPECTED_FLAGS ||
        coremark_axi_read(12u) != COREMARK_AXI_CACHE_GEOMETRY ||
        coremark_axi_read(16u) != COREMARK_AXI_CACHE_GEOMETRY ||
        coremark_axi_btb_mode_seen != COREMARK_AXI_BP_CONFIG ||
        coremark_axi_read(24u) != COREMARK_AXI_STATS_SCHEMA ||
        sizeof(ee_u64) != 8u) {
        coremark_axi_platform_failed = coremark_failed = 1u;
        ee_printf("ERROR: AXI CoreMark hardware configuration mismatch\n");
    }
}

void portable_fini(core_portable *portable)
{
    ee_u32 first[COREMARK_AXI_BANK_WORDS], last[COREMARK_AXI_BANK_WORDS];
    ee_u32 i;
    ee_u64 profile_sum = 0u;
    static const char *const cycle_names[COREMARK_AXI_CYCLE_PROFILE_FIELDS] = {
        "work_other", "ifetch_wait", "data_read_wait", "data_write_wait",
        "local_mmio_wait", "redirect_wait"
    };
    for (i = 0u; i < COREMARK_AXI_BANK_WORDS; ++i) {
        first[i] = coremark_axi_read(COREMARK_AXI_START_BANK + 4u * i);
        last[i] = coremark_axi_read(COREMARK_AXI_STOP_BANK + 4u * i);
    }
    coremark_axi_cycle_delta = coremark_axi_join(last[0], last[1]) -
                              coremark_axi_join(first[0], first[1]);
    coremark_axi_instret_delta = coremark_axi_join(last[2], last[3]) -
                                coremark_axi_join(first[2], first[3]);
    /* Each Cache or BP counter advances at most once per cycle. Subtraction
     * therefore tolerates one low-word wrap, but not windows >= 2^32 cycles. */
    coremark_axi_stats_valid = !coremark_axi_platform_failed &&
        coremark_axi_cycle_delta > 0u &&
        coremark_axi_cycle_delta < ((ee_u64)1u << 32) &&
        coremark_axi_instret_delta > 0u;
    for (i = 0u; i < 5u; ++i)
        coremark_axi_icache_delta[i] = last[4u + i] - first[4u + i];
    for (i = 0u; i < 7u; ++i)
        coremark_axi_dcache_delta[i] = last[9u + i] - first[9u + i];
    for (i = 0u; i < COREMARK_AXI_BP_BANK_WORDS; ++i)
        coremark_axi_btb_delta[i] =
            coremark_axi_read(COREMARK_AXI_BP_STOP_BANK + 4u * i) -
            coremark_axi_read(COREMARK_AXI_BP_START_BANK + 4u * i);
    /* Each class is a 64-bit counter frozen by the SAME START/STOP reads as
     * cycle_count. Read the frozen banks only after stop_time, outside the
     * timed algorithm. A partition failure invalidates the entire platform
     * report; it must never be followed by a FORMAL PASS. */
    coremark_axi_cycle_profile_valid = coremark_axi_stats_valid;
    for (i = 0u; i < COREMARK_AXI_CYCLE_PROFILE_FIELDS; ++i) {
        ee_u32 offset = i * 8u;
        ee_u64 begin_count = coremark_axi_join(
            coremark_axi_read(COREMARK_AXI_CYCLE_PROFILE_START_BANK + offset),
            coremark_axi_read(COREMARK_AXI_CYCLE_PROFILE_START_BANK + offset + 4u));
        ee_u64 end_count = coremark_axi_join(
            coremark_axi_read(COREMARK_AXI_CYCLE_PROFILE_STOP_BANK + offset),
            coremark_axi_read(COREMARK_AXI_CYCLE_PROFILE_STOP_BANK + offset + 4u));
        ee_u64 delta = end_count - begin_count;
        ee_u64 next_sum = profile_sum + delta;
        coremark_axi_cycle_profile_delta[i] = delta;
        if (delta > coremark_axi_cycle_delta || next_sum < profile_sum)
            coremark_axi_cycle_profile_valid = 0u;
        profile_sum = next_sum;
    }
    coremark_axi_cycle_profile_sum = profile_sum;
    if (profile_sum != coremark_axi_cycle_delta)
        coremark_axi_cycle_profile_valid = 0u;
    if (!coremark_axi_cycle_profile_valid) {
        coremark_axi_stats_valid = 0u;
        coremark_axi_platform_failed = coremark_failed = 1u;
        ee_printf("ERROR: AXI CoreMark cycle profile partition mismatch\n");
    }
    if (coremark_axi_platform_failed) coremark_failed = 1u;

    ee_printf("COREMARK platform=%s\n", COREMARK_PLATFORM_NAME);
    ee_printf("COREMARK cache_enable=%u\n", coremark_axi_mode_seen);
    ee_printf("COREMARK branch_pred_enable=%u\n", COREMARK_ENABLE_BRANCH_PRED);
    ee_printf("COREMARK btb_entries=%u\n", COREMARK_BTB_ENTRIES);
    ee_printf("COREMARK btb_config=%u\n", coremark_axi_btb_mode_seen);
    ee_printf("COREMARK counter_window=START-before-mtime;STOP-after-mtime;includes-boundary-overhead\n");
    ee_printf("COREMARK counter_valid=%u\n", coremark_axi_stats_valid);
    ee_printf("COREMARK counter_cycles=%llu\n", coremark_axi_cycle_delta);
    ee_printf("COREMARK counter_retired=%llu\n", coremark_axi_instret_delta);
    if (coremark_axi_stats_valid)
        ee_printf("COREMARK counter_cpi=%.9f\n",
                  (double)coremark_axi_cycle_delta / (double)coremark_axi_instret_delta);
    else
        ee_printf("COREMARK counter_cpi=unavailable\n");
    ee_printf("COREMARK cycle_profile_schema=%u\n", COREMARK_AXI_CYCLE_PROFILE_SCHEMA);
    ee_printf("COREMARK cycle_profile_valid=%u\n", coremark_axi_cycle_profile_valid);
    for (i = 0u; i < COREMARK_AXI_CYCLE_PROFILE_FIELDS; ++i)
        ee_printf("COREMARK cycle_%s=%llu\n", cycle_names[i],
                  coremark_axi_cycle_profile_delta[i]);
    ee_printf("COREMARK cycle_profile_sum=%llu\n", coremark_axi_cycle_profile_sum);
    ee_printf("COREMARK icache_access=%u\n", coremark_axi_icache_delta[0]);
    ee_printf("COREMARK icache_hit=%u\n", coremark_axi_icache_delta[1]);
    ee_printf("COREMARK icache_miss=%u\n", coremark_axi_icache_delta[2]);
    ee_printf("COREMARK icache_refill_words=%u\n", coremark_axi_icache_delta[3]);
    ee_printf("COREMARK icache_errors=%u\n", coremark_axi_icache_delta[4]);
    ee_printf("COREMARK dcache_access=%u\n", coremark_axi_dcache_delta[0]);
    ee_printf("COREMARK dcache_hit=%u\n", coremark_axi_dcache_delta[1]);
    ee_printf("COREMARK dcache_miss=%u\n", coremark_axi_dcache_delta[2]);
    ee_printf("COREMARK dcache_refill_words=%u\n", coremark_axi_dcache_delta[3]);
    ee_printf("COREMARK dcache_errors=%u\n", coremark_axi_dcache_delta[4]);
    ee_printf("COREMARK dcache_write=%u\n", coremark_axi_dcache_delta[5]);
    ee_printf("COREMARK dcache_bypass=%u\n", coremark_axi_dcache_delta[6]);
    ee_printf("COREMARK bp_lookup=%u\n", coremark_axi_btb_delta[0]);
    ee_printf("COREMARK bp_hit=%u\n", coremark_axi_btb_delta[1]);
    ee_printf("COREMARK bp_predicted_taken=%u\n", coremark_axi_btb_delta[2]);
    ee_printf("COREMARK bp_resolved=%u\n", coremark_axi_btb_delta[3]);
    ee_printf("COREMARK bp_next_pc_mismatch=%u\n", coremark_axi_btb_delta[4]);
    ee_printf("COREMARK bp_direction_error=%u\n", coremark_axi_btb_delta[5]);
    ee_printf("COREMARK bp_target_error=%u\n", coremark_axi_btb_delta[6]);
    /* Fetch lookups include requests later flushed. Next-PC mismatches include
     * JALR and stale ordinary-instruction predictions, while resolved counts
     * only branches/JAL: their quotient is not a branch misprediction rate. */
    ee_printf("COREMARK cache_state=%s\n", ITERATIONS == 0
              ? "automatic-calibration-warmed;no-explicit-flush"
              : "fixed-iterations;no-explicit-flush");
    ee_printf("COREMARK predictor_state=%s\n", COREMARK_ENABLE_BRANCH_PRED == 0
              ? "disabled" : (ITERATIONS == 0
              ? "automatic-calibration-trained;no-explicit-reset"
              : "fixed-iterations;no-explicit-reset"));
    /* The original fini prints the original timing/CRC fields, validates the
     * score, flushes UART, and writes tohost only after this extra report. */
    coremark_axi_base_portable_fini(portable);
}
