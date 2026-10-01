#include "gpio.h"

static volatile uint32_t expected_initial_input = 0xa5;

// Finite simulation self-test, not a hardware blink demonstration.
// gpio_cpu_tb drives 0xa5 initially, then 0x3c after the 0x69 marker.
int main(void)
{
    uint32_t attempts;
    if (gpio_read_output() != 0 || gpio_read_direction() != 0) return 2;
    if ((gpio_read_input() ^ 0xffu) != (expected_initial_input ^ 0xffu)) return 3;

    gpio_write(0x3c);
    if (gpio_read_output() != 0x3c || gpio_read_direction() != 0) return 4;
    gpio_set_direction(0xff);
    if (gpio_read_direction() != 0xff) return 5;
    gpio_write(0x5a);
    gpio_set(0x81);
    if (gpio_read_output() != 0xdb) return 6;
    gpio_clear(0x18);
    if (gpio_read_output() != 0xc3) return 7;
    gpio_toggle(0x0f);
    if (gpio_read_output() != 0xcc) return 8;

    // Reserved upper bits must neither read back nor modify the low byte.
    gpio_set(0xffffff00u);
    gpio_clear(0xffffff00u);
    gpio_toggle(0xffffff00u);
    if (gpio_read_output() != 0xcc) return 9;
    gpio_write(0x123456aau);
    gpio_set_direction(0x12345655u);
    if (gpio_read_output() != 0xaa || gpio_read_direction() != 0x55) return 10;

    // A taken branch must squash the wrong-path MMIO store. Also check that
    // a GPIO load to x0 does not accidentally write a general register.
    __asm__ volatile (
        "li t0, 0x20000020\n"
        "li t1, 0xee\n"
        "beq zero, zero, 1f\n"
        "sw t1, 0(t0)\n"
        "1: lw zero, 0(t0)\n"
        ::: "t0", "t1", "memory");
    if (gpio_read_output() != 0xaa) return 11;

    gpio_write(0x69);  // Tell the testbench to change asynchronous inputs.
    for (attempts = 0; attempts < 100; ++attempts)
        if (gpio_read_input() == 0x3c) break;
    if (attempts == 100) return 12;
    gpio_write(0xaa);
    gpio_set_direction(0);
    if (gpio_read_direction() != 0 || gpio_read_output() != 0xaa) return 13;
    return 1;         // Existing start.S writes main's value to tohost.
}
