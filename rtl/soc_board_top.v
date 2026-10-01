// MES50HP board wrapper for the new SoC, with the same physical pins as
// board_top. The old board_top remains the saved baseline entry point.
module soc_board_top #(
    parameter PROGRAM_FILE = "programs/board_demo.hex",
    parameter DATA_FILE = "programs/board_demo_data.hex",
    parameter integer RESET_HOLD_CYCLES = 50000
) (
    input  wire       clk_50m,
    input  wire       key1_n,
    input  wire [6:0] keys_n,
    output wire [7:0] led,
    output wire       uart_tx,
    input  wire       uart_rx
);
    wire cpu_rst_n;
    wire [7:0] gpio_out, gpio_oe;
    board_reset #(.HOLD_CYCLES(RESET_HOLD_CYCLES)) u_reset (
        .clk(clk_50m), .key1_n(key1_n), .cpu_rst_n(cpu_rst_n)
    );
    soc_top #(
        .PROGRAM_FILE(PROGRAM_FILE), .DATA_FILE(DATA_FILE),
        .IMEM_WORDS(8192), .DMEM_WORDS(4096),
        .DMEM_BASE_ADDR(32'h00010000),
        .UART_CLOCK_HZ(50000000), .UART_BAUD(115200),
        .SIM_CONSOLE_ECHO(0)
    ) u_soc (
        .clk(clk_50m), .rst_n(cpu_rst_n), .uart_rx(uart_rx), .uart_tx(uart_tx),
        .gpio_in({keys_n, key1_n}), .gpio_out(gpio_out), .gpio_oe(gpio_oe),
        .pc_x(), .instr_x(), .valid_x(), .wb_pc(), .wb_rd(), .wb_data(),
        .wb_we(), .retire_valid(), .cycle_count(), .instret_count(),
        .imem_fault(), .imem_fault_pc(), .dmem_fault()
    );
    assign led = gpio_out & gpio_oe;
endmodule
