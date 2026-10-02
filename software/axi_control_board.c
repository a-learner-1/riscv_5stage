#include "axi_control.h"
#include "gpio.h"

#ifndef AXI_BOARD_BLINK_CYCLES
#define AXI_BOARD_BLINK_CYCLES 25000000u
#endif

/* Only this initialized data changes in the accelerated simulation image. */
static volatile uint32_t blink_cycles = AXI_BOARD_BLINK_CYCLES;
static volatile axi_u32 ram_guard = 0x12345678u;
static volatile axi_u32 observed[3];
static const axi_u32 operand_a[3] = {17u, 0xffffffffu, 0x7fffffffu};
static const axi_u32 operand_b[3] = {25u, 2u, 1u};
static const axi_u32 expected[3] = {42u, 1u, 0x80000000u};

static void put_string(const char *text)
{
    while (*text != '\0') mmio_putchar(*text++);
}

static void put_hex32(axi_u32 value)
{
    int shift;
    for (shift = 28; shift >= 0; shift -= 4) {
        axi_u32 digit = (value >> shift) & 15u;
        mmio_putchar((char)(digit < 10u ? '0' + digit : 'A' + digit - 10u));
    }
}

static void fail(axi_u32 error_code)
{
    gpio_write(4u);
    put_string("AXI CTRL FAIL ");
    put_hex32(error_code);
    put_string("\r\n");
    mmio_uart_flush();
    for (;;) {
    }
}

int main(void)
{
    axi_u32 job, poll, status, value;
    uint32_t phase = 0u;
    uint32_t last_toggle;
    gpio_write(0u);
    gpio_set_direction(7u);

    /* Error codes 2..8 identify each software self-test boundary. */
    if (ram_guard != 0x12345678u) fail(2u);
    if (axi_ctrl_read(AXI_CTRL_STATUS) != 0u ||
        axi_ctrl_read(AXI_CTRL_START_COUNT) != 0u) fail(3u);
    for (job = 0; job < 3; ++job) {
        axi_ctrl_write(AXI_CTRL_OPERAND_A, operand_a[job]);
        axi_ctrl_write(AXI_CTRL_OPERAND_B, operand_b[job]);
        axi_ctrl_write(AXI_CTRL_COMMAND, AXI_CTRL_START);
        for (poll = 0; poll < 4096; ++poll) {
            status = axi_ctrl_read(AXI_CTRL_STATUS);
            if ((status & AXI_CTRL_DONE) != 0u) break;
        }
        if (poll == 4096 || (status & AXI_CTRL_BUSY) != 0u) fail(4u);
        value = axi_ctrl_read(AXI_CTRL_RESULT);
        if (value != expected[job]) fail(5u);
        /* Reading a result must preserve DONE and the accepted START count. */
        if (axi_ctrl_read(AXI_CTRL_RESULT) != value ||
            axi_ctrl_read(AXI_CTRL_STATUS) != AXI_CTRL_DONE ||
            axi_ctrl_read(AXI_CTRL_START_COUNT) != job + 1u) fail(6u);
        observed[job] = value;
        axi_ctrl_write(AXI_CTRL_COMMAND, AXI_CTRL_CLEAR_DONE);
        if (axi_ctrl_read(AXI_CTRL_STATUS) != 0u) fail(7u);
    }
    if (ram_guard != 0x12345678u || observed[0] != 42u ||
        observed[1] != 1u || observed[2] != 0x80000000u) fail(8u);

    /* Print actual values read back from RAM, rather than expected literals. */
    put_string("AXI RESULTS ");
    for (job = 0; job < 3; ++job) {
        put_hex32(observed[job]);
        if (job != 2u) mmio_putchar(' ');
    }
    put_string("\r\nAXI CTRL PASS\r\n");
    mmio_uart_flush();
    gpio_write(2u);
    last_toggle = mmio_read_cycle();
    for (;;) {
        uint32_t now = mmio_read_cycle();
        if ((uint32_t)(now - last_toggle) >= blink_cycles) {
            phase ^= 1u;
            gpio_write(2u | phase);
            last_toggle = now;
        }
    }
}
