// MES50HP (PGL50H-6IFBG484), no PLL, no external memory or external GPIO.
// clk_50m: P20; KEY1: K18; UART TX: R9; UART RX: R8. See pds/board_top.fdc.
// Dedicated active-high LEDs use OUT & OE; these are NOT bidirectional IOs.
module board_top #(
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

    cpu_top #(
        .PROGRAM_FILE(PROGRAM_FILE), .DATA_FILE(DATA_FILE),
        .IMEM_WORDS(8192), .DMEM_WORDS(4096),
        .DMEM_BASE_ADDR(32'h00010000),
        .UART_CLOCK_HZ(50000000), .UART_BAUD(115200),
        .SIM_CONSOLE_ECHO(0)
    ) u_cpu (
        .clk(clk_50m), .rst_n(cpu_rst_n),
        .pc_x(), .instr_x(), .valid_x(),
        .wb_pc(), .wb_rd(), .wb_data(), .wb_we(), .retire_valid(),
        .cycle_count(), .instret_count(), .uart_tx(uart_tx), .uart_rx(uart_rx),
        // GPIO bit 0 is KEY1; bits 1..7 are KEY2..KEY8, all active-low.
        .gpio_in({keys_n, key1_n}), .gpio_out(gpio_out), .gpio_oe(gpio_oe),
        // The minimum board demo uses the internal data-bus endpoint.
        .dmem_req_valid(), .dmem_req_ready(1'b0), .dmem_req_write(),
        .dmem_req_addr(), .dmem_req_size(), .dmem_req_wdata(), .dmem_req_wstrb(),
        .dmem_rsp_valid(1'b0), .dmem_rsp_ready(),
        .dmem_rsp_rdata(32'd0), .dmem_rsp_error(1'b0), .dmem_fault()
    );
    assign led = gpio_out & gpio_oe;
endmodule
