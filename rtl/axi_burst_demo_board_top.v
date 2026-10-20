// MES50HP CPU-commanded AXI4 read-burst demonstration. No CNN is attached.
// The normal CPU memory remains D0 BRAM behind the two-way D-Cache.
module axi_burst_demo_board_top #(
    parameter PROGRAM_FILE = "programs/axi_burst_demo_board.hex",
    parameter DATA_FILE = "programs/axi_burst_demo_board_data.hex",
    parameter integer RESET_HOLD_CYCLES = 50000
) (
    input wire clk_50m,
    input wire key1_n,
    input wire [6:0] keys_n,
    output wire [7:0] led,
    output wire uart_tx,
    input wire uart_rx
);
    wire cpu_rst_n, imem_fault, dmem_fault;
    wire burst_busy, burst_done, burst_error;
    wire [7:0] gpio_out, gpio_oe;
    board_reset #(.HOLD_CYCLES(RESET_HOLD_CYCLES)) u_reset (
        .clk(clk_50m), .key1_n(key1_n), .cpu_rst_n(cpu_rst_n)
    );
    soc_axi_burst_demo_top #(
        .PROGRAM_FILE(PROGRAM_FILE), .DATA_FILE(DATA_FILE),
        .IMEM_WORDS(8192), .DMEM_WORDS(4096), .DMEM_BASE_ADDR(32'h00010000),
        .UART_CLOCK_HZ(50000000), .UART_BAUD(115200), .UART_RX_FIFO_DEPTH(16),
        .SIM_CONSOLE_ECHO(0),
        .STATS_BASE_ADDR(32'h30000000), .CSR_BASE_ADDR(32'h30001000),
        .BUFFER0_BASE_ADDR(32'h40000000), .BUFFER1_BASE_ADDR(32'h40001000),
        .BUFFER_WORDS(1024)
    ) u_soc (
        .clk(clk_50m), .rst_n(cpu_rst_n), .uart_rx(uart_rx), .uart_tx(uart_tx),
        .gpio_in({keys_n, key1_n}), .gpio_out(gpio_out), .gpio_oe(gpio_oe),
        .pc_x(), .instr_x(), .valid_x(), .wb_pc(), .wb_rd(), .wb_data(), .wb_we(),
        .retire_valid(), .cycle_count(), .instret_count(),
        .imem_fault(imem_fault), .imem_fault_pc(), .dmem_fault(dmem_fault),
        .trap_valid(), .trap_pc(), .trap_cause(), .trap_tval(),
        .burst_busy(burst_busy), .burst_done(burst_done), .burst_error(burst_error)
    );
    // Software success/failure is observable on bits 1/2 and UART. The live
    // reader status also reaches LEDs, so the new fabric is never unobserved.
    assign led = !cpu_rst_n ? 8'h00 : imem_fault ? 8'h80 : dmem_fault ? 8'h40 :
                 ((gpio_out & gpio_oe & 8'h07) |
                  {2'b00, burst_error, burst_done, burst_busy, 3'b000});
endmodule
