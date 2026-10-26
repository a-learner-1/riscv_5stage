// Independent MES50HP CPU5 target. Geometry/ISA/clock/UART are fixed here.
// The PDS builder binds image paths and reset hold as localparams in board_top.
module cpu5_coremark_board_top #(
    parameter PROGRAM_FILE = "build/cpu5_s19/firmware/performance/program.hex",
    parameter DATA_FILE = "build/cpu5_s19/firmware/performance/program_data.hex",
    parameter integer RESET_HOLD_CYCLES = 50000
)(
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
    cpu5_stats_axi_lite_top #(
        .PROGRAM_FILE(PROGRAM_FILE), .DATA_FILE(DATA_FILE),
        .IMEM_WORDS(8192), .DMEM_WORDS(4096), .DMEM_BASE_ADDR(32'h00010000),
        .STATS_BASE_ADDR(32'h30000000), .TRAP_VECTOR(32'h00000100),
        .ENABLE_D0_BRAM(1), .D0_REQ_WAIT_CYCLES(0), .D0_RSP_WAIT_CYCLES(0),
        .ENABLE_ICACHE(1), .ICACHE_SETS(64), .ICACHE_LINE_WORDS(4),
        .ENABLE_DCACHE(1), .DCACHE_SETS(64), .DCACHE_LINE_WORDS(4),
        .ENABLE_BRANCH_PRED(1), .BTB_ENTRIES(64), .BRANCH_RESOLVE_IN_ID(0),
        .ENABLE_FORWARDING(1), .ENABLE_M(1),
        .UART_CLOCK_HZ(50000000), .UART_BAUD(115200),
        .UART_RX_FIFO_DEPTH(16), .SIM_CONSOLE_ECHO(0),
        .IMEM_REQ_WAIT_CYCLES(0), .IMEM_RSP_WAIT_CYCLES(0),
        .RAM_AW_WAIT_CYCLES(0), .RAM_W_WAIT_CYCLES(0), .RAM_AR_WAIT_CYCLES(0),
        .RAM_B_WAIT_CYCLES(0), .RAM_R_WAIT_CYCLES(0)
    ) u_soc (
        .clk(clk_50m), .rst_n(cpu_rst_n), .uart_rx(uart_rx), .uart_tx(uart_tx),
        .gpio_in({keys_n, key1_n}), .gpio_out(gpio_out), .gpio_oe(gpio_oe),
        .irq_external(1'b0), .irq_software(1'b0), .irq_timer(1'b0),
        .pc_x(), .instr_x(), .valid_x(), .wb_pc(), .wb_rd(), .wb_data(),
        .wb_we(), .retire_valid(), .cycle_count(), .instret_count(), .perf_cycle_events(),
        .imem_fault(), .imem_fault_pc(), .dmem_fault(),
        .trap_valid(), .trap_pc(), .trap_cause(), .trap_tval(),
        .icache_access_count(), .icache_hit_count(), .icache_miss_count(),
        .icache_refill_word_count(), .icache_error_count(),
        .dcache_access_count(), .dcache_hit_count(), .dcache_miss_count(),
        .dcache_refill_word_count(), .dcache_error_count(), .dcache_write_count(), .dcache_bypass_count(),
        .bp_lookup_count(), .bp_hit_count(), .bp_taken_count(), .bp_resolved_count(),
        .bp_mispredict_count(), .bp_direction_error_count(), .bp_target_error_count()
    );
    assign led = gpio_out & gpio_oe;
endmodule
