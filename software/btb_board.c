/* Prepared board acceptance firmware; no performance score is measured.
 * Six branch conditions, JAL/JALR links, trained loop exits and BTB conflicts.
 * GPIO bit 1 = PASS, bit 0 = heartbeat, bit 2 = FAIL. KEY1 restarts the image.
 */
#include "gpio.h"
#include "timer.h"
typedef unsigned int u32;

#ifndef BTB_BOARD_BLINK_CYCLES
#define BTB_BOARD_BLINK_CYCLES 25000000u
#endif

#define BTB_BASE 0x20000070u
#define BTB_EXPECT_CONFIG 0x00400001u
extern u32 btb_board_cases(void);
extern void btb_board_trap_entry(void);
volatile u32 btb_board_blink_cycles = BTB_BOARD_BLINK_CYCLES;
volatile u32 btb_board_failed;
volatile u32 btb_board_result;
volatile u32 btb_board_done;
volatile u32 btb_board_baseline[8];
volatile u32 btb_board_snapshot[8];

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

static void snapshot(volatile u32 values[8])
{
    /* Each MMIO counter is an independent volatile LW. These are diagnostics,
     * not an atomic benchmark window, and include the snapshot instructions. */
    for (u32 index = 0u; index < 8u; ++index)
        values[index] = MMIO_REG32(BTB_BASE + (index << 2));
}

/* The trap entry resets SP and never resumes the interrupted instruction.
 * This prevents an unexpected trap from restarting at reset PC and clearing
 * an earlier failure before a subsequent run can print PASS. */
__attribute__((noreturn)) void btb_board_trap_fail(u32 cause, u32 pc, u32 tval)
{
    btb_board_failed |= 16u;
    btb_board_result = cause;
    gpio_set_direction(7u);
    gpio_write(4u);
    uart_puts("BTB TRAP ");
    uart_hex(cause);
    mmio_putchar(' ');
    uart_hex(pc);
    mmio_putchar(' ');
    uart_hex(tval);
    uart_puts("\r\nBTB BOARD FAIL ");
    uart_hex(btb_board_failed);
    mmio_putchar(' ');
    uart_hex(btb_board_result);
    uart_puts("\r\n");
    mmio_uart_flush();
    btb_board_done = 1u;
    for (;;) {}
}

int main(void)
{
    u32 phase = 0u, last_toggle;
    /* Install a fatal trap destination before touching MMIO or running cases.
     * No timer interrupt is enabled by this image. */
    __asm__ volatile("csrw mtvec, %0\ncsrrc zero, mstatus, %1\ncsrw mie, zero"
                     :: "r"((u32)btb_board_trap_entry), "r"(8u) : "memory");
    gpio_write(0u);
    gpio_set_direction(7u);
    timer_cancel();
    snapshot(btb_board_baseline);
    btb_board_result = btb_board_cases();
    snapshot(btb_board_snapshot);
    if (btb_board_result != 0u) btb_board_failed |= 1u;
    if (btb_board_baseline[0] != BTB_EXPECT_CONFIG ||
        btb_board_snapshot[0] != BTB_EXPECT_CONFIG) btb_board_failed |= 2u;
    /* Require useful predictor activity and a recovery. Exact counts depend
     * on compiler layout and on the instructions in the snapshot helper. */
    for (u32 index = 1u; index <= 5u; ++index)
        if ((u32)(btb_board_snapshot[index] - btb_board_baseline[index]) == 0u)
            btb_board_failed |= 4u;
    if (btb_board_blink_cycles == 0u) btb_board_failed |= 8u;
    uart_puts("BTB COUNTERS");
    for (u32 index = 1u; index < 8u; ++index) {
        mmio_putchar(' ');
        uart_hex((u32)(btb_board_snapshot[index] - btb_board_baseline[index]));
    }
    uart_puts("\r\n");
    if (btb_board_failed) {
        gpio_write(4u);
        uart_puts("BTB BOARD FAIL ");
        uart_hex(btb_board_failed);
        mmio_putchar(' ');
        uart_hex(btb_board_result);
        uart_puts("\r\n");
        mmio_uart_flush();
        btb_board_done = 1u;
        for (;;) {}
    }
    uart_puts("BTB BOARD PASS\r\n");
    mmio_uart_flush();
    gpio_write(2u);
    btb_board_done = 1u;
    last_toggle = (u32)timer_read_time();
    for (;;) {
        u32 now = (u32)timer_read_time();
        if ((u32)(now - last_toggle) >= btb_board_blink_cycles) {
            phase ^= 1u;
            gpio_write(2u | phase);
            last_toggle = now;
        }
    }
}
