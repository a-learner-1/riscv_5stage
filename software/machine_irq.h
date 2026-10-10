#ifndef RISCV_3STAGE_MACHINE_IRQ_H
#define RISCV_3STAGE_MACHINE_IRQ_H

#include "timer.h"

#define MACHINE_IRQ_MSIP_ADDR 0x20000050u
#define MACHINE_IRQ_MSIE 0x008u
#define MACHINE_IRQ_MTIE 0x080u
#define MACHINE_IRQ_MEIE 0x800u
#define MACHINE_IRQ_ALL (MACHINE_IRQ_MSIE | MACHINE_IRQ_MTIE | MACHINE_IRQ_MEIE)
#define MACHINE_IRQ_GLOBAL_MIE 0x008u
#define MACHINE_IRQ_DEMO_BASE 0x30000000u
#define MACHINE_IRQ_DEMO_ID 0x49525131u

#define MACHINE_CSR_READ(name) ({uint32_t irq_value; \
    __asm__ volatile("csrr %0, " #name : "=r"(irq_value) :: "memory"); irq_value;})
#define MACHINE_CSR_WRITE(name, value) \
    __asm__ volatile("csrw " #name ", %0" :: "r"((uint32_t)(value)) : "memory")
#define MACHINE_CSR_SET(name, value) \
    __asm__ volatile("csrrs zero, " #name ", %0" :: "r"((uint32_t)(value)) : "memory")
#define MACHINE_CSR_CLEAR(name, value) \
    __asm__ volatile("csrrc zero, " #name ", %0" :: "r"((uint32_t)(value)) : "memory")

static inline void machine_irq_set_software(uint32_t pending)
{ MMIO_REG32(MACHINE_IRQ_MSIP_ADDR) = pending & 1u; }
static inline void machine_irq_set_external(void)
{ MMIO_REG32(MACHINE_IRQ_DEMO_BASE + 8u) = 1u; }
static inline void machine_irq_clear_external(void)
{ MMIO_REG32(MACHINE_IRQ_DEMO_BASE + 12u) = 1u; }

#endif
