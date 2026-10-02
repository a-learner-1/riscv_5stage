// MES50HP board entry point for the temporary AXI control demonstration.
// KEY1 resets the CPU and all AXI protocol and control-device state.
module axi_control_board_top #(
    parameter PROGRAM_FILE = "programs/axi_control_board.hex",
    parameter DATA_FILE = "programs/axi_control_board_data.hex",
    parameter integer RESET_HOLD_CYCLES = 50000,
    parameter integer CTRL_JOB_CYCLES = 256
) (
    input  wire       clk_50m,
    input  wire       key1_n,
    input  wire [6:0] keys_n,
    output wire [7:0] led,
    output wire       uart_tx,
    input  wire       uart_rx
);
    wire cpu_rst_n;
    wire imem_fault, dmem_fault;
    wire [7:0] gpio_out, gpio_oe;
    board_reset #(.HOLD_CYCLES(RESET_HOLD_CYCLES)) u_reset (
        .clk(clk_50m), .key1_n(key1_n), .cpu_rst_n(cpu_rst_n)
    );
    soc_axi_control_top #(
        .PROGRAM_FILE(PROGRAM_FILE), .DATA_FILE(DATA_FILE),
        .IMEM_WORDS(8192), .DMEM_WORDS(4096),
        .DMEM_BASE_ADDR(32'h00010000), .CTRL_BASE_ADDR(32'h30000000),
        .CTRL_JOB_CYCLES(CTRL_JOB_CYCLES),
        .UART_CLOCK_HZ(50000000), .UART_BAUD(115200),
        .SIM_CONSOLE_ECHO(0)
    ) u_soc (
        .clk(clk_50m), .rst_n(cpu_rst_n), .uart_rx(uart_rx), .uart_tx(uart_tx),
        .gpio_in({keys_n, key1_n}), .gpio_out(gpio_out), .gpio_oe(gpio_oe),
        .pc_x(), .instr_x(), .valid_x(), .wb_pc(), .wb_rd(), .wb_data(),
        .wb_we(), .retire_valid(), .cycle_count(), .instret_count(),
        .imem_fault(imem_fault), .imem_fault_pc(), .dmem_fault(dmem_fault),
        .ctrl_busy(), .ctrl_done(), .ctrl_result(), .ctrl_start_count()
    );
    // CPU faults halt software, so their indication is independent of GPIO.
    // Instruction fault has priority if both fault latches are set.
    assign led = !cpu_rst_n ? 8'h00 :
                 imem_fault ? 8'h80 :
                 dmem_fault ? 8'h40 : (gpio_out & gpio_oe);
endmodule
