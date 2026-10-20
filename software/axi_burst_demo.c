#include "gpio.h"

/* CPU-commanded AXI4 read-channel demonstration; no CNN is connected. */
#define STATS_BASE 0x30000000u
#define CSR_BASE   0x30001000u
#define BUFFER0    0x40000040u
#define BUFFER1    0x40001040u
#define REG(offset) MMIO_REG32(CSR_BASE + (offset))
#define STAT(offset) MMIO_REG32(STATS_BASE + (offset))
#define DONE 2u
#define ERROR 4u

volatile uint32_t axi_burst_demo_status = 0u;
volatile uint32_t axi_burst_demo_checks = 0u;
volatile uint32_t axi_burst_demo_checksum = 0u;
volatile uint32_t axi_burst_demo_observed[4];
volatile uint32_t axi_burst_demo_scratch[32];
volatile uint32_t axi_burst_demo_guard = 0x13579bdfu;
volatile uint32_t axi_burst_demo_dcache_writes;
volatile uint32_t axi_burst_demo_dcache_hits;
volatile uint32_t axi_burst_demo_dcache_misses;

static void put_string(const char *text)
{
    while (*text) mmio_putchar(*text++);
}

static void put_hex(uint32_t value)
{
    int shift;
    for (shift = 28; shift >= 0; shift -= 4) {
        uint32_t digit = (value >> shift) & 15u;
        mmio_putchar((char)(digit < 10u ? '0' + digit : 'A' + digit - 10u));
    }
}

static int fail(uint32_t code)
{
    axi_burst_demo_status = code;
    gpio_write(4u);
    put_string("AXI4 READ BURST DEMO FAIL ");
    put_hex(code);
    put_string("\r\n");
    mmio_uart_flush();
    return (int)code;
}

static uint32_t seed(uint32_t address, uint32_t data, uint32_t strobe)
{
    uint32_t before = REG(0x2cu);
    REG(0x20u) = address;
    REG(0x24u) = data;
    REG(0x28u) = strobe;
    REG(0x2cu) = 1u;
    return REG(0x2cu) == before + 1u;
}

static uint32_t command(uint32_t address, uint32_t length,
                        uint32_t error_expected, const uint32_t *expected)
{
    uint32_t before_ar = REG(0x30u), before_r = REG(0x34u);
    uint32_t poll, status = 0u, beat;
    REG(0x04u) = address;
    REG(0x08u) = length;
    REG(0x00u) = 1u;
    for (poll = 0u; poll < 65536u; ++poll) {
        status = REG(0x00u);
        if (status & DONE) break;
    }
    if (poll == 65536u || (status & 1u) ||
        ((status & ERROR) != (error_expected ? ERROR : 0u))) return 0u;
    if (REG(0x0cu) != length + 1u || REG(0x30u) != before_ar + 1u ||
        REG(0x34u) != before_r + length + 1u) return 0u;
    for (beat = 0u; beat <= length; ++beat) {
        uint32_t value = REG(0x10u + 4u * beat);
        if (!error_expected && value != expected[beat]) return 0u;
        axi_burst_demo_observed[beat] = value;
        axi_burst_demo_checksum ^= value;
        if (REG(0x10u + 4u * beat) != value) return 0u;
    }
    if (REG(0x00u) != status) return 0u;
    axi_burst_demo_checks += 1u;
    return 1u;
}

