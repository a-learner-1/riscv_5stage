#ifndef RISCV_3STAGE_GPIO_H
#define RISCV_3STAGE_GPIO_H

#include "mmio.h"

#define MMIO_GPIO_OUT_ADDR 0x20000020u
#define MMIO_GPIO_IN_ADDR  0x20000024u
#define MMIO_GPIO_OE_ADDR  0x20000028u
#define MMIO_GPIO_SET_ADDR 0x2000002cu
#define MMIO_GPIO_CLR_ADDR 0x20000030u
#define MMIO_GPIO_XOR_ADDR 0x20000034u

static inline void gpio_write(uint32_t value)
{ MMIO_REG32(MMIO_GPIO_OUT_ADDR) = value; }
static inline uint32_t gpio_read_output(void)
{ return MMIO_REG32(MMIO_GPIO_OUT_ADDR); }
static inline uint32_t gpio_read_input(void)
{ return MMIO_REG32(MMIO_GPIO_IN_ADDR); }
static inline void gpio_set_direction(uint32_t mask)
{ MMIO_REG32(MMIO_GPIO_OE_ADDR) = mask; }
static inline uint32_t gpio_read_direction(void)
{ return MMIO_REG32(MMIO_GPIO_OE_ADDR); }
static inline void gpio_set(uint32_t mask)
{ MMIO_REG32(MMIO_GPIO_SET_ADDR) = mask; }
static inline void gpio_clear(uint32_t mask)
{ MMIO_REG32(MMIO_GPIO_CLR_ADDR) = mask; }
static inline void gpio_toggle(uint32_t mask)
{ MMIO_REG32(MMIO_GPIO_XOR_ADDR) = mask; }

#endif
