#ifndef RISCV_3STAGE_UART_RX_H
#define RISCV_3STAGE_UART_RX_H

#include "mmio.h"

#define MMIO_UART_RX_DATA_ADDR   0x20000018u
#define MMIO_UART_RX_STATUS_ADDR 0x2000001cu

#define UART_RX_NONEMPTY_MASK    0x01u
#define UART_RX_FULL_MASK        0x02u
#define UART_RX_OVERFLOW_MASK    0x04u
#define UART_RX_FRAME_ERROR_MASK 0x08u
#define UART_RX_ERROR_MASK       (UART_RX_OVERFLOW_MASK | UART_RX_FRAME_ERROR_MASK)
#define UART_RX_COUNT_MASK       0x0000ff00u
#define UART_RX_COUNT_SHIFT      8u

static inline uint32_t uart_rx_status(void)
{
    return MMIO_REG32(MMIO_UART_RX_STATUS_ADDR);
}

static inline uint32_t uart_rx_count(uint32_t status)
{
    return (status & UART_RX_COUNT_MASK) >> UART_RX_COUNT_SHIFT;
}

/* Aligned LW from DATA removes exactly one byte. Never read an empty FIFO. */
static inline unsigned char uart_rx_getchar(void)
{
    while ((uart_rx_status() & UART_RX_NONEMPTY_MASK) == 0u) {
    }
    return (unsigned char)MMIO_REG32(MMIO_UART_RX_DATA_ADDR);
}

/* STATUS bits 2 and 3 are sticky errors with write-one-to-clear semantics. */
static inline void uart_rx_clear_errors(uint32_t mask)
{
    MMIO_REG32(MMIO_UART_RX_STATUS_ADDR) = mask & UART_RX_ERROR_MASK;
}

#endif
