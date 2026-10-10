// Independent MES50HP machine external/software/timer IRQ demonstration.
// Internal AXI source drives a level; no additional board pin is required.
// Cache and BTB stay disabled. KEY1 resets source, CPU and bus protocol.
module machine_irq_board_top #(
    parameter PROGRAM_FILE = "programs/machine_irq_board.hex",
    parameter DATA_FILE = "programs/machine_irq_board_data.hex",
    parameter integer RESET_HOLD_CYCLES = 50000
) (
    input wire clk_50m, key1_n,
    input wire [6:0] keys_n,
    output wire [7:0] led,
    output wire uart_tx,
    input wire uart_rx
);
    wire cpu_rst_n, irq_external;
    wire imem_fault, dmem_fault, trap_valid;
    wire [31:0] trap_pc, trap_cause, trap_tval;
    wire [7:0] gpio_out, gpio_oe;
    wire [31:0] axi_awaddr, axi_wdata, axi_araddr, axi_rdata;
    wire [2:0] axi_awprot, axi_arprot;
    wire [3:0] axi_wstrb;
    wire [1:0] axi_bresp, axi_rresp;
    wire axi_awvalid, axi_awready, axi_wvalid, axi_wready, axi_bvalid, axi_bready;
    wire axi_arvalid, axi_arready, axi_rvalid, axi_rready;
    wire [31:0] ram_awaddr, ram_wdata, ram_araddr, ram_rdata;
    wire [2:0] ram_awprot, ram_arprot;
    wire [3:0] ram_wstrb;
    wire [1:0] ram_bresp, ram_rresp;
    wire ram_awvalid, ram_awready, ram_wvalid, ram_wready, ram_bvalid, ram_bready;
    wire ram_arvalid, ram_arready, ram_rvalid, ram_rready;
    wire [31:0] irq_awaddr, irq_wdata, irq_araddr, irq_rdata;
    wire [2:0] irq_awprot, irq_arprot;
    wire [3:0] irq_wstrb;
    wire [1:0] irq_bresp, irq_rresp;
    wire irq_awvalid, irq_awready, irq_wvalid, irq_wready, irq_bvalid, irq_bready;
    wire irq_arvalid, irq_arready, irq_rvalid, irq_rready;

    board_reset #(.HOLD_CYCLES(RESET_HOLD_CYCLES)) u_reset (
        .clk(clk_50m), .key1_n(key1_n), .cpu_rst_n(cpu_rst_n)
    );
    soc_axi_lite_top #(
        .PROGRAM_FILE(PROGRAM_FILE), .DATA_FILE(DATA_FILE),
        .IMEM_WORDS(8192), .DMEM_WORDS(4096), .DMEM_BASE_ADDR(32'h00010000),
        .ENABLE_TRAPS(1), .ENABLE_TIMER_IRQ(1),
        .ENABLE_EXTERNAL_IRQ(1), .ENABLE_SOFTWARE_IRQ(1),
        .ENABLE_ICACHE(0), .ENABLE_DCACHE(0), .ENABLE_BRANCH_PRED(0),
        .UART_CLOCK_HZ(50000000), .UART_BAUD(115200), .SIM_CONSOLE_ECHO(0)
    ) u_soc (
        .clk(clk_50m), .rst_n(cpu_rst_n), .irq_external(irq_external),
        .uart_rx(uart_rx), .uart_tx(uart_tx),
        .gpio_in({keys_n, key1_n}), .gpio_out(gpio_out), .gpio_oe(gpio_oe),
        .pc_x(), .instr_x(), .valid_x(), .wb_pc(), .wb_rd(), .wb_data(),
        .wb_we(), .retire_valid(), .cycle_count(), .instret_count(),
        .imem_fault(imem_fault), .imem_fault_pc(), .dmem_fault(dmem_fault),
        .trap_valid(trap_valid), .trap_pc(trap_pc), .trap_cause(trap_cause), .trap_tval(trap_tval),
        .m_axi_awaddr(axi_awaddr),
        .m_axi_awprot(axi_awprot),
        .m_axi_awvalid(axi_awvalid),
        .m_axi_awready(axi_awready),
        .m_axi_wdata(axi_wdata),
        .m_axi_wstrb(axi_wstrb),
        .m_axi_wvalid(axi_wvalid),
        .m_axi_wready(axi_wready),
        .m_axi_bresp(axi_bresp),
        .m_axi_bvalid(axi_bvalid),
        .m_axi_bready(axi_bready),
        .m_axi_araddr(axi_araddr),
        .m_axi_arprot(axi_arprot),
        .m_axi_arvalid(axi_arvalid),
        .m_axi_arready(axi_arready),
        .m_axi_rdata(axi_rdata),
        .m_axi_rresp(axi_rresp),
        .m_axi_rvalid(axi_rvalid),
        .m_axi_rready(axi_rready),
        .icache_access_count(), .icache_hit_count(), .icache_miss_count(),
        .icache_refill_word_count(), .icache_error_count(),
        .dcache_access_count(), .dcache_hit_count(), .dcache_miss_count(),
        .dcache_refill_word_count(), .dcache_error_count(), .dcache_write_count(), .dcache_bypass_count(),
        .bp_lookup_count(), .bp_hit_count(), .bp_taken_count(), .bp_resolved_count(),
        .bp_mispredict_count(), .bp_direction_error_count(), .bp_target_error_count()
    );
    axi_lite_1x2 #(
        .M0_BASE_ADDR(32'h00010000), .M0_SIZE_BYTES(16384),
        .M1_BASE_ADDR(32'h30000000), .M1_SIZE_BYTES(32'h100)
    ) u_router (
        .clk(clk_50m), .rst_n(cpu_rst_n),
        .s_axi_awaddr(axi_awaddr),
        .s_axi_awprot(axi_awprot),
        .s_axi_awvalid(axi_awvalid),
        .s_axi_awready(axi_awready),
        .s_axi_wdata(axi_wdata),
        .s_axi_wstrb(axi_wstrb),
        .s_axi_wvalid(axi_wvalid),
        .s_axi_wready(axi_wready),
        .s_axi_bresp(axi_bresp),
        .s_axi_bvalid(axi_bvalid),
        .s_axi_bready(axi_bready),
        .s_axi_araddr(axi_araddr),
        .s_axi_arprot(axi_arprot),
        .s_axi_arvalid(axi_arvalid),
        .s_axi_arready(axi_arready),
        .s_axi_rdata(axi_rdata),
        .s_axi_rresp(axi_rresp),
        .s_axi_rvalid(axi_rvalid),
        .s_axi_rready(axi_rready),
        .m0_axi_awaddr(ram_awaddr),
        .m0_axi_awprot(ram_awprot),
        .m0_axi_awvalid(ram_awvalid),
        .m0_axi_awready(ram_awready),
        .m0_axi_wdata(ram_wdata),
        .m0_axi_wstrb(ram_wstrb),
        .m0_axi_wvalid(ram_wvalid),
        .m0_axi_wready(ram_wready),
        .m0_axi_bresp(ram_bresp),
        .m0_axi_bvalid(ram_bvalid),
        .m0_axi_bready(ram_bready),
        .m0_axi_araddr(ram_araddr),
        .m0_axi_arprot(ram_arprot),
        .m0_axi_arvalid(ram_arvalid),
        .m0_axi_arready(ram_arready),
        .m0_axi_rdata(ram_rdata),
        .m0_axi_rresp(ram_rresp),
        .m0_axi_rvalid(ram_rvalid),
        .m0_axi_rready(ram_rready),
        .m1_axi_awaddr(irq_awaddr),
        .m1_axi_awprot(irq_awprot),
        .m1_axi_awvalid(irq_awvalid),
        .m1_axi_awready(irq_awready),
        .m1_axi_wdata(irq_wdata),
        .m1_axi_wstrb(irq_wstrb),
        .m1_axi_wvalid(irq_wvalid),
        .m1_axi_wready(irq_wready),
        .m1_axi_bresp(irq_bresp),
        .m1_axi_bvalid(irq_bvalid),
        .m1_axi_bready(irq_bready),
        .m1_axi_araddr(irq_araddr),
        .m1_axi_arprot(irq_arprot),
        .m1_axi_arvalid(irq_arvalid),
        .m1_axi_arready(irq_arready),
        .m1_axi_rdata(irq_rdata),
        .m1_axi_rresp(irq_rresp),
        .m1_axi_rvalid(irq_rvalid),
        .m1_axi_rready(irq_rready)
    );
    axi_lite_ram #(.WORDS(4096), .BASE_ADDR(32'h00010000), .INIT_FILE(DATA_FILE)) u_ram (
        .clk(clk_50m), .rst_n(cpu_rst_n),
        .s_axi_awaddr(ram_awaddr),
        .s_axi_awprot(ram_awprot),
        .s_axi_awvalid(ram_awvalid),
        .s_axi_awready(ram_awready),
        .s_axi_wdata(ram_wdata),
        .s_axi_wstrb(ram_wstrb),
        .s_axi_wvalid(ram_wvalid),
        .s_axi_wready(ram_wready),
        .s_axi_bresp(ram_bresp),
        .s_axi_bvalid(ram_bvalid),
        .s_axi_bready(ram_bready),
        .s_axi_araddr(ram_araddr),
        .s_axi_arprot(ram_arprot),
        .s_axi_arvalid(ram_arvalid),
        .s_axi_arready(ram_arready),
        .s_axi_rdata(ram_rdata),
        .s_axi_rresp(ram_rresp),
        .s_axi_rvalid(ram_rvalid),
        .s_axi_rready(ram_rready)
    );
    axi_lite_irq_demo #(.BASE_ADDR(32'h30000000)) u_irq_source (
        .clk(clk_50m), .rst_n(cpu_rst_n), .irq(irq_external),
        .s_axi_awaddr(irq_awaddr),
        .s_axi_awprot(irq_awprot),
        .s_axi_awvalid(irq_awvalid),
        .s_axi_awready(irq_awready),
        .s_axi_wdata(irq_wdata),
        .s_axi_wstrb(irq_wstrb),
        .s_axi_wvalid(irq_wvalid),
        .s_axi_wready(irq_wready),
        .s_axi_bresp(irq_bresp),
        .s_axi_bvalid(irq_bvalid),
        .s_axi_bready(irq_bready),
        .s_axi_araddr(irq_araddr),
        .s_axi_arprot(irq_arprot),
        .s_axi_arvalid(irq_arvalid),
        .s_axi_arready(irq_arready),
        .s_axi_rdata(irq_rdata),
        .s_axi_rresp(irq_rresp),
        .s_axi_rvalid(irq_rvalid),
        .s_axi_rready(irq_rready)
    );
    assign led = !cpu_rst_n ? 8'h00 : (gpio_out & gpio_oe);
endmodule

