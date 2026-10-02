/* M-mode timer IRQ demonstration. Requires ENABLE_TRAPS=1 and
 * ENABLE_TIMER_IRQ=1; mtime counts clock ticks, not retired instructions.
 * Three IRQs return to the interrupted PC without skipping an instruction.
 * No WFI, external IRQ, nested interrupt or synchronous ISR fault is used. */
#include "timer.h"
typedef unsigned int u32;

#define IRQ_COUNT 3u
#define IRQ_PERIOD 20000u
#define WORK_COUNT 2048u
#define WORK_SEED 0x13579bdfu
#define WORK_EXPECT 0x569ea33cu

extern void timer_entry(void);
volatile u32 timer_irq_count;
volatile u32 timer_irq_log[IRQ_COUNT][4];
volatile u32 timer_irq_when[IRQ_COUNT][2];
volatile u32 timer_irq_checksum;
volatile u32 timer_irq_work;
volatile u32 timer_irq_mask_checks;
volatile u32 timer_irq_fail_code;
volatile u32 timer_irq_guard = 0x12345678u;

#define CSR_READ(name) ({u32 value; __asm__ volatile("csrr %0, " #name : "=r"(value)); value;})
#define CSR_WRITE(name, value) __asm__ volatile("csrw " #name ", %0" :: "r"((u32)(value)) : "memory")
#define CSR_CLEAR(name, value) __asm__ volatile("csrrc zero, " #name ", %0" :: "r"((u32)(value)) : "memory")
#define CSR_SET(name, value) __asm__ volatile("csrrs zero, " #name ", %0" :: "r"((u32)(value)) : "memory")

static void uart_puts(const char *text)
{
    while (*text) mmio_putchar(*text++);
}

static void fail(u32 code)
{
    CSR_CLEAR(mstatus, TIMER_MIE_MASK);
    CSR_WRITE(mie, 0u);
    timer_cancel();
    timer_irq_fail_code = code;
    uart_puts("TIMER IRQ FAIL\r\n");
    mmio_uart_flush();
    *(volatile u32 *)0x00013ffcu = 0xdead0000u | code;
    for (;;) {}
}

u32 timer_irq_handler(u32 cause, u32 pc, u32 tval, u32 status)
{
    u32 slot = timer_irq_count;
    timer_u64 now;
    if (slot >= IRQ_COUNT || cause != 0x80000007u || tval != 0u || (pc & 3u) != 0u ||
        (status & 0x1888u) != 0x1880u || (CSR_READ(mie) & TIMER_MTIE_MASK) == 0u ||
        (CSR_READ(mip) & TIMER_MTIP_MASK) == 0u) fail(0x10u + slot);
    now = timer_read_time();
    timer_irq_log[slot][0] = cause;
    timer_irq_log[slot][1] = pc;
    timer_irq_log[slot][2] = tval;
    timer_irq_log[slot][3] = status;
    timer_irq_when[slot][0] = (u32)now;
    timer_irq_when[slot][1] = (u32)(now >> 32);
    if (slot + 1u < IRQ_COUNT) timer_write_compare(now + IRQ_PERIOD);
    else timer_cancel();
    timer_irq_count = slot + 1u;
    return pc; /* Interrupt recovery resumes; mepc must not be advanced by 4. */
}

/* The checker has a named boundary after all IRQ and main-work assertions. */
__attribute__((noinline)) static void timer_irq_pass(void)
{
    uart_puts("TIMER IRQ PASS\r\n");
    mmio_uart_flush();
}

int main(void)
{
    u32 value = WORK_SEED;
    timer_u64 begin, deadline;
    CSR_CLEAR(mstatus, TIMER_MIE_MASK);
    CSR_WRITE(mie, 0u);
    CSR_WRITE(mtvec, timer_entry);
    if (CSR_READ(mtvec) != (u32)timer_entry || timer_irq_guard != 0x12345678u)
        fail(1u);
    begin = timer_read_time();
    timer_write_compare(0u); /* Deliberately pending while globally masked. */
    for (u32 poll = 0; poll < 32u; ++poll) {
        if ((CSR_READ(mip) & TIMER_MTIP_MASK) == 0u || timer_irq_count != 0u)
            fail(2u);
    }
    timer_irq_mask_checks = 1u;
    CSR_WRITE(mie, TIMER_MTIE_MASK);
    for (u32 poll = 0; poll < 32u; ++poll) {
        if (timer_irq_count != 0u || (CSR_READ(mie) & TIMER_MTIE_MASK) == 0u ||
            (CSR_READ(mstatus) & TIMER_MIE_MASK) != 0u) fail(3u);
    }
    timer_irq_mask_checks = 2u;
    CSR_SET(mstatus, TIMER_MIE_MASK);
    __asm__ volatile(".global timer_irq_work_begin\ntimer_irq_work_begin:" ::: "memory");
    for (u32 index = 0; index < WORK_COUNT; ++index) {
        value = (value << 5) ^ (value >> 2) ^ index;
        timer_irq_checksum = value;
        timer_irq_work = index + 1u;
    }
    __asm__ volatile(".global timer_irq_work_end\ntimer_irq_work_end:" ::: "memory");
    deadline = timer_read_time() + 1000000u;
    while (timer_irq_count < IRQ_COUNT) {
        if (timer_read_time() >= deadline) fail(4u);
    }
    CSR_CLEAR(mstatus, TIMER_MIE_MASK);
    CSR_WRITE(mie, 0u);
    if (timer_irq_count != IRQ_COUNT || timer_irq_checksum != WORK_EXPECT ||
        value != WORK_EXPECT || timer_irq_work != WORK_COUNT ||
        timer_irq_mask_checks != 2u || timer_irq_guard != 0x12345678u ||
        timer_irq_fail_code != 0u || (CSR_READ(mie) & TIMER_MTIE_MASK) != 0u ||
        (CSR_READ(mip) & TIMER_MTIP_MASK) != 0u ||
        (CSR_READ(mstatus) & 0x1888u) != 0x1880u || timer_read_time() <= begin)
        fail(5u);
    for (u32 slot = 0; slot < IRQ_COUNT; ++slot) {
        if (timer_irq_log[slot][0] != 0x80000007u || timer_irq_log[slot][2] != 0u ||
            (timer_irq_log[slot][1] & 3u) != 0u ||
            (timer_irq_log[slot][3] & 0x1888u) != 0x1880u) fail(6u);
    }
    timer_irq_pass();
    return 1;
}
