// CPU5 schema4/profile2 system integration. No board/project references this top.
// Native synchronous instruction ROM; optional D0 RAM; external AXI RAM and
// read-triggered Stats through the unchanged AXI 1x2 router. Shared reset.
module cpu5_stats_axi_lite_top #(
    parameter PROGRAM_FILE="programs/rv32i_regression.hex", DATA_FILE="",
    parameter integer IMEM_WORDS=8192,DMEM_WORDS=4096,
    parameter [31:0] DMEM_BASE_ADDR=32'h10000,STATS_BASE_ADDR=32'h30000000,TRAP_VECTOR=32'h100,
    parameter integer ENABLE_ICACHE=0,ICACHE_SETS=64,ICACHE_LINE_WORDS=4,
    parameter integer ENABLE_DCACHE=0,DCACHE_SETS=64,DCACHE_LINE_WORDS=4,
    parameter integer ENABLE_BRANCH_PRED=0,BTB_ENTRIES=64,BRANCH_RESOLVE_IN_ID=0,ENABLE_FORWARDING=1,
    parameter integer UART_CLOCK_HZ=50000000,UART_BAUD=115200,UART_RX_FIFO_DEPTH=16,SIM_CONSOLE_ECHO=0,
    parameter integer IMEM_REQ_WAIT_CYCLES=0,IMEM_RSP_WAIT_CYCLES=0,
    parameter integer RAM_AW_WAIT_CYCLES=0,RAM_W_WAIT_CYCLES=0,RAM_AR_WAIT_CYCLES=0,
    parameter integer RAM_B_WAIT_CYCLES=0,RAM_R_WAIT_CYCLES=0,
    parameter integer ENABLE_D0_BRAM=0,D0_REQ_WAIT_CYCLES=0,D0_RSP_WAIT_CYCLES=0,ENABLE_M=1
)(
    input wire clk,rst_n,uart_rx, input wire [7:0] gpio_in,
    input wire irq_external,irq_software,irq_timer,
    output wire uart_tx, output wire [7:0] gpio_out,gpio_oe,
    output wire [31:0] pc_x,instr_x, output wire valid_x,
    output wire [31:0] wb_pc,wb_data, output wire [4:0] wb_rd,
    output wire wb_we,retire_valid, output wire [63:0] cycle_count,instret_count,
    output wire [9:0] perf_cycle_events,
    output wire imem_fault,dmem_fault, output wire [31:0] imem_fault_pc,
    output wire trap_valid, output wire [31:0] trap_pc,trap_cause,trap_tval,
    output wire [31:0] icache_access_count,icache_hit_count,icache_miss_count,icache_refill_word_count,icache_error_count,
    output wire [31:0] dcache_access_count,dcache_hit_count,dcache_miss_count,dcache_refill_word_count,dcache_error_count,dcache_write_count,dcache_bypass_count,
    output wire [31:0] bp_lookup_count,bp_hit_count,bp_taken_count,bp_resolved_count,bp_mispredict_count,bp_direction_error_count,bp_target_error_count
);
    wire imem_req_valid,imem_req_ready,imem_rsp_valid,imem_rsp_ready,imem_rsp_error;
    wire [31:0] imem_req_addr,imem_rsp_rdata;
    wire [31:0] axi_awaddr,axi_wdata,axi_araddr,axi_rdata;
    wire [2:0] axi_awprot,axi_arprot;
    wire [3:0] axi_wstrb;
    wire [1:0] axi_bresp,axi_rresp;
    wire axi_awvalid,axi_awready,axi_wvalid,axi_wready,
         axi_bvalid,axi_bready,axi_arvalid,axi_arready,axi_rvalid,axi_rready;
    wire [31:0] ram_awaddr,ram_wdata,ram_araddr,ram_rdata;
    wire [2:0] ram_awprot,ram_arprot;
    wire [3:0] ram_wstrb;
    wire [1:0] ram_bresp,ram_rresp;
    wire ram_awvalid,ram_awready,ram_wvalid,ram_wready,
         ram_bvalid,ram_bready,ram_arvalid,ram_arready,ram_rvalid,ram_rready;
    wire [31:0] stats_awaddr,stats_wdata,stats_araddr,stats_rdata;
    wire [2:0] stats_awprot,stats_arprot;
    wire [3:0] stats_wstrb;
    wire [1:0] stats_bresp,stats_rresp;
    wire stats_awvalid,stats_awready,stats_wvalid,stats_wready,
         stats_bvalid,stats_bready,stats_arvalid,stats_arready,stats_rvalid,stats_rready;
    soc_instr_mem #(.WORDS(IMEM_WORDS),.INIT_FILE(PROGRAM_FILE),
        .REQ_WAIT_CYCLES(IMEM_REQ_WAIT_CYCLES),.RSP_WAIT_CYCLES(IMEM_RSP_WAIT_CYCLES)) u_instr_mem(
        .clk(clk),.rst_n(rst_n),.req_valid(imem_req_valid),.req_ready(imem_req_ready),.req_addr(imem_req_addr),
        .rsp_valid(imem_rsp_valid),.rsp_ready(imem_rsp_ready),.rsp_rdata(imem_rsp_rdata),.rsp_error(imem_rsp_error));
    cpu5_d0_axi_lite_top #(
        .PROGRAM_FILE(PROGRAM_FILE),.DATA_FILE(DATA_FILE),.IMEM_WORDS(IMEM_WORDS),
        .DMEM_WORDS(DMEM_WORDS),.DMEM_BASE_ADDR(DMEM_BASE_ADDR),
        .SKELETON_ONLY(0),.ENABLE_FORWARDING(ENABLE_FORWARDING),.ENABLE_CONTROL_FLOW(1),
        .ENABLE_RAM(1),.ENABLE_MMIO(1),.ENABLE_SYNC_TRAPS(1),.ENABLE_CSR(1),.ENABLE_RV32M(ENABLE_M),.ENABLE_M(ENABLE_M),
        .ENABLE_FENCE(1),.ENABLE_EXTERNAL_IRQ(1),.ENABLE_SOFTWARE_IRQ(1),.ENABLE_TIMER_IRQ(1),
        .ENABLE_TIMER_DEVICE(1),.ENABLE_SOFTWARE_DEVICE(1),.TRAP_VECTOR(TRAP_VECTOR),
        .BRANCH_RESOLVE_IN_ID(BRANCH_RESOLVE_IN_ID),
        .UART_CLOCK_HZ(UART_CLOCK_HZ),.UART_BAUD(UART_BAUD),.UART_RX_FIFO_DEPTH(UART_RX_FIFO_DEPTH),
        .SIM_CONSOLE_ECHO(SIM_CONSOLE_ECHO),.ENABLE_ICACHE(ENABLE_ICACHE),
        .ICACHE_SETS(ICACHE_SETS),.ICACHE_LINE_WORDS(ICACHE_LINE_WORDS),
        .ENABLE_DCACHE(ENABLE_DCACHE),.DCACHE_SETS(DCACHE_SETS),.DCACHE_LINE_WORDS(DCACHE_LINE_WORDS),
        .ENABLE_D0_BRAM(ENABLE_D0_BRAM),.D0_REQ_WAIT_CYCLES(D0_REQ_WAIT_CYCLES),.D0_RSP_WAIT_CYCLES(D0_RSP_WAIT_CYCLES),
        .ENABLE_BRANCH_PRED(ENABLE_BRANCH_PRED),.BTB_ENTRIES(BTB_ENTRIES)
    ) u_core (
        .irq_external(irq_external),.irq_software(irq_software),.irq_timer(irq_timer),
        .imem_req_valid(imem_req_valid),.imem_req_ready(imem_req_ready),.imem_req_addr(imem_req_addr),
        .imem_rsp_valid(imem_rsp_valid),.imem_rsp_ready(imem_rsp_ready),.imem_rsp_rdata(imem_rsp_rdata),.imem_rsp_error(imem_rsp_error),
        .clk(clk),.rst_n(rst_n),.uart_rx(uart_rx),.uart_tx(uart_tx),
        .gpio_in(gpio_in),.gpio_out(gpio_out),.gpio_oe(gpio_oe),
        .pc_x(pc_x),.instr_x(instr_x),.valid_x(valid_x),
        .wb_pc(wb_pc),.wb_rd(wb_rd),.wb_data(wb_data),.wb_we(wb_we),.retire_valid(retire_valid),
        .cycle_count(cycle_count),.instret_count(instret_count),
        .perf_cycle_events(perf_cycle_events),
        .imem_fault(imem_fault),.imem_fault_pc(imem_fault_pc),.dmem_fault(dmem_fault),
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
        .trap_valid(trap_valid), .trap_pc(trap_pc), .trap_cause(trap_cause), .trap_tval(trap_tval),
        .icache_access_count(icache_access_count),.icache_hit_count(icache_hit_count),.icache_miss_count(icache_miss_count),
        .icache_refill_word_count(icache_refill_word_count),.icache_error_count(icache_error_count),
        .dcache_access_count(dcache_access_count),.dcache_hit_count(dcache_hit_count),.dcache_miss_count(dcache_miss_count),.dcache_refill_word_count(dcache_refill_word_count),.dcache_error_count(dcache_error_count),.dcache_write_count(dcache_write_count),.dcache_bypass_count(dcache_bypass_count),
        .bp_lookup_count(bp_lookup_count), .bp_hit_count(bp_hit_count),
        .bp_taken_count(bp_taken_count), .bp_resolved_count(bp_resolved_count),
        .bp_mispredict_count(bp_mispredict_count),
        .bp_direction_error_count(bp_direction_error_count),
        .bp_target_error_count(bp_target_error_count)
    );
    axi_lite_1x2 #(.M0_BASE_ADDR(DMEM_BASE_ADDR),.M0_SIZE_BYTES(DMEM_WORDS*4),
        .M1_BASE_ADDR(STATS_BASE_ADDR),.M1_SIZE_BYTES(32'h200)
    ) u_router (.clk(clk),.rst_n(rst_n),
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
        .m1_axi_awaddr(stats_awaddr),
        .m1_axi_awprot(stats_awprot),
        .m1_axi_awvalid(stats_awvalid),
        .m1_axi_awready(stats_awready),
        .m1_axi_wdata(stats_wdata),
        .m1_axi_wstrb(stats_wstrb),
        .m1_axi_wvalid(stats_wvalid),
        .m1_axi_wready(stats_wready),
        .m1_axi_bresp(stats_bresp),
        .m1_axi_bvalid(stats_bvalid),
        .m1_axi_bready(stats_bready),
        .m1_axi_araddr(stats_araddr),
        .m1_axi_arprot(stats_arprot),
        .m1_axi_arvalid(stats_arvalid),
        .m1_axi_arready(stats_arready),
        .m1_axi_rdata(stats_rdata),
        .m1_axi_rresp(stats_rresp),
        .m1_axi_rvalid(stats_rvalid),
        .m1_axi_rready(stats_rready)
    );
    // Preserve the legacy u_ram hierarchy and exact default topology. D0
    // intercepts the entire RAM range before AXI, so disable this endpoint
    // statically and reduce its unused backing array to a single zero word.
    axi_lite_ram #(.WORDS(ENABLE_D0_BRAM ? 1 : DMEM_WORDS),.BASE_ADDR(DMEM_BASE_ADDR),
        .INIT_FILE(ENABLE_D0_BRAM ? "" : DATA_FILE),
        .AW_WAIT_CYCLES(RAM_AW_WAIT_CYCLES),.W_WAIT_CYCLES(RAM_W_WAIT_CYCLES),
        .AR_WAIT_CYCLES(RAM_AR_WAIT_CYCLES),.B_WAIT_CYCLES(RAM_B_WAIT_CYCLES),.R_WAIT_CYCLES(RAM_R_WAIT_CYCLES)
    ) u_ram (.clk(clk),.rst_n(rst_n),
        .s_axi_awaddr(ram_awaddr),
        .s_axi_awprot(ram_awprot),
        .s_axi_awvalid(ram_awvalid && (ENABLE_D0_BRAM == 0)),
        .s_axi_awready(ram_awready),
        .s_axi_wdata(ram_wdata),
        .s_axi_wstrb(ram_wstrb),
        .s_axi_wvalid(ram_wvalid && (ENABLE_D0_BRAM == 0)),
        .s_axi_wready(ram_wready),
        .s_axi_bresp(ram_bresp),
        .s_axi_bvalid(ram_bvalid),
        .s_axi_bready(ram_bready),
        .s_axi_araddr(ram_araddr),
        .s_axi_arprot(ram_arprot),
        .s_axi_arvalid(ram_arvalid && (ENABLE_D0_BRAM == 0)),
        .s_axi_arready(ram_arready),
        .s_axi_rdata(ram_rdata),
        .s_axi_rresp(ram_rresp),
        .s_axi_rvalid(ram_rvalid),
        .s_axi_rready(ram_rready)
    );
    axi_lite_cpu5_stats #(
        .BASE_ADDR(STATS_BASE_ADDR), .ENABLE_ICACHE(ENABLE_ICACHE), .ENABLE_DCACHE(ENABLE_DCACHE),
        .DATA_BACKEND_ID(ENABLE_D0_BRAM ? 1 : 0),
        .ENABLE_BRANCH_PRED(ENABLE_BRANCH_PRED), .BTB_ENTRIES(BTB_ENTRIES),
        .ICACHE_SETS(ICACHE_SETS), .ICACHE_LINE_WORDS(ICACHE_LINE_WORDS),
        .DCACHE_SETS(DCACHE_SETS), .DCACHE_LINE_WORDS(DCACHE_LINE_WORDS)
    ) u_stats (.clk(clk),.rst_n(rst_n),
        .cycle_count(cycle_count), .instret_count(instret_count),
        .perf_cycle_events(perf_cycle_events),
        .icache_access_count(icache_access_count), .icache_hit_count(icache_hit_count),
        .icache_miss_count(icache_miss_count), .icache_refill_word_count(icache_refill_word_count),
        .icache_error_count(icache_error_count),
        .dcache_access_count(dcache_access_count), .dcache_hit_count(dcache_hit_count),
        .dcache_miss_count(dcache_miss_count), .dcache_refill_word_count(dcache_refill_word_count),
        .dcache_error_count(dcache_error_count), .dcache_write_count(dcache_write_count),
        .dcache_bypass_count(dcache_bypass_count),
        .bp_lookup_count(bp_lookup_count), .bp_hit_count(bp_hit_count),
        .bp_taken_count(bp_taken_count), .bp_resolved_count(bp_resolved_count),
        .bp_mispredict_count(bp_mispredict_count),
        .bp_direction_error_count(bp_direction_error_count),
        .bp_target_error_count(bp_target_error_count),
        .s_axi_awaddr(stats_awaddr),
        .s_axi_awprot(stats_awprot),
        .s_axi_awvalid(stats_awvalid),
        .s_axi_awready(stats_awready),
        .s_axi_wdata(stats_wdata),
        .s_axi_wstrb(stats_wstrb),
        .s_axi_wvalid(stats_wvalid),
        .s_axi_wready(stats_wready),
        .s_axi_bresp(stats_bresp),
        .s_axi_bvalid(stats_bvalid),
        .s_axi_bready(stats_bready),
        .s_axi_araddr(stats_araddr),
        .s_axi_arprot(stats_arprot),
        .s_axi_arvalid(stats_arvalid),
        .s_axi_arready(stats_arready),
        .s_axi_rdata(stats_rdata),
        .s_axi_rresp(stats_rresp),
        .s_axi_rvalid(stats_rvalid),
        .s_axi_rready(stats_rready)
    );
    // synthesis translate_off
    initial begin
        if(DMEM_WORDS <= 0 || DMEM_WORDS > 1073741823)
            $fatal(1,"cpu5_stats_axi_lite_top invalid RAM size");
        if(({32'd0,STATS_BASE_ADDR}<64'h20000100) &&
           (({32'd0,STATS_BASE_ADDR}+64'h200)>64'h20000000))
            $fatal(1,"CPU5 statistics window overlaps CPU-local MMIO");
    end
    // synthesis translate_on
endmodule
