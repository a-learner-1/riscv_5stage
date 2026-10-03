// MES50HP entry point for the opt-in machine timer interrupt acceptance image.
// KEY1 resets CPU, instruction endpoint, AXI bridge/RAM protocol and MMIO.
// Completed RAM writes survive reset; software/start.S clears its own BSS.
module timer_irq_board_top #(
    parameter PROGRAM_FILE = "programs/timer_irq_board.hex",
    parameter DATA_FILE = "programs/timer_irq_board_data.hex",
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
    wire imem_fault, dmem_fault, trap_valid;
    wire [31:0] trap_pc, trap_cause, trap_tval;
    wire [7:0] gpio_out, gpio_oe;
    wire [31:0] awaddr, wdata, araddr, rdata;
    wire [2:0] awprot, arprot;
    wire [3:0] wstrb;
    wire [1:0] bresp, rresp;
    wire awvalid, awready, wvalid, wready, bvalid, bready;
    wire arvalid, arready, rvalid, rready;

    board_reset #(.HOLD_CYCLES(RESET_HOLD_CYCLES)) u_reset (
        .clk(clk_50m), .key1_n(key1_n), .cpu_rst_n(cpu_rst_n)
    );
    soc_axi_lite_top #(
        .PROGRAM_FILE(PROGRAM_FILE), .DATA_FILE(DATA_FILE),
        .IMEM_WORDS(8192), .DMEM_WORDS(4096),
        .DMEM_BASE_ADDR(32'h00010000), .ENABLE_TRAPS(1), .ENABLE_TIMER_IRQ(1),
        .UART_CLOCK_HZ(50000000), .UART_BAUD(115200),
        .SIM_CONSOLE_ECHO(0)
    ) u_soc (
        .clk(clk_50m), .rst_n(cpu_rst_n), .uart_rx(uart_rx), .uart_tx(uart_tx),
        .gpio_in({keys_n, key1_n}), .gpio_out(gpio_out), .gpio_oe(gpio_oe),
        .pc_x(), .instr_x(), .valid_x(), .wb_pc(), .wb_rd(), .wb_data(),
        .wb_we(), .retire_valid(), .cycle_count(), .instret_count(),
        .imem_fault(imem_fault), .imem_fault_pc(), .dmem_fault(dmem_fault),
        .m_axi_awaddr(awaddr), .m_axi_awprot(awprot),
        .m_axi_awvalid(awvalid), .m_axi_awready(awready),
        .m_axi_wdata(wdata), .m_axi_wstrb(wstrb),
        .m_axi_wvalid(wvalid), .m_axi_wready(wready),
        .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
        .m_axi_araddr(araddr), .m_axi_arprot(arprot),
        .m_axi_arvalid(arvalid), .m_axi_arready(arready),
        .m_axi_rdata(rdata), .m_axi_rresp(rresp),
        .m_axi_rvalid(rvalid), .m_axi_rready(rready),
        .trap_valid(trap_valid), .trap_pc(trap_pc),
        .trap_cause(trap_cause), .trap_tval(trap_tval)
    );
    axi_lite_ram #(
        .WORDS(4096), .BASE_ADDR(32'h00010000), .INIT_FILE(DATA_FILE)
    ) u_ram (
        .clk(clk_50m), .rst_n(cpu_rst_n),
        .s_axi_awaddr(awaddr), .s_axi_awprot(awprot),
        .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(arprot),
        .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp),
        .s_axi_rvalid(rvalid), .s_axi_rready(rready)
    );
    // A recoverable instruction error is pending trap state, not a board
    // failure latch. Software publishes PASS/FAIL after checking recovery.
    assign led = !cpu_rst_n ? 8'h00 : (gpio_out & gpio_oe);
endmodule
