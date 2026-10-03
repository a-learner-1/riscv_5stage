/* Test-only firmware. Scripted mtime is not benchmark timing evidence. */
#include "coremark.h"
#include "port_test_io.h"
#undef mmio_putchar
#undef mmio_uart_flush

static uint32_t sequence_addr[12], sequence_value[12], sequence_count, sequence_index;
static uint32_t read_value, mock_tohost;
static char output[4096];
static uint32_t output_len;
volatile uint32_t coremark_math_cases;
volatile uint32_t coremark_math_failure;

static void fixture_puts(const char *text) {
    while (*text) mmio_putchar(*text++);
}
static void fail(uint32_t code) {
    coremark_math_failure = code;
    fixture_puts("COREMARK PORT TEST FAIL\n");
    mmio_uart_flush();
    *(volatile uint32_t *)0x00013ffcu = 2u;
    for (;;) { }
}
#define CHECK(condition, code) do { if (!(condition)) fail(code); } while (0)
uint32_t *coremark_test_reg(uint32_t address) {
    CHECK(sequence_index < sequence_count, 1);
    CHECK(address == sequence_addr[sequence_index], 2);
    read_value = sequence_value[sequence_index++];
    return &read_value;
}
void coremark_test_putchar(char c) {
    CHECK(output_len + 1u < sizeof(output), 3);
    output[output_len++] = c;
    output[output_len] = '\0';
}
void coremark_test_flush(void) { }
void coremark_test_tohost(uint32_t value) { mock_tohost = value; }
static int contains(const char *text) {
    uint32_t i, j;
    for (i = 0; i < output_len; ++i) {
        for (j = 0; text[j] && output[i+j] == text[j]; ++j) { }
        if (!text[j]) return 1;
    }
    return 0;
}
static void push(uint32_t addr, uint32_t value) {
    CHECK(sequence_count < 12, 4);
    sequence_addr[sequence_count] = addr;
    sequence_value[sequence_count++] = value;
}
static void consistent(CORE_TICKS value) {
    push(MMIO_MTIME_HI_ADDR, (uint32_t)(value >> 32));
    push(MMIO_MTIME_LO_ADDR, (uint32_t)value);
    push(MMIO_MTIME_HI_ADDR, (uint32_t)(value >> 32));
}
static void begin(CORE_TICKS elapsed) {
    core_portable portable;
    int argc = 0;
    char *argv[1] = {0};
    output_len = 0;
    output[0] = '\0';
    mock_tohost = 0;
    portable_init(&portable, &argc, argv);
    sequence_count = sequence_index = 0;
    consistent(0x00000000fffffff0ULL);
    consistent(0x00000000fffffff0ULL + elapsed);
    start_time();
    stop_time();
    CHECK(sequence_index == 6, 5);
    CHECK(get_time() == elapsed, 6);
}
static void report(int bad_crc, int unknown_seed) {
    ee_printf("Total ticks      : %lu\n", (unsigned long)get_time());
    ee_printf("Total time (secs): %f\n", time_in_secs(get_time()));
    ee_printf("Iterations       : %lu\n", (unsigned long)123);
    ee_printf("seedcrc          : 0x%04x\n", unknown_seed ? 0x1111 : 0xe9f5);
    ee_printf("[%d]crclist       : 0x%04x\n", 0, bad_crc ? 0x1234 : 0xe714);
    ee_printf("[%d]crcmatrix     : 0x%04x\n", 0, 0x1fd7);
    ee_printf("[%d]crcstate      : 0x%04x\n", 0, 0x8e3a);
}
static void finish(void) {
    core_portable portable;
    portable.portable_id = 1;
    portable_fini(&portable);
}
int main(void) {
    CORE_TICKS elapsed;
    secs_ret seconds;
    /* A low word wraps between LO and the second HI. It must retry. */
    sequence_count = sequence_index = 0;
    push(MMIO_MTIME_HI_ADDR, 0);
    push(MMIO_MTIME_LO_ADDR, 0xffffffffu);
    push(MMIO_MTIME_HI_ADDR, 1);
    consistent(0x0000000100000042ULL);
    CHECK(timer_read_time() == 0x0000000100000042ULL, 10);
    CHECK(sequence_index == 6, 11);
    ++coremark_math_cases;

    elapsed = (CORE_TICKS)COREMARK_CLOCK_HZ / 8u;
    begin(elapsed);
    CHECK(sizeof(CORE_TICKS) == 8, 20);
    seconds = time_in_secs(elapsed);
    CHECK(seconds > 0.124999 && seconds < 0.125001, 21);
    report(0, 0);
    ee_printf("ERROR! Must execute for at least 10 secs for a valid result!\n");
    ee_printf("Errors detected\n");
    finish();
    CHECK(mock_tohost == (COREMARK_FORMAL ? 2u : 1u), 22);
    CHECK(contains("Total time (secs): 0.125000"), 23);
    ++coremark_math_cases;

    elapsed = 0x100000001ULL;
    begin(elapsed);
    CHECK(get_time() > 0xffffffffULL, 30);
    CHECK(time_in_secs(elapsed) > 42.9, 31);
    report(0, 0);
    ee_printf("Correct operation validated. See readme.txt for run and reporting rules.\n");
    finish();
    CHECK(mock_tohost == 1u, 32);
    CHECK(contains("4294967297"), 33);
    CHECK(coremark_elapsed_ticks == elapsed, 34);
    CHECK(coremark_actual_iterations == 123, 35);
    ++coremark_math_cases;

    begin((CORE_TICKS)COREMARK_CLOCK_HZ * 12u);
    report(1, 0);
    ee_printf("[%u]ERROR! list crc 0x%04x - should be 0x%04x\n", 0u, 0x1234u, 0xe714u);
    ee_printf("Correct operation validated. See readme.txt for run and reporting rules.\n");
    finish();
    CHECK(mock_tohost == 2u, 40);
    ++coremark_math_cases;

    begin((CORE_TICKS)COREMARK_CLOCK_HZ * 12u);
    report(0, 1);
    ee_printf("Cannot validate operation for these seed values, please compare with results on a known platform.\n");
    finish();
    CHECK(mock_tohost == 2u, 50);
    ++coremark_math_cases;

    begin((CORE_TICKS)COREMARK_CLOCK_HZ * 12u);
    /* Missing CRC/report must never pass. */
    ee_printf("Correct operation validated. See readme.txt for run and reporting rules.\n");
    finish();
    CHECK(mock_tohost == 2u, 60);
    ++coremark_math_cases;

    begin((CORE_TICKS)COREMARK_CLOCK_HZ * 12u);
    report(0, 0);
    ee_printf("ERROR: datatype validation failure\n");
    finish();
    CHECK(mock_tohost == 2u, 70);
    ++coremark_math_cases;

    begin((CORE_TICKS)COREMARK_CLOCK_HZ * 12u);
    ee_printf("FORMAT %.3f %llu %08x\n", 1.25, 0x100000001ULL, 0x42u);
    CHECK(contains("FORMAT 1.250 4294967297 00000042"), 80);
    ee_printf("LIMITS %llu %lld %.3f %.0f %.6f\n", 0xffffffffffffffffULL,
              (-9223372036854775807LL - 1LL), -1.25, 1.5, 0.9999999);
    CHECK(contains("LIMITS 18446744073709551615 -9223372036854775808 -1.250 2 1.000000"), 81);
    ++coremark_math_cases;

    /* Zero elapsed time is a hard failure even for smoke. */
    begin(0);
    report(0, 0);
    finish();
    CHECK(mock_tohost == 2u, 90);
    ++coremark_math_cases;

    begin((CORE_TICKS)COREMARK_CLOCK_HZ * 10u - 1u);
    report(0, 0);
    ee_printf("Correct operation validated. See readme.txt for run and reporting rules.\n");
    finish();
    CHECK(mock_tohost == (COREMARK_FORMAL ? 2u : 1u), 100);
    ++coremark_math_cases;

    begin((CORE_TICKS)COREMARK_CLOCK_HZ * 10u);
    report(0, 0);
    ee_printf("Correct operation validated. See readme.txt for run and reporting rules.\n");
    finish();
    CHECK(mock_tohost == 1u, 110);
    ++coremark_math_cases;

    begin((CORE_TICKS)COREMARK_CLOCK_HZ * 12u);
    report(0, 0);
    { union { double number; CORE_TICKS bits; } invalid;
      invalid.bits = 0x7ff8000000000000ULL;
      ee_printf("INVALID %f\n", invalid.number); }
    ee_printf("Correct operation validated. See readme.txt for run and reporting rules.\n");
    finish();
    CHECK(mock_tohost == 2u, 120);
    ++coremark_math_cases;

    begin((CORE_TICKS)COREMARK_CLOCK_HZ * 12u);
    report(0, 0);
    ee_printf("INVALID %f\n", 1.0e20);
    ee_printf("Correct operation validated. See readme.txt for run and reporting rules.\n");
    finish();
    CHECK(mock_tohost == 2u, 130);
    ++coremark_math_cases;

    fixture_puts("COREMARK PORT TEST PASS (MOCK TIMING, NO SCORE)\n");
    mmio_uart_flush();
    *(volatile uint32_t *)0x00013ffcu = 1u;
    return 0;
}
