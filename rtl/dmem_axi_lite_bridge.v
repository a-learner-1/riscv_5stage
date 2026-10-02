// Convert one CPU data request into one 32-bit AXI4-Lite transaction.
// CPU write data and strobes already select the proper byte lanes.
// Reset cancels protocol state. The AXI slave must share this reset;
// completed writes are not rolled back and slave RAM is not cleared here.
module dmem_axi_lite_bridge (
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
    localparam [2:0] IDLE       = 3'd0;
    localparam [2:0] SEND_WRITE = 3'd1;
    localparam [2:0] WAIT_B     = 3'd2;
    localparam [2:0] SEND_READ  = 3'd3;
    localparam [2:0] WAIT_R     = 3'd4;
    localparam [2:0] CPU_RSP    = 3'd5;

    reg [2:0] state;
    reg [31:0] addr_q;
    reg [31:0] wdata_q;
    reg [3:0] wstrb_q;
    reg aw_done;
    reg w_done;
    reg [31:0] rsp_rdata_q;
    reg rsp_error_q;

    // Size is a CPU-side property. AXI4-Lite reads a complete 32-bit word;
    // the CPU retains the original address offset for LB/LBU/LH/LHU.
    wire size_aligned = (req_size == 2'd0) ||
        ((req_size == 2'd1) && (req_addr[0] == 1'b0)) ||
        ((req_size == 2'd2) && (req_addr[1:0] == 2'b00));
    wire [3:0] expected_wstrb =
        (req_size == 2'd0) ? (4'b0001 << req_addr[1:0]) :
        (req_size == 2'd1) ? (4'b0011 << req_addr[1:0]) :
        (req_size == 2'd2) ? 4'b1111 : 4'b0000;
    wire request_ok = size_aligned &&
        (!req_write || (req_wstrb == expected_wstrb));

    assign req_ready = rst_n && (state == IDLE);
    assign rsp_valid = rst_n && (state == CPU_RSP);
    assign rsp_rdata = rsp_rdata_q;
    assign rsp_error = rsp_error_q;

    assign m_axi_awaddr = addr_q;
    assign m_axi_awprot = 3'b000;
    assign m_axi_wdata = wdata_q;
    assign m_axi_wstrb = wstrb_q;
    // Both VALID signals are asserted without looking at either READY.
    // The channels complete independently and each can handshake only once.
    assign m_axi_awvalid = rst_n && (state == SEND_WRITE) && !aw_done;
    assign m_axi_wvalid = rst_n && (state == SEND_WRITE) && !w_done;
    assign m_axi_bready = rst_n && (state == WAIT_B);
    assign m_axi_araddr = addr_q;
    assign m_axi_arprot = 3'b000;
    assign m_axi_arvalid = rst_n && (state == SEND_READ);
    assign m_axi_rready = rst_n && (state == WAIT_R);

    wire req_fire = req_valid && req_ready;
    wire aw_fire = m_axi_awvalid && m_axi_awready;
    wire w_fire = m_axi_wvalid && m_axi_wready;
    wire b_fire = m_axi_bvalid && m_axi_bready;
    wire ar_fire = m_axi_arvalid && m_axi_arready;
    wire r_fire = m_axi_rvalid && m_axi_rready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            addr_q <= 32'd0;
            wdata_q <= 32'd0;
            wstrb_q <= 4'd0;
            aw_done <= 1'b0;
            w_done <= 1'b0;
            rsp_rdata_q <= 32'd0;
            rsp_error_q <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    if (req_fire) begin
                        addr_q <= {req_addr[31:2], 2'b00};
                        wdata_q <= req_wdata;
                        wstrb_q <= req_wstrb;
                        aw_done <= 1'b0;
                        w_done <= 1'b0;
                        rsp_rdata_q <= 32'd0;
                        rsp_error_q <= 1'b0;
                        if (!request_ok) begin
                            // Invalid CPU requests never reach an AXI channel.
                            rsp_error_q <= 1'b1;
                            state <= CPU_RSP;
                        end else if (req_write) begin
                            state <= SEND_WRITE;
                        end else begin
                            state <= SEND_READ;
                        end
                    end
                end
                SEND_WRITE: begin
                    if (aw_fire)
                        aw_done <= 1'b1;
                    if (w_fire)
                        w_done <= 1'b1;
                    if ((aw_done || aw_fire) && (w_done || w_fire))
                        state <= WAIT_B;
                end
                WAIT_B: begin
                    if (b_fire) begin
                        rsp_rdata_q <= 32'd0;
                        // AXI4-Lite has no exclusive accesses: only OKAY is
                        // successful. All other response values report error.
                        case (m_axi_bresp)
                            2'b00: rsp_error_q <= 1'b0;
                            default: rsp_error_q <= 1'b1;
                        endcase
                        state <= CPU_RSP;
                    end
                end
                SEND_READ: begin
                    if (ar_fire)
                        state <= WAIT_R;
                end
                WAIT_R: begin
                    if (r_fire) begin
                        case (m_axi_rresp)
                            2'b00: begin
                                rsp_rdata_q <= m_axi_rdata;
                                rsp_error_q <= 1'b0;
                            end
                            default: begin
                                rsp_rdata_q <= 32'd0;
                                rsp_error_q <= 1'b1;
                            end
                        endcase
                        state <= CPU_RSP;
                    end
                end
                CPU_RSP: begin
                    // Keep response data/error stable during CPU backpressure.
                    // A new CPU request is accepted only after this completes.
                    if (rsp_ready)
                        state <= IDLE;
                end
                default: begin
                    state <= IDLE;
                    aw_done <= 1'b0;
                    w_done <= 1'b0;
                    rsp_rdata_q <= 32'd0;
                    rsp_error_q <= 1'b0;
                end
            endcase
        end
    end
endmodule
