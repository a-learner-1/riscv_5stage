// MES50HP entry point for the opt-in machine timer interrupt acceptance image.
// KEY1 resets CPU, instruction endpoint, AXI bridge/RAM protocol and MMIO.
// Completed RAM writes survive reset; software/start.S clears its own BSS.
module icache_board_top #(
    parameter PROGRAM_FILE = "programs/icache_board.hex",
    parameter DATA_FILE = "programs/icache_board_data.hex",
    parameter integer RESET_HOLD_CYCLES = 50000,
    parameter integer IMEM_REQ_WAIT_CYCLES=0, IMEM_RSP_WAIT_CYCLES=0
) (
    input  wire       clk_50m,
    input  wire       key1_n,
    input  wire [6:0] keys_n,
    output wire [7:0] led,
    output wire       uart_tx,
    input  wire       uart_rx
);
    wire cpu_rst_n;
    wire imem_fault, dmem_fault, trap_valid;
    wire [31:0] trap_pc, trap_cause, trap_tval;
    wire [7:0] gpio_out, gpio_oe;
    wire [31:0] icache_access_count,icache_hit_count,icache_miss_count,icache_refill_word_count,icache_error_count;
    board_reset #(.HOLD_CYCLES(RESET_HOLD_CYCLES)) u_reset (
        .clk(clk_50m), .key1_n(key1_n), .cpu_rst_n(cpu_rst_n)
    );
    soc_icache_stats_top #(
        .PROGRAM_FILE(PROGRAM_FILE), .DATA_FILE(DATA_FILE),
        .IMEM_WORDS(8192), .DMEM_WORDS(4096),
        .DMEM_BASE_ADDR(32'h00010000), .ENABLE_ICACHE(1),
        .IMEM_REQ_WAIT_CYCLES(IMEM_REQ_WAIT_CYCLES),.IMEM_RSP_WAIT_CYCLES(IMEM_RSP_WAIT_CYCLES),
        .UART_CLOCK_HZ(50000000), .UART_BAUD(115200),
        .SIM_CONSOLE_ECHO(0)
    ) u_soc (
        .clk(clk_50m), .rst_n(cpu_rst_n), .uart_rx(uart_rx), .uart_tx(uart_tx),
        .gpio_in({keys_n, key1_n}), .gpio_out(gpio_out), .gpio_oe(gpio_oe),
        .pc_x(), .instr_x(), .valid_x(), .wb_pc(), .wb_rd(), .wb_data(),
        .wb_we(), .retire_valid(), .cycle_count(), .instret_count(),
        .imem_fault(imem_fault), .imem_fault_pc(), .dmem_fault(dmem_fault),
        .icache_access_count(icache_access_count),.icache_hit_count(icache_hit_count),.icache_miss_count(icache_miss_count),
        .icache_refill_word_count(icache_refill_word_count),.icache_error_count(icache_error_count),
        .trap_valid(trap_valid), .trap_pc(trap_pc),
        .trap_cause(trap_cause), .trap_tval(trap_tval)
    );
    // A recoverable instruction error is pending trap state, not a board
    // failure latch. Software publishes PASS/FAIL after checking recovery.
    assign led = !cpu_rst_n ? 8'h00 : (gpio_out & gpio_oe);
endmodule
