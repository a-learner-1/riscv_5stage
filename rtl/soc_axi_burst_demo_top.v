// Integrated CPU-controlled AXI4 read-subset demonstration, not a CNN.
// Ordinary data stays behind the existing D-cache + D0 synchronous BRAM.
// The old AXI-Lite master addresses only statistics and burst-reader CSRs.
module soc_axi_burst_demo_top #(
    parameter PROGRAM_FILE="programs/axi_burst_demo.hex",
    parameter DATA_FILE="programs/axi_burst_demo_data.hex",
    parameter integer IMEM_WORDS=8192,DMEM_WORDS=4096,
    parameter [31:0] DMEM_BASE_ADDR=32'h00010000,
    parameter integer UART_CLOCK_HZ=50000000,UART_BAUD=115200,UART_RX_FIFO_DEPTH=16,
    parameter integer SIM_CONSOLE_ECHO=0,
    parameter [31:0] STATS_BASE_ADDR=32'h30000000,CSR_BASE_ADDR=32'h30001000,
    parameter [31:0] BUFFER0_BASE_ADDR=32'h40000000,BUFFER1_BASE_ADDR=32'h40001000,
    parameter integer BUFFER_WORDS=1024
) (
    input wire clk,rst_n,uart_rx,input wire [7:0] gpio_in,
    output wire uart_tx,output wire [7:0] gpio_out,gpio_oe,
    output wire [31:0] pc_x,instr_x,output wire valid_x,
    output wire [31:0] wb_pc,wb_data,output wire [4:0] wb_rd,
    output wire wb_we,retire_valid,output wire [63:0] cycle_count,instret_count,
    output wire imem_fault,dmem_fault,output wire [31:0] imem_fault_pc,
    output wire trap_valid,output wire [31:0] trap_pc,trap_cause,trap_tval,
    output wire burst_busy,burst_done,burst_error
);
    wire [31:0] axi_awaddr;
    wire [2:0] axi_awprot;
    wire axi_awvalid;
    wire axi_awready;
    wire [31:0] axi_wdata;
    wire [3:0] axi_wstrb;
    wire axi_wvalid;
    wire axi_wready;
    wire [1:0] axi_bresp;
    wire axi_bvalid;
    wire axi_bready;
    wire [31:0] axi_araddr;
    wire [2:0] axi_arprot;
    wire axi_arvalid;
    wire axi_arready;
    wire [31:0] axi_rdata;
    wire [1:0] axi_rresp;
    wire axi_rvalid;
    wire axi_rready;
    wire [31:0] stats_awaddr;
    wire [2:0] stats_awprot;
    wire stats_awvalid;
    wire stats_awready;
    wire [31:0] stats_wdata;
    wire [3:0] stats_wstrb;
    wire stats_wvalid;
    wire stats_wready;
    wire [1:0] stats_bresp;
    wire stats_bvalid;
    wire stats_bready;
    wire [31:0] stats_araddr;
    wire [2:0] stats_arprot;
    wire stats_arvalid;
    wire stats_arready;
    wire [31:0] stats_rdata;
    wire [1:0] stats_rresp;
    wire stats_rvalid;
    wire stats_rready;
    wire [31:0] command_awaddr;
    wire [2:0] command_awprot;
    wire command_awvalid;
    wire command_awready;
    wire [31:0] command_wdata;
    wire [3:0] command_wstrb;
    wire command_wvalid;
    wire command_wready;
    wire [1:0] command_bresp;
    wire command_bvalid;
    wire command_bready;
    wire [31:0] command_araddr;
    wire [2:0] command_arprot;
    wire command_arvalid;
    wire command_arready;
    wire [31:0] command_rdata;
    wire [1:0] command_rresp;
    wire command_rvalid;
    wire command_rready;
    wire [31:0] burst_araddr;
    wire [2:0] burst_arprot;
    wire [7:0] burst_arlen;
    wire [2:0] burst_arsize;
    wire [1:0] burst_arburst;
    wire burst_arvalid;
    wire burst_arready;
    wire [31:0] burst_rdata;
    wire [1:0] burst_rresp;
    wire burst_rlast;
    wire burst_rvalid;
    wire burst_rready;
    wire [31:0] buffer0_araddr;
    wire [2:0] buffer0_arprot;
    wire [7:0] buffer0_arlen;
    wire [2:0] buffer0_arsize;
    wire [1:0] buffer0_arburst;
    wire buffer0_arvalid;
    wire buffer0_arready;
    wire [31:0] buffer0_rdata;
    wire [1:0] buffer0_rresp;
    wire buffer0_rlast;
    wire buffer0_rvalid;
    wire buffer0_rready;
    wire [31:0] buffer1_araddr;
    wire [2:0] buffer1_arprot;
    wire [7:0] buffer1_arlen;
    wire [2:0] buffer1_arsize;
    wire [1:0] buffer1_arburst;
    wire buffer1_arvalid;
    wire buffer1_arready;
    wire [31:0] buffer1_rdata;
    wire [1:0] buffer1_rresp;
    wire buffer1_rlast;
    wire buffer1_rvalid;
    wire buffer1_rready;
    wire [5:0] perf_cycle_events;
    wire [31:0] icache_access_count,icache_hit_count,icache_miss_count,icache_refill_word_count,icache_error_count,dcache_access_count,dcache_hit_count,dcache_miss_count,dcache_refill_word_count,dcache_error_count,dcache_write_count,dcache_bypass_count,bp_lookup_count,bp_hit_count,bp_taken_count,bp_resolved_count,bp_mispredict_count,bp_direction_error_count,bp_target_error_count;
    wire seed_valid,seed_ready,seed_error;
    wire [31:0] seed_addr,seed_wdata;
    wire [3:0] seed_wstrb;
    wire seed0_ready,seed0_error,seed1_ready,seed1_error;
    localparam [63:0] BUFFER0_END={32'd0,BUFFER0_BASE_ADDR}+64'd4*BUFFER_WORDS;
    localparam [63:0] BUFFER1_END={32'd0,BUFFER1_BASE_ADDR}+64'd4*BUFFER_WORDS;
    wire seed_select0=({32'd0,seed_addr}>={32'd0,BUFFER0_BASE_ADDR})&&({32'd0,seed_addr}<BUFFER0_END);
    wire seed_select1=({32'd0,seed_addr}>={32'd0,BUFFER1_BASE_ADDR})&&({32'd0,seed_addr}<BUFFER1_END);
    assign seed_ready=seed_select0?seed0_ready:seed_select1?seed1_ready:rst_n;
    assign seed_error=seed_select0?seed0_error:seed_select1?seed1_error:1'b1;

    soc_axi_lite_top #(
        .PROGRAM_FILE(PROGRAM_FILE),.DATA_FILE(DATA_FILE),.IMEM_WORDS(IMEM_WORDS),
        .DMEM_WORDS(DMEM_WORDS),.DMEM_BASE_ADDR(DMEM_BASE_ADDR),
        .UART_CLOCK_HZ(UART_CLOCK_HZ),.UART_BAUD(UART_BAUD),.UART_RX_FIFO_DEPTH(UART_RX_FIFO_DEPTH),
        .SIM_CONSOLE_ECHO(SIM_CONSOLE_ECHO),.ENABLE_TRAPS(1),.ENABLE_TIMER_IRQ(1),
        .ENABLE_ICACHE(1),.ICACHE_SETS(64),.ICACHE_LINE_WORDS(4),
        .ENABLE_DCACHE(1),.DCACHE_SETS(64),.DCACHE_LINE_WORDS(4),
        .ENABLE_D0_BRAM(1),.ENABLE_BRANCH_PRED(1),.BTB_ENTRIES(64)
    ) u_core (
        .clk(clk),.rst_n(rst_n),.uart_rx(uart_rx),.gpio_in(gpio_in),
        .uart_tx(uart_tx),.gpio_out(gpio_out),.gpio_oe(gpio_oe),
        .pc_x(pc_x),.instr_x(instr_x),.valid_x(valid_x),.wb_pc(wb_pc),.wb_data(wb_data),
        .wb_rd(wb_rd),.wb_we(wb_we),.retire_valid(retire_valid),.cycle_count(cycle_count),.instret_count(instret_count),
        .imem_fault(imem_fault),.imem_fault_pc(imem_fault_pc),.dmem_fault(dmem_fault),
        .trap_valid(trap_valid),.trap_pc(trap_pc),.trap_cause(trap_cause),.trap_tval(trap_tval),
        .perf_cycle_events(perf_cycle_events),.irq_external(1'b0),
        .icache_access_count(icache_access_count),
        .icache_hit_count(icache_hit_count),
        .icache_miss_count(icache_miss_count),
        .icache_refill_word_count(icache_refill_word_count),
        .icache_error_count(icache_error_count),
        .dcache_access_count(dcache_access_count),
        .dcache_hit_count(dcache_hit_count),
        .dcache_miss_count(dcache_miss_count),
        .dcache_refill_word_count(dcache_refill_word_count),
        .dcache_error_count(dcache_error_count),
        .dcache_write_count(dcache_write_count),
        .dcache_bypass_count(dcache_bypass_count),
        .bp_lookup_count(bp_lookup_count),
        .bp_hit_count(bp_hit_count),
        .bp_taken_count(bp_taken_count),
        .bp_resolved_count(bp_resolved_count),
        .bp_mispredict_count(bp_mispredict_count),
        .bp_direction_error_count(bp_direction_error_count),
        .bp_target_error_count(bp_target_error_count),
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
        .m_axi_rready(axi_rready)
    );
    axi_lite_1x2 #(
        .M0_BASE_ADDR(STATS_BASE_ADDR),.M0_SIZE_BYTES(32'h200),
        .M1_BASE_ADDR(CSR_BASE_ADDR),.M1_SIZE_BYTES(32'h100)
    ) u_lite_router (
        .clk(clk),.rst_n(rst_n),
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
        .m0_axi_awaddr(stats_awaddr),
        .m0_axi_awprot(stats_awprot),
        .m0_axi_awvalid(stats_awvalid),
        .m0_axi_awready(stats_awready),
        .m0_axi_wdata(stats_wdata),
        .m0_axi_wstrb(stats_wstrb),
        .m0_axi_wvalid(stats_wvalid),
        .m0_axi_wready(stats_wready),
        .m0_axi_bresp(stats_bresp),
        .m0_axi_bvalid(stats_bvalid),
        .m0_axi_bready(stats_bready),
        .m0_axi_araddr(stats_araddr),
        .m0_axi_arprot(stats_arprot),
        .m0_axi_arvalid(stats_arvalid),
        .m0_axi_arready(stats_arready),
        .m0_axi_rdata(stats_rdata),
        .m0_axi_rresp(stats_rresp),
        .m0_axi_rvalid(stats_rvalid),
        .m0_axi_rready(stats_rready),
        .m1_axi_awaddr(command_awaddr),
        .m1_axi_awprot(command_awprot),
        .m1_axi_awvalid(command_awvalid),
        .m1_axi_awready(command_awready),
        .m1_axi_wdata(command_wdata),
        .m1_axi_wstrb(command_wstrb),
        .m1_axi_wvalid(command_wvalid),
        .m1_axi_wready(command_wready),
        .m1_axi_bresp(command_bresp),
        .m1_axi_bvalid(command_bvalid),
        .m1_axi_bready(command_bready),
        .m1_axi_araddr(command_araddr),
        .m1_axi_arprot(command_arprot),
        .m1_axi_arvalid(command_arvalid),
        .m1_axi_arready(command_arready),
        .m1_axi_rdata(command_rdata),
        .m1_axi_rresp(command_rresp),
        .m1_axi_rvalid(command_rvalid),
        .m1_axi_rready(command_rready)
    );
    axi_lite_coremark_stats #(
        .BASE_ADDR(STATS_BASE_ADDR),.ENABLE_ICACHE(1),.ENABLE_DCACHE(1),
        .ENABLE_BRANCH_PRED(1),.BTB_ENTRIES(64),.ICACHE_SETS(64),.ICACHE_LINE_WORDS(4),
        .DCACHE_SETS(64),.DCACHE_LINE_WORDS(4),.DATA_BACKEND_ID(1)
    ) u_stats (
        .clk(clk),.rst_n(rst_n),.cycle_count(cycle_count),.instret_count(instret_count),
        .perf_cycle_events(perf_cycle_events),
        .icache_access_count(icache_access_count),
        .icache_hit_count(icache_hit_count),
        .icache_miss_count(icache_miss_count),
        .icache_refill_word_count(icache_refill_word_count),
        .icache_error_count(icache_error_count),
        .dcache_access_count(dcache_access_count),
        .dcache_hit_count(dcache_hit_count),
        .dcache_miss_count(dcache_miss_count),
        .dcache_refill_word_count(dcache_refill_word_count),
        .dcache_error_count(dcache_error_count),
        .dcache_write_count(dcache_write_count),
        .dcache_bypass_count(dcache_bypass_count),
        .bp_lookup_count(bp_lookup_count),
        .bp_hit_count(bp_hit_count),
        .bp_taken_count(bp_taken_count),
        .bp_resolved_count(bp_resolved_count),
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
    axi_lite_burst_reader #(.BASE_ADDR(CSR_BASE_ADDR)) u_reader (
        .clk(clk),.rst_n(rst_n),.busy(burst_busy),.done(burst_done),.error(burst_error),
        .seed_valid(seed_valid),.seed_ready(seed_ready),.seed_addr(seed_addr),
        .seed_wdata(seed_wdata),.seed_wstrb(seed_wstrb),.seed_error(seed_error),
        .s_axi_awaddr(command_awaddr),
        .s_axi_awprot(command_awprot),
        .s_axi_awvalid(command_awvalid),
        .s_axi_awready(command_awready),
        .s_axi_wdata(command_wdata),
        .s_axi_wstrb(command_wstrb),
        .s_axi_wvalid(command_wvalid),
        .s_axi_wready(command_wready),
        .s_axi_bresp(command_bresp),
        .s_axi_bvalid(command_bvalid),
        .s_axi_bready(command_bready),
        .s_axi_araddr(command_araddr),
        .s_axi_arprot(command_arprot),
        .s_axi_arvalid(command_arvalid),
        .s_axi_arready(command_arready),
        .s_axi_rdata(command_rdata),
        .s_axi_rresp(command_rresp),
        .s_axi_rvalid(command_rvalid),
        .s_axi_rready(command_rready),
        .m_axi_araddr(burst_araddr),
        .m_axi_arprot(burst_arprot),
        .m_axi_arlen(burst_arlen),
        .m_axi_arsize(burst_arsize),
        .m_axi_arburst(burst_arburst),
        .m_axi_arvalid(burst_arvalid),
        .m_axi_arready(burst_arready),
        .m_axi_rdata(burst_rdata),
        .m_axi_rresp(burst_rresp),
        .m_axi_rlast(burst_rlast),
        .m_axi_rvalid(burst_rvalid),
        .m_axi_rready(burst_rready)
    );
    axi4_read_1x2 #(
        .M0_BASE_ADDR(BUFFER0_BASE_ADDR),.M0_SIZE_BYTES(BUFFER_WORDS*4),
        .M1_BASE_ADDR(BUFFER1_BASE_ADDR),.M1_SIZE_BYTES(BUFFER_WORDS*4)
    ) u_burst_router (
        .clk(clk),.rst_n(rst_n),
        .s_axi_araddr(burst_araddr),
        .s_axi_arprot(burst_arprot),
        .s_axi_arlen(burst_arlen),
        .s_axi_arsize(burst_arsize),
        .s_axi_arburst(burst_arburst),
        .s_axi_arvalid(burst_arvalid),
        .s_axi_arready(burst_arready),
        .s_axi_rdata(burst_rdata),
        .s_axi_rresp(burst_rresp),
        .s_axi_rlast(burst_rlast),
        .s_axi_rvalid(burst_rvalid),
        .s_axi_rready(burst_rready),
        .m0_axi_araddr(buffer0_araddr),
        .m0_axi_arprot(buffer0_arprot),
        .m0_axi_arlen(buffer0_arlen),
        .m0_axi_arsize(buffer0_arsize),
        .m0_axi_arburst(buffer0_arburst),
        .m0_axi_arvalid(buffer0_arvalid),
        .m0_axi_arready(buffer0_arready),
        .m0_axi_rdata(buffer0_rdata),
        .m0_axi_rresp(buffer0_rresp),
        .m0_axi_rlast(buffer0_rlast),
        .m0_axi_rvalid(buffer0_rvalid),
        .m0_axi_rready(buffer0_rready),
        .m1_axi_araddr(buffer1_araddr),
        .m1_axi_arprot(buffer1_arprot),
        .m1_axi_arlen(buffer1_arlen),
        .m1_axi_arsize(buffer1_arsize),
        .m1_axi_arburst(buffer1_arburst),
        .m1_axi_arvalid(buffer1_arvalid),
        .m1_axi_arready(buffer1_arready),
        .m1_axi_rdata(buffer1_rdata),
        .m1_axi_rresp(buffer1_rresp),
        .m1_axi_rlast(buffer1_rlast),
        .m1_axi_rvalid(buffer1_rvalid),
        .m1_axi_rready(buffer1_rready)
    );
    axi4_read_ram #(.WORDS(BUFFER_WORDS),.BASE_ADDR(BUFFER0_BASE_ADDR),.INIT_FILE("")) u_buffer0 (
        .clk(clk),.rst_n(rst_n),.seed_valid(seed_valid&&seed_select0),.seed_ready(seed0_ready),
        .seed_addr(seed_addr),.seed_wdata(seed_wdata),.seed_wstrb(seed_wstrb),.seed_error(seed0_error),
        .s_axi_araddr(buffer0_araddr),
        .s_axi_arprot(buffer0_arprot),
        .s_axi_arlen(buffer0_arlen),
        .s_axi_arsize(buffer0_arsize),
        .s_axi_arburst(buffer0_arburst),
        .s_axi_arvalid(buffer0_arvalid),
        .s_axi_arready(buffer0_arready),
        .s_axi_rdata(buffer0_rdata),
        .s_axi_rresp(buffer0_rresp),
        .s_axi_rlast(buffer0_rlast),
        .s_axi_rvalid(buffer0_rvalid),
        .s_axi_rready(buffer0_rready)
    );
    axi4_read_ram #(.WORDS(BUFFER_WORDS),.BASE_ADDR(BUFFER1_BASE_ADDR),.INIT_FILE("")) u_buffer1 (
        .clk(clk),.rst_n(rst_n),.seed_valid(seed_valid&&seed_select1),.seed_ready(seed1_ready),
        .seed_addr(seed_addr),.seed_wdata(seed_wdata),.seed_wstrb(seed_wstrb),.seed_error(seed1_error),
        .s_axi_araddr(buffer1_araddr),
        .s_axi_arprot(buffer1_arprot),
        .s_axi_arlen(buffer1_arlen),
        .s_axi_arsize(buffer1_arsize),
        .s_axi_arburst(buffer1_arburst),
        .s_axi_arvalid(buffer1_arvalid),
        .s_axi_arready(buffer1_arready),
        .s_axi_rdata(buffer1_rdata),
        .s_axi_rresp(buffer1_rresp),
        .s_axi_rlast(buffer1_rlast),
        .s_axi_rvalid(buffer1_rvalid),
        .s_axi_rready(buffer1_rready)
    );
    // synthesis translate_off
    initial begin
        if(BUFFER_WORDS<=0||BUFFER_WORDS>1073741823||BUFFER0_END>64'h100000000||BUFFER1_END>64'h100000000)
            $fatal(1,"soc_axi_burst_demo_top invalid buffer range");
    end
    // synthesis translate_on
endmodule
