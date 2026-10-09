// Opt-in MES50HP branch prediction acceptance image, prepared but unverified.
// Internal 32 KiB ROM / 16 KiB RAM, 50 MHz and 115200 baud.
module btb_board_top #(
    parameter PROGRAM_FILE = "programs/btb_board.hex",
    parameter DATA_FILE = "programs/btb_board_data.hex",
    parameter integer RESET_HOLD_CYCLES = 50000
) (
    input wire clk_50m,
    input wire key1_n,
    input wire [6:0] keys_n,
    output wire [7:0] led,
    output wire uart_tx,
    input wire uart_rx
);
    wire cpu_rst_n;
    wire [7:0] gpio_out, gpio_oe;
    board_reset #(.HOLD_CYCLES(RESET_HOLD_CYCLES)) u_reset (
        .clk(clk_50m), .key1_n(key1_n), .cpu_rst_n(cpu_rst_n)
    );
    cpu_top #(
        .PROGRAM_FILE(PROGRAM_FILE), .DATA_FILE(DATA_FILE),
        .IMEM_WORDS(8192), .DMEM_WORDS(4096),
        .DMEM_BASE_ADDR(32'h00010000),
        .UART_CLOCK_HZ(50000000), .UART_BAUD(115200),
        .ENABLE_TRAPS(1), .ENABLE_TIMER_IRQ(1),
        .ENABLE_BRANCH_PRED(1), .BTB_ENTRIES(64), .SIM_CONSOLE_ECHO(0)
    ) u_cpu (
        .clk(clk_50m), .rst_n(cpu_rst_n), .uart_rx(uart_rx), .uart_tx(uart_tx),
        .gpio_in({keys_n, key1_n}), .gpio_out(gpio_out), .gpio_oe(gpio_oe),
        .pc_x(), .instr_x(), .valid_x(), .wb_pc(), .wb_rd(), .wb_data(),
        .wb_we(), .retire_valid(), .cycle_count(), .instret_count(),
        .imem_req_valid(), .imem_req_ready(1'b0), .imem_req_addr(),
        .imem_rsp_valid(1'b0), .imem_rsp_ready(), .imem_rsp_rdata(32'd0),
        .imem_rsp_error(1'b0), .imem_fault(), .imem_fault_pc(),
        .dmem_req_valid(), .dmem_req_ready(1'b0), .dmem_req_write(),
        .dmem_req_addr(), .dmem_req_size(), .dmem_req_wdata(), .dmem_req_wstrb(),
        .dmem_rsp_valid(1'b0), .dmem_rsp_ready(), .dmem_rsp_rdata(32'd0),
        .dmem_rsp_error(1'b0), .dmem_fault(),
        .trap_valid(), .trap_pc(), .trap_cause(), .trap_tval()
    );
    // GPIO bit 1 = PASS, bit 0 = heartbeat, bit 2 = FAIL.
    assign led = !cpu_rst_n ? 8'h00 : (gpio_out & gpio_oe);
endmodule
