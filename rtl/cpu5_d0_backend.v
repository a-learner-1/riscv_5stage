// Independent CPU5 D0/native-to-AXI backend. All reused RTL stays unchanged.
// Ordinary RAM goes to local synchronous RAM only when explicitly enabled.
// Shared reset cancels protocol state; previously accepted writes persist.
module cpu5_d0_backend #(
    parameter integer ENABLE_D0_BRAM=0, DMEM_WORDS=4096,
    parameter [31:0] DMEM_BASE_ADDR=32'h00010000,
    parameter DATA_FILE="",
    parameter integer D0_REQ_WAIT_CYCLES=0, D0_RSP_WAIT_CYCLES=0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        req_valid,
    output wire        req_ready,
    input  wire        req_write,
    input  wire [31:0] req_addr,
    input  wire [1:0]  req_size,
    input  wire [31:0] req_wdata,
    input  wire [3:0]  req_wstrb,
    output wire        rsp_valid,
    input  wire        rsp_ready,
    output wire [31:0] rsp_rdata,
    output wire        rsp_error,

    output wire [31:0] m_axi_awaddr,
    output wire [2:0]  m_axi_awprot,
    output wire        m_axi_awvalid,
    input  wire        m_axi_awready,
    output wire [31:0] m_axi_wdata,
    output wire [3:0]  m_axi_wstrb,
    output wire        m_axi_wvalid,
    input  wire        m_axi_wready,
    input  wire [1:0]  m_axi_bresp,
    input  wire        m_axi_bvalid,
    output wire        m_axi_bready,
    output wire [31:0] m_axi_araddr,
    output wire [2:0]  m_axi_arprot,
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [31:0] m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rvalid,
    output wire        m_axi_rready
);
    wire axi_req_valid;
    wire axi_req_ready;
    wire axi_req_write;
    wire [31:0] axi_req_addr;
    wire [1:0] axi_req_size;
    wire [31:0] axi_req_wdata;
    wire [3:0] axi_req_wstrb;
    wire axi_rsp_valid;
    wire axi_rsp_ready;
    wire [31:0] axi_rsp_rdata;
    wire axi_rsp_error;
    generate if(ENABLE_D0_BRAM)begin:g_d0
        wire ram_req_valid;
        wire ram_req_ready;
        wire ram_req_write;
        wire [31:0] ram_req_addr;
        wire [1:0] ram_req_size;
        wire [31:0] ram_req_wdata;
        wire [3:0] ram_req_wstrb;
        wire ram_rsp_valid;
        wire ram_rsp_ready;
        wire [31:0] ram_rsp_rdata;
        wire ram_rsp_error;
        dmem_region_router #(.M0_BASE_ADDR(DMEM_BASE_ADDR),.M0_WORDS(DMEM_WORDS)) u_router(
            .clk(clk),
            .rst_n(rst_n),
            .req_valid(req_valid),
            .req_ready(req_ready),
            .req_write(req_write),
            .req_addr(req_addr),
            .req_size(req_size),
            .req_wdata(req_wdata),
            .req_wstrb(req_wstrb),
            .rsp_valid(rsp_valid),
            .rsp_ready(rsp_ready),
            .rsp_rdata(rsp_rdata),
            .rsp_error(rsp_error),
            .m0_req_valid(ram_req_valid),
            .m0_req_ready(ram_req_ready),
            .m0_req_write(ram_req_write),
            .m0_req_addr(ram_req_addr),
            .m0_req_size(ram_req_size),
            .m0_req_wdata(ram_req_wdata),
            .m0_req_wstrb(ram_req_wstrb),
            .m0_rsp_valid(ram_rsp_valid),
            .m0_rsp_ready(ram_rsp_ready),
            .m0_rsp_rdata(ram_rsp_rdata),
            .m0_rsp_error(ram_rsp_error),
            .m1_req_valid(axi_req_valid),
            .m1_req_ready(axi_req_ready),
            .m1_req_write(axi_req_write),
            .m1_req_addr(axi_req_addr),
            .m1_req_size(axi_req_size),
            .m1_req_wdata(axi_req_wdata),
            .m1_req_wstrb(axi_req_wstrb),
            .m1_rsp_valid(axi_rsp_valid),
            .m1_rsp_ready(axi_rsp_ready),
            .m1_rsp_rdata(axi_rsp_rdata),
            .m1_rsp_error(axi_rsp_error)
        );
        soc_data_mem #(.WORDS(DMEM_WORDS),.BASE_ADDR(DMEM_BASE_ADDR),.INIT_FILE(DATA_FILE),
            .REQ_WAIT_CYCLES(D0_REQ_WAIT_CYCLES),.RSP_WAIT_CYCLES(D0_RSP_WAIT_CYCLES)) u_ram(
            .clk(clk),
            .rst_n(rst_n),
            .req_valid(ram_req_valid),
            .req_ready(ram_req_ready),
            .req_write(ram_req_write),
            .req_addr(ram_req_addr),
            .req_size(ram_req_size),
            .req_wdata(ram_req_wdata),
            .req_wstrb(ram_req_wstrb),
            .rsp_valid(ram_rsp_valid),
            .rsp_ready(ram_rsp_ready),
            .rsp_rdata(ram_rsp_rdata),
            .rsp_error(ram_rsp_error)
        );
    end else begin:g_no_d0
        assign axi_req_valid=req_valid;
        assign req_ready=axi_req_ready;
        assign axi_req_write=req_write;
        assign axi_req_addr=req_addr;
        assign axi_req_size=req_size;
        assign axi_req_wdata=req_wdata;
        assign axi_req_wstrb=req_wstrb;
        assign rsp_valid=axi_rsp_valid;
        assign axi_rsp_ready=rsp_ready;
        assign rsp_rdata=axi_rsp_rdata;
        assign rsp_error=axi_rsp_error;
    end endgenerate
    dmem_axi_lite_bridge u_bridge(
        .clk(clk),
        .rst_n(rst_n),
        .req_valid(axi_req_valid),
        .req_ready(axi_req_ready),
        .req_write(axi_req_write),
        .req_addr(axi_req_addr),
        .req_size(axi_req_size),
        .req_wdata(axi_req_wdata),
        .req_wstrb(axi_req_wstrb),
        .rsp_valid(axi_rsp_valid),
        .rsp_ready(axi_rsp_ready),
        .rsp_rdata(axi_rsp_rdata),
        .rsp_error(axi_rsp_error),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awprot(m_axi_awprot),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arprot(m_axi_arprot),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready)
    );
    // synthesis translate_off
    initial if(ENABLE_D0_BRAM!=0 && ENABLE_D0_BRAM!=1)
        $fatal(1,"CPU5 D0 backend requires boolean D0 enable");
    // synthesis translate_on
endmodule