int main(void)
{
    uint32_t i;
    static const uint32_t initial0[4] = {0x11223344u, 0x55667788u, 0x10203040u, 0x76543210u};
    static const uint32_t initial1[4] = {0x89abcdefu, 0x01234567u, 0x55aa00ffu, 0x0f1e2d3cu};
    static const uint32_t expected0[4] = {0x11aa3344u, 0x5566beefu, 0x10203040u, 0x76543210u};
    static const uint32_t expected1[4] = {0x8933cd77u, 0x01234567u, 0x55aa00ffu, 0xa51e5a3cu};

    gpio_write(0u);
    gpio_set_direction(7u);
    if (STAT(0x00u) != 0x434d4158u || STAT(0x08u) != 3u ||
        STAT(0x14u) != 0x00400001u || STAT(0x18u) != 3u || STAT(0x1cu) != 1u)
        return fail(2u);
    if (REG(0x38u) != 0x42525354u || REG(0x3cu) != 1u ||
        REG(0x00u) != 0u || REG(0x30u) != 0u || REG(0x34u) != 0u || REG(0x2cu) != 0u)
        return fail(3u);

    /* Exercise initialized data, stack, BSS and two-way D-Cache on D0 RAM. */
    if (axi_burst_demo_guard != 0x13579bdfu) return fail(4u);
    for (i = 0u; i < 32u; ++i) axi_burst_demo_scratch[i] = 0x2468ace0u ^ (i << 8) ^ i;
    for (i = 0u; i < 32u; ++i)
        if (axi_burst_demo_scratch[i] != (0x2468ace0u ^ (i << 8) ^ i)) return fail(5u);

    for (i = 0u; i < 4u; ++i) {
        if (!seed(BUFFER0 + 4u * i, initial0[i], 15u) ||
            !seed(BUFFER1 + 4u * i, initial1[i], 15u)) return fail(6u);
    }
    if (!seed(BUFFER0, 0x00aa0000u, 4u) ||
        !seed(BUFFER0 + 4u, 0x0000beefu, 3u) ||
        !seed(BUFFER1, 0x00330077u, 5u) ||
        !seed(BUFFER1 + 12u, 0xa5005a00u, 10u) || REG(0x2cu) != 12u) return fail(7u);

    if (!command(BUFFER0, 3u, 0u, expected0) || !command(BUFFER1, 3u, 0u, expected1) ||
        !command(BUFFER0 + 4u, 0u, 0u, expected0 + 1) ||
        !command(BUFFER1 + 8u, 0u, 0u, expected1 + 2)) return fail(8u);

    /* Product has no injected fault source. These commands exercise real
       decode/alignment/range errors; per-beat subordinate faults use the TB. */
    if (!command(BUFFER0 + 1u, 3u, 1u, expected0) || !command(BUFFER1, 3u, 0u, expected1)) return fail(9u);
    if (!command(0x50000000u, 3u, 1u, expected0) || !command(BUFFER0, 3u, 0u, expected0)) return fail(10u);
    if (!command(0x40000ff8u, 3u, 1u, expected0) || !command(BUFFER1, 3u, 0u, expected1)) return fail(11u);
    if (REG(0x30u) != 10u || REG(0x34u) != 34u || axi_burst_demo_checks != 10u) return fail(12u);
    REG(0x00u) = 2u;
    if (REG(0x00u) != 0u || REG(0x30u) != 10u || REG(0x34u) != 34u) return fail(13u);

    if (STAT(0x04u) != 0x434d4158u) return fail(14u);
    axi_burst_demo_dcache_writes = STAT(0xb8u) - STAT(0x78u);
    axi_burst_demo_dcache_hits = STAT(0xa8u) - STAT(0x68u);
    axi_burst_demo_dcache_misses = STAT(0xacu) - STAT(0x6cu);
    if (!axi_burst_demo_dcache_writes || !axi_burst_demo_dcache_hits || !axi_burst_demo_dcache_misses ||
        STAT(0xb4u) != STAT(0x74u) || axi_burst_demo_guard != 0x13579bdfu) return fail(15u);

    put_string("AXI4 DEMO AR="); put_hex(REG(0x30u));
    put_string(" R="); put_hex(REG(0x34u));
    put_string(" SEED="); put_hex(REG(0x2cu));
    put_string(" CHECKSUM="); put_hex(axi_burst_demo_checksum);
    put_string("\r\nD0 DCACHE WRITE="); put_hex(axi_burst_demo_dcache_writes);
    put_string(" HIT="); put_hex(axi_burst_demo_dcache_hits);
    put_string(" MISS="); put_hex(axi_burst_demo_dcache_misses);
    put_string("\r\nAXI4 READ BURST DEMO PASS\r\n");
    mmio_uart_flush();
    axi_burst_demo_status = 1u;
    gpio_write(2u);
    return 1;
}
