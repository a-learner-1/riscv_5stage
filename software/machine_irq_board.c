/* Independent MES50HP machine external/software/timer IRQ acceptance.
 * GPIO bit1=PASS, bit0=heartbeat, bit2=FAIL. KEY1 restarts via start.S.
 * This source has not been compiled, simulated or tested on hardware. */
#include "machine_irq.h"
#include "gpio.h"
typedef unsigned int u32;
#define IRQ_EXPECTED 8u
#define WORK_COUNT 2048u
#define WORK_SEED 0x13579bdfu
#define WORK_EXPECT 0x569ea33cu
#define TIMEOUT_CYCLES 1000000u
#ifndef MACHINE_IRQ_BOARD_BLINK_CYCLES
#define MACHINE_IRQ_BOARD_BLINK_CYCLES 25000000u
#endif

extern void machine_irq_entry(void);
extern volatile u32 tohost;
volatile u32 machine_irq_blink_cycles = MACHINE_IRQ_BOARD_BLINK_CYCLES;
volatile u32 machine_irq_guard = 0x12345678u;
volatile u32 machine_irq_done, machine_irq_failed;
volatile u32 machine_irq_external_count, machine_irq_software_count, machine_irq_timer_count;
volatile u32 machine_irq_order[IRQ_EXPECTED], machine_irq_order_count;
volatile u32 machine_irq_log[IRQ_EXPECTED][4];
volatile u32 machine_irq_checksum, machine_irq_work, machine_irq_mask_checks;

static void uart_puts(const char *text)
{ while (*text) mmio_putchar(*text++); }

__attribute__((noreturn)) static void fail(u32 code)
{
    MACHINE_CSR_CLEAR(mstatus, MACHINE_IRQ_GLOBAL_MIE);
    MACHINE_CSR_WRITE(mie, 0u);
    timer_cancel();
    machine_irq_failed = code;
    machine_irq_done = 2u;
    gpio_write(4u);
    uart_puts("MACHINE IRQ FAIL ");
    for (int shift = 28; shift >= 0; shift -= 4) {
        u32 digit = (code >> shift) & 15u;
        mmio_putchar((char)(digit < 10u ? '0' + digit : 'A' + digit - 10u));
    }
    uart_puts("\r\n");
    mmio_uart_flush();
    tohost = 2u;
    for (;;) {}
}

static void wait_pending(u32 bits, u32 expected, u32 code)
{
    timer_u64 deadline = timer_read_time() + TIMEOUT_CYCLES;
    while ((MACHINE_CSR_READ(mip) & bits) != expected)
        if (timer_read_time() >= deadline) fail(code);
}

static void wait_count(u32 expected, u32 code)
{
    timer_u64 deadline = timer_read_time() + TIMEOUT_CYCLES;
    while (machine_irq_order_count < expected)
        if (timer_read_time() >= deadline) fail(code);
    if (machine_irq_order_count != expected) fail(code + 0x100u);
}

/* Entry saves every integer register. Never advance interrupt mepc by four.
 * Poll after acknowledgement so synchronized MEIP cannot retrigger on MRET. */
u32 machine_irq_handler(u32 cause, u32 pc, u32 tval, u32 status)
{
    u32 slot = machine_irq_order_count;
    u32 code = cause & 0x7fffffffu, bit;
    if (slot >= IRQ_EXPECTED || (cause & 0x80000000u) == 0u ||
        (code != 11u && code != 3u && code != 7u) || tval != 0u ||
        (pc & 3u) != 0u || (status & 0x1888u) != 0x1880u)
        fail(0x1000u | slot);
    bit = 1u << code;
    if ((MACHINE_CSR_READ(mie) & bit) == 0u || (MACHINE_CSR_READ(mip) & bit) == 0u)
        fail(0x1100u | slot);
    machine_irq_log[slot][0] = cause;
    machine_irq_log[slot][1] = pc;
    machine_irq_log[slot][2] = tval;
    machine_irq_log[slot][3] = status;
    machine_irq_order[slot] = code;
    if (code == 11u) {
        machine_irq_clear_external();
        ++machine_irq_external_count;
    } else if (code == 3u) {
        machine_irq_set_software(0u);
        ++machine_irq_software_count;
    } else {
        timer_cancel();
        ++machine_irq_timer_count;
    }
    wait_pending(bit, 0u, 0x1200u | slot);
    machine_irq_order_count = slot + 1u;
    return pc;
}

static void check_masked(u32 count, u32 pending, u32 enabled, u32 global, u32 code)
{
    wait_pending(pending, pending, code);
    for (u32 poll = 0; poll < 32u; ++poll) {
        if (machine_irq_order_count != count ||
            (MACHINE_CSR_READ(mip) & pending) != pending ||
            (MACHINE_CSR_READ(mie) & MACHINE_IRQ_ALL) != enabled ||
            (MACHINE_CSR_READ(mstatus) & MACHINE_IRQ_GLOBAL_MIE) != global)
            fail(code + 1u);
    }
    ++machine_irq_mask_checks;
}

__attribute__((noinline)) void machine_irq_pass(void)
{
    uart_puts("MACHINE IRQ PASS\r\n");
    mmio_uart_flush();
}

