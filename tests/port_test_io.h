#ifndef COREMARK_PORT_TEST_IO_H
#define COREMARK_PORT_TEST_IO_H
/* Deterministic RV32 fixture: the production timer_read_time() is unchanged.
 * Only register reads and report output are replaced. Mock values are not scores. */
#include "mmio.h"
uint32_t *coremark_test_reg(uint32_t address);
void coremark_test_putchar(char character);
void coremark_test_flush(void);
void coremark_test_tohost(uint32_t value);
#undef MMIO_REG32
#define MMIO_REG32(address) (*coremark_test_reg(address))
#include "timer.h"
#define mmio_putchar coremark_test_putchar
#define mmio_uart_flush coremark_test_flush
#define COREMARK_TOHOST_WRITE(value) coremark_test_tohost(value)
#endif
