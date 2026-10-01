#include "gpio.h"

#ifndef BOARD_BLINK_CYCLES
#define BOARD_BLINK_CYCLES 25000000u
#endif

// Volatile data lets the accelerated simulation use the same instruction
// image and a different .data image. Hardware uses 25M cycles = 0.5s at 50MHz.
static volatile uint32_t blink_cycles = BOARD_BLINK_CYCLES;

int main(void)
{
    const char *message = "Hello RISC-V\r\n";
    uint32_t phase = 1u;
    uint32_t last_toggle;

    gpio_write(phase);
    gpio_set_direction(0xffu);
    while (*message != '\0')
        mmio_putchar(*message++);
    mmio_uart_flush();
    last_toggle = mmio_read_cycle();

    // This is a real board demo: it never returns or waits for tohost.
    // KEY1 resets the whole CPU; KEY2..KEY8 light LED2..LED8 while pressed.
    // GPIO input synchronization is not a general mechanical debounce filter.
    for (;;) {
        uint32_t now = mmio_read_cycle();
        if ((uint32_t)(now - last_toggle) >= blink_cycles) {
            phase ^= 1u;
            last_toggle = now;
        }
        gpio_write(phase | ((~gpio_read_input()) & 0xfeu));
    }
}
