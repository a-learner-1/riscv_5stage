/* MES50HP synchronous exception acceptance program: ENABLE_TRAPS=1.
 * GPIO bit 1: PASS, bit 0: heartbeat, bit 2: software FAIL.
 * This same binary runs on hardware and in simulation. Only the initialized
 * blink_cycles RAM word differs. Interrupts and nested traps are not used. */
#include "gpio.h"
typedef unsigned int u32;

#ifndef TRAP_BOARD_BLINK_CYCLES
#define TRAP_BOARD_BLINK_CYCLES 25000000u
#endif

extern void trap_entry(void);
extern const char trap_board_ecall[], trap_board_ebreak[];
extern const char trap_board_illegal[], trap_board_badcsr[];

volatile u32 trap_board_count;
volatile u32 trap_board_log[4][4];
volatile u32 trap_board_resumed;
volatile u32 ram_guard = 0x12345678u;
volatile u32 blink_cycles = TRAP_BOARD_BLINK_CYCLES;

#define CSR_READ(name) ({u32 value; __asm__ volatile("csrr %0, " #name : "=r"(value)); value;})
#define CSR_WRITE(name, value) __asm__ volatile("csrw " #name ", %0" :: "r"((u32)(value)) : "memory")

static void uart_puts(const char *text)
{
    while (*text) mmio_putchar(*text++);
}

static void uart_hex(u32 value)
{
    for (int shift = 28; shift >= 0; shift -= 4) {
        u32 digit = (value >> shift) & 15u;
        mmio_putchar((char)(digit < 10u ? '0' + digit : 'A' + digit - 10u));
    }
}

static void fail(u32 code)
{
    gpio_write(4u);
    uart_puts("TRAP BOARD FAIL ");
    uart_hex(code);
    uart_puts("\r\n");
    mmio_uart_flush();
    for (;;) {}
}

/* Retain trap_demo_handler to reuse the unchanged trap_entry.S entry ABI.
 * These four deliberate 32-bit faults recover by skipping one instruction.
 * A general exception handler must choose recovery according to its cause. */
u32 trap_demo_handler(u32 cause, u32 pc, u32 tval, u32 status)
{
    const u32 expected_cause[4] = {11u, 3u, 2u, 2u};
    const u32 expected_pc[4] = {(u32)trap_board_ecall, (u32)trap_board_ebreak,
                               (u32)trap_board_illegal, (u32)trap_board_badcsr};
    const u32 expected_tval[4] = {0u, (u32)trap_board_ebreak, 0xffffffffu, 0x77702073u};
    u32 slot = trap_board_count;
    if (slot >= 4u || cause != expected_cause[slot] || pc != expected_pc[slot] ||
        tval != expected_tval[slot] || (status & 0x1888u) != 0x1880u)
        fail(0x10u + slot);
    trap_board_log[slot][0] = cause;
    trap_board_log[slot][1] = pc;
    trap_board_log[slot][2] = tval;
    trap_board_log[slot][3] = status;
    trap_board_count = slot + 1u;
    return pc + 4u;
}

int main(void)
{
    u32 old, value, phase = 0u, last_toggle;
    gpio_write(0u);
    gpio_set_direction(7u);
    if (ram_guard != 0x12345678u || blink_cycles == 0u) fail(1u);

    CSR_WRITE(mtvec, trap_entry);
    if (CSR_READ(mtvec) != (u32)trap_entry) fail(2u);
    CSR_WRITE(mscratch, 0x12345678u);
    value = 0xffu;
    __asm__ volatile("csrrs %0, mscratch, %1" : "=r"(old) : "r"(value));
    if (old != 0x12345678u || CSR_READ(mscratch) != 0x123456ffu) fail(3u);
    value = 0xf0u;
    __asm__ volatile("csrrc %0, mscratch, %1" : "=r"(old) : "r"(value));
    if (old != 0x123456ffu || CSR_READ(mscratch) != 0x1234560fu) fail(4u);
    __asm__ volatile("csrrwi %0, mscratch, 16" : "=r"(old));
    if (old != 0x1234560fu) fail(5u);
    __asm__ volatile("csrrsi %0, mscratch, 3" : "=r"(old));
    if (old != 16u) fail(6u);
    __asm__ volatile("csrrci %0, mscratch, 1" : "=r"(old));
    if (old != 19u || CSR_READ(mscratch) != 18u) fail(7u);
    __asm__ volatile("csrrw %0, misa, zero" : "=r"(old));
    if (old != 0x40000100u || CSR_READ(misa) != old || CSR_READ(mhartid) != 0u) fail(8u);

    ram_guard = 0x12345678u;
    __asm__ volatile("fence iorw, iorw" ::: "memory");
    if (ram_guard != 0x12345678u) fail(9u);
    value = 8u;
    __asm__ volatile("csrrs zero, mstatus, %0" :: "r"(value) : "memory");
    __asm__ volatile(".global trap_board_ecall\ntrap_board_ecall: ecall" ::: "memory");
    trap_board_resumed++;
    __asm__ volatile(".global trap_board_ebreak\ntrap_board_ebreak: ebreak" ::: "memory");
    trap_board_resumed++;
    __asm__ volatile(".global trap_board_illegal\ntrap_board_illegal: .word 0xffffffff" ::: "memory");
    trap_board_resumed++;
    __asm__ volatile(".global trap_board_badcsr\ntrap_board_badcsr: .word 0x77702073" ::: "memory");
    trap_board_resumed++;

    if (trap_board_count != 4u || trap_board_resumed != 4u ||
        ram_guard != 0x12345678u || CSR_READ(mscratch) != 18u ||
        (CSR_READ(mstatus) & 0x1888u) != 0x1888u) fail(10u);
    for (u32 slot = 0; slot < 4u; ++slot) {
        const u32 expected_cause[4] = {11u, 3u, 2u, 2u};
        const u32 expected_pc[4] = {(u32)trap_board_ecall, (u32)trap_board_ebreak,
                                   (u32)trap_board_illegal, (u32)trap_board_badcsr};
        const u32 expected_tval[4] = {0u, (u32)trap_board_ebreak, 0xffffffffu, 0x77702073u};
        if (trap_board_log[slot][0] != expected_cause[slot] ||
            trap_board_log[slot][1] != expected_pc[slot] ||
            trap_board_log[slot][2] != expected_tval[slot] ||
            (trap_board_log[slot][3] & 0x1888u) != 0x1880u) fail(0x20u + slot);
    }
    uart_puts("TRAP BOARD PASS\r\n");
    mmio_uart_flush();
    gpio_write(2u);
    last_toggle = mmio_read_cycle();
    for (;;) {
        u32 now = mmio_read_cycle();
        if ((u32)(now - last_toggle) >= blink_cycles) {
            phase ^= 1u;
            gpio_write(2u | phase);
            last_toggle = now;
        }
    }
}
