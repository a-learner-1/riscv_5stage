#ifndef AXI_CONTROL_H
#define AXI_CONTROL_H

/* Temporary demo-device interface, not a CNN register contract. */
typedef unsigned int axi_u32;
#ifndef AXI_CTRL_BASE
#define AXI_CTRL_BASE 0x30000000u
#endif
#define AXI_CTRL_COMMAND     0x00u
#define AXI_CTRL_STATUS      0x04u
#define AXI_CTRL_OPERAND_A   0x08u
#define AXI_CTRL_OPERAND_B   0x0cu
#define AXI_CTRL_RESULT      0x10u
#define AXI_CTRL_START_COUNT 0x14u
#define AXI_CTRL_START       1u
#define AXI_CTRL_CLEAR_DONE  2u
#define AXI_CTRL_BUSY        1u
#define AXI_CTRL_DONE        2u

static inline void axi_ctrl_write(axi_u32 offset, axi_u32 value)
{
    *(volatile axi_u32 *)(AXI_CTRL_BASE + offset) = value;
}

static inline axi_u32 axi_ctrl_read(axi_u32 offset)
{
    return *(volatile axi_u32 *)(AXI_CTRL_BASE + offset);
}
#endif
