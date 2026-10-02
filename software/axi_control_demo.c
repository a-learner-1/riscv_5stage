#include "axi_control.h"

/* Volatile data proves ordinary RAM accesses share the routed AXI path. */
static volatile axi_u32 ram_guard = 0x12345678u;
static volatile axi_u32 observed[3];
static const axi_u32 operand_a[3] = {17u, 0xffffffffu, 0x7fffffffu};
static const axi_u32 operand_b[3] = {25u, 2u, 1u};
static const axi_u32 expected[3] = {42u, 1u, 0x80000000u};

int main(void)
{
    axi_u32 job, poll, status, value;
    if (ram_guard != 0x12345678u) return 2;
    if (axi_ctrl_read(AXI_CTRL_STATUS) != 0u ||
        axi_ctrl_read(AXI_CTRL_START_COUNT) != 0u) return 3;
    for (job = 0; job < 3; ++job) {
        axi_ctrl_write(AXI_CTRL_OPERAND_A, operand_a[job]);
        axi_ctrl_write(AXI_CTRL_OPERAND_B, operand_b[job]);
        axi_ctrl_write(AXI_CTRL_COMMAND, AXI_CTRL_START);
        for (poll = 0; poll < 4096; ++poll) {
            status = axi_ctrl_read(AXI_CTRL_STATUS);
            if ((status & AXI_CTRL_DONE) != 0u) break;
        }
        if (poll == 4096 || (status & AXI_CTRL_BUSY) != 0u) return 4;
        value = axi_ctrl_read(AXI_CTRL_RESULT);
        if (value != expected[job]) return 5;
        /* Reading results/status must not clear DONE or start another task. */
        if (axi_ctrl_read(AXI_CTRL_RESULT) != value ||
            axi_ctrl_read(AXI_CTRL_STATUS) != AXI_CTRL_DONE ||
            axi_ctrl_read(AXI_CTRL_START_COUNT) != job + 1u) return 6;
        observed[job] = value;
        axi_ctrl_write(AXI_CTRL_COMMAND, AXI_CTRL_CLEAR_DONE);
        if (axi_ctrl_read(AXI_CTRL_STATUS) != 0u) return 7;
    }
    if (ram_guard != 0x12345678u || observed[0] != 42u ||
        observed[1] != 1u || observed[2] != 0x80000000u) return 8;
    return 1;
}
