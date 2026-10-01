#include "uart_rx.h"

#ifndef UART_RX_TEST_BYTES
#define UART_RX_TEST_BYTES 0
#endif

int main(void)
{
#if UART_RX_TEST_BYTES > 0
    uint32_t received;
    for (received = 0u; received < UART_RX_TEST_BYTES; ++received)
        mmio_putchar((char)uart_rx_getchar());

    /* Match start.S: main returns 1 on pass, then a0 is stored to tohost. */
    mmio_uart_flush();
    return (uart_rx_status() & UART_RX_ERROR_MASK) ? 2 : 1;
#else
    /* Board firmware has no tohost completion and emits no extra text. */
    for (;;)
        mmio_putchar((char)uart_rx_getchar());
#endif
}