int main(void)
{
    static const u32 expected_order[IRQ_EXPECTED] = {11u, 3u, 7u, 11u, 3u, 11u, 3u, 7u};
    u32 value = WORK_SEED, phase = 0u, last_toggle;
    gpio_set_direction(7u);
    gpio_write(0u);
    tohost = 0u;
    MACHINE_CSR_CLEAR(mstatus, MACHINE_IRQ_GLOBAL_MIE);
    MACHINE_CSR_WRITE(mie, 0u);
    MACHINE_CSR_WRITE(mtvec, machine_irq_entry);
    timer_cancel();
    machine_irq_set_software(0u);
    if (MACHINE_CSR_READ(mtvec) != (u32)machine_irq_entry ||
        machine_irq_guard != 0x12345678u || machine_irq_blink_cycles == 0u ||
        MMIO_REG32(MACHINE_IRQ_DEMO_BASE) != MACHINE_IRQ_DEMO_ID ||
        MMIO_REG32(MACHINE_IRQ_DEMO_BASE + 4u) != 0u ||
        MMIO_REG32(MACHINE_IRQ_DEMO_BASE + 16u) != 0u ||
        MMIO_REG32(MACHINE_IRQ_DEMO_BASE + 20u) != 0u)
        fail(1u);
    wait_pending(MACHINE_IRQ_ALL, 0u, 2u);
    MACHINE_CSR_WRITE(mie, MACHINE_IRQ_ALL);
    MACHINE_CSR_SET(mstatus, MACHINE_IRQ_GLOBAL_MIE);
    machine_irq_set_external();
    wait_count(1u, 0x20u);
    machine_irq_set_software(1u);
    wait_count(2u, 0x30u);
    /* Schedule one timer interrupt inside ordinary arithmetic/loads/stores. */
    timer_write_compare(timer_read_time() + 2000u);
    __asm__ volatile(".global machine_irq_work_begin\nmachine_irq_work_begin:" ::: "memory");
    for (u32 index = 0; index < WORK_COUNT; ++index) {
        value = (value << 5) ^ (value >> 2) ^ index;
        machine_irq_checksum = value;
        machine_irq_work = index + 1u;
    }
    __asm__ volatile(".global machine_irq_work_end\nmachine_irq_work_end:" ::: "memory");
    wait_count(3u, 0x40u);

    /* Enabled global MIE cannot bypass an individual source mask. */
    MACHINE_CSR_WRITE(mie, MACHINE_IRQ_ALL & ~MACHINE_IRQ_MEIE);
    machine_irq_set_external();
    check_masked(3u, MACHINE_IRQ_MEIE, MACHINE_IRQ_ALL & ~MACHINE_IRQ_MEIE,
                 MACHINE_IRQ_GLOBAL_MIE, 0x50u);
    MACHINE_CSR_WRITE(mie, MACHINE_IRQ_ALL);
    wait_count(4u, 0x60u);

    /* An enabled source stays pending while global MIE is clear. */
    MACHINE_CSR_CLEAR(mstatus, MACHINE_IRQ_GLOBAL_MIE);
    machine_irq_set_software(1u);
    check_masked(4u, MACHINE_IRQ_MSIE, MACHINE_IRQ_ALL, 0u, 0x70u);
    MACHINE_CSR_SET(mstatus, MACHINE_IRQ_GLOBAL_MIE);
    wait_count(5u, 0x80u);

    /* Wait for all three actual mip bits before enabling arbitration. */
    MACHINE_CSR_CLEAR(mstatus, MACHINE_IRQ_GLOBAL_MIE);
    machine_irq_set_external();
    machine_irq_set_software(1u);
    timer_write_compare(0u);
    check_masked(5u, MACHINE_IRQ_ALL, MACHINE_IRQ_ALL, 0u, 0x90u);
    MACHINE_CSR_SET(mstatus, MACHINE_IRQ_GLOBAL_MIE);
    wait_count(IRQ_EXPECTED, 0xa0u);
    MACHINE_CSR_CLEAR(mstatus, MACHINE_IRQ_GLOBAL_MIE);
    MACHINE_CSR_WRITE(mie, 0u);
    wait_pending(MACHINE_IRQ_ALL, 0u, 0xb0u);
    if (machine_irq_external_count != 3u || machine_irq_software_count != 3u ||
        machine_irq_timer_count != 2u || machine_irq_mask_checks != 3u ||
        machine_irq_guard != 0x12345678u || machine_irq_failed != 0u ||
        machine_irq_checksum != WORK_EXPECT || value != WORK_EXPECT || machine_irq_work != WORK_COUNT ||
        MMIO_REG32(MACHINE_IRQ_MSIP_ADDR) != 0u ||
        MMIO_REG32(MACHINE_IRQ_DEMO_BASE + 4u) != 0u ||
        MMIO_REG32(MACHINE_IRQ_DEMO_BASE + 16u) != 3u ||
        MMIO_REG32(MACHINE_IRQ_DEMO_BASE + 20u) != 3u)
        fail(0xc0u);
    for (u32 slot = 0; slot < IRQ_EXPECTED; ++slot)
        if (machine_irq_order[slot] != expected_order[slot]) fail(0xd0u + slot);
    machine_irq_done = 1u;
    machine_irq_pass();
    tohost = 1u;
    gpio_write(2u);
    last_toggle = (u32)timer_read_time();
    for (;;) {
        u32 now = (u32)timer_read_time();
        if ((u32)(now - last_toggle) >= machine_irq_blink_cycles) {
            phase ^= 1u;
            gpio_write(2u | phase);
            last_toggle = now;
        }
    }
}
