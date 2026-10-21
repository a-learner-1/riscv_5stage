// MES50HP independent CoreMark AXI comparison target.
// Cache off/on and optional BTB use the same AXI memory topology/wait settings.
// KEY1 resets all protocol/cache state. Completed backing RAM writes persist;
// start_coremark.S reinitializes BSS on every boot. No IRQ is enabled in software.
module coremark_axi_board_top #(
    parameter PROGRAM_FILE = "programs/coremark_axi_cache_on_performance.hex",
    parameter DATA_FILE = "programs/coremark_axi_cache_on_performance_data.hex",
    parameter integer ENABLE_ICACHE = 1, ENABLE_DCACHE = 1,
    parameter integer ENABLE_BRANCH_PRED = 0, BTB_ENTRIES = 64,
    parameter integer UART_CLOCK_HZ = 50000000, UART_BAUD = 115200,
    parameter integer RESET_HOLD_CYCLES = 50000,
    parameter integer IMEM_REQ_WAIT_CYCLES = 0, IMEM_RSP_WAIT_CYCLES = 0,
    parameter integer MMIO_REQ_WAIT_CYCLES = 0, MMIO_RSP_WAIT_CYCLES = 0,
    parameter integer RAM_AW_WAIT_CYCLES = 0, RAM_W_WAIT_CYCLES = 0,
    parameter integer RAM_AR_WAIT_CYCLES = 0, RAM_B_WAIT_CYCLES = 0,
    parameter integer RAM_R_WAIT_CYCLES = 0,
    parameter integer ENABLE_D0_BRAM = 0,
    parameter integer ENABLE_M = 0
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
    soc_coremark_axi_top #(
        .PROGRAM_FILE(PROGRAM_FILE), .DATA_FILE(DATA_FILE),
        .IMEM_WORDS(8192), .DMEM_WORDS(4096), .DMEM_BASE_ADDR(32'h00010000),
        .STATS_BASE_ADDR(32'h30000000),
        .ENABLE_ICACHE(ENABLE_ICACHE), .ENABLE_DCACHE(ENABLE_DCACHE),
        .ENABLE_D0_BRAM(ENABLE_D0_BRAM),
        .ENABLE_M(ENABLE_M),
        .ENABLE_BRANCH_PRED(ENABLE_BRANCH_PRED), .BTB_ENTRIES(BTB_ENTRIES),
        .ICACHE_SETS(64), .ICACHE_LINE_WORDS(4),
        .DCACHE_SETS(64), .DCACHE_LINE_WORDS(4),
        .UART_CLOCK_HZ(UART_CLOCK_HZ), .UART_BAUD(UART_BAUD),
        .SIM_CONSOLE_ECHO(0),
        .IMEM_REQ_WAIT_CYCLES(IMEM_REQ_WAIT_CYCLES),
        .IMEM_RSP_WAIT_CYCLES(IMEM_RSP_WAIT_CYCLES),
        .MMIO_REQ_WAIT_CYCLES(MMIO_REQ_WAIT_CYCLES),
        .MMIO_RSP_WAIT_CYCLES(MMIO_RSP_WAIT_CYCLES),
        .RAM_AW_WAIT_CYCLES(RAM_AW_WAIT_CYCLES),
        .RAM_W_WAIT_CYCLES(RAM_W_WAIT_CYCLES),
        .RAM_AR_WAIT_CYCLES(RAM_AR_WAIT_CYCLES),
        .RAM_B_WAIT_CYCLES(RAM_B_WAIT_CYCLES),
        .RAM_R_WAIT_CYCLES(RAM_R_WAIT_CYCLES)
    ) u_soc (
        .clk(clk_50m), .rst_n(cpu_rst_n), .uart_rx(uart_rx), .uart_tx(uart_tx),
        .gpio_in({keys_n, key1_n}), .gpio_out(gpio_out), .gpio_oe(gpio_oe),
        .pc_x(), .instr_x(), .valid_x(),
        .wb_pc(), .wb_rd(), .wb_data(), .wb_we(), .retire_valid(),
        .cycle_count(), .instret_count(),
        .imem_fault(), .imem_fault_pc(), .dmem_fault(),
        .trap_valid(), .trap_pc(), .trap_cause(), .trap_tval(),
        .icache_access_count(), .icache_hit_count(), .icache_miss_count(),
        .icache_refill_word_count(), .icache_error_count(),
        .dcache_access_count(), .dcache_hit_count(), .dcache_miss_count(),
        .dcache_refill_word_count(), .dcache_error_count(),
        .dcache_write_count(), .dcache_bypass_count(),
        .bp_lookup_count(), .bp_hit_count(), .bp_taken_count(),
        .bp_resolved_count(), .bp_mispredict_count(),
        .bp_direction_error_count(), .bp_target_error_count()
    );
    assign led = !cpu_rst_n ? 8'h00 : (gpio_out & gpio_oe);
endmodule
