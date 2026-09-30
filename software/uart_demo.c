#include "mmio.h"

int main(void)
{
    const char *text = "Hello RISC-V\n";
    while (*text != '\0')
        mmio_putchar(*text++);

    // main must not signal completion before the last stop bit is sent.
    mmio_uart_flush();
    return 1;
}
