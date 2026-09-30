#ifndef RISCV_3STAGE_MMIO_H
#define RISCV_3STAGE_MMIO_H

typedef unsigned int uint32_t;

#define MMIO_CYCLE_ADDR    0x20000000u
#define MMIO_INSTRET_ADDR  0x20000004u
#define MMIO_PUTCHAR_ADDR  0x20000010u
#define MMIO_UART_STATUS_ADDR 0x20000014u
#define MMIO_UART_BUSY_MASK   1u

#define MMIO_REG32(address) \
    (*(volatile uint32_t *)(address))

static inline uint32_t mmio_read_cycle(void)
{
    return MMIO_REG32(MMIO_CYCLE_ADDR);
}

static inline uint32_t mmio_read_instret(void)
{
    return MMIO_REG32(MMIO_INSTRET_ADDR);
}

static inline void mmio_putchar(char character)
{
    while (MMIO_REG32(MMIO_UART_STATUS_ADDR) & MMIO_UART_BUSY_MASK) {
        /* Poll a volatile register until the complete previous frame ends. */
    }
    MMIO_REG32(MMIO_PUTCHAR_ADDR) = (uint32_t)(unsigned char)character;
}

static inline void mmio_uart_flush(void)
{
    while (MMIO_REG32(MMIO_UART_STATUS_ADDR) & MMIO_UART_BUSY_MASK) {
    }
}

#endif
