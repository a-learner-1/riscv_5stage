// One AXI4-Lite manager, two memory-mapped subordinates. Addresses pass
// through unchanged. One read and one write may be outstanding independently.
// Every endpoint must share reset; reset cancels protocol state but does not
// roll back writes already performed by a subordinate.
module axi_lite_1x2 #(
    parameter [31:0] M0_BASE_ADDR = 32'h00010000,
    parameter [31:0] M0_SIZE_BYTES = 32'h00004000,
    parameter [31:0] M1_BASE_ADDR = 32'h30000000,
    parameter [31:0] M1_SIZE_BYTES = 32'h00000100
) (
    input wire clk,
    input wire rst_n,

    input wire [31:0] s_axi_awaddr,
    input wire [2:0] s_axi_awprot,
    input wire s_axi_awvalid,
    output wire s_axi_awready,
    input wire [31:0] s_axi_wdata,
    input wire [3:0] s_axi_wstrb,
    input wire s_axi_wvalid,
    output wire s_axi_wready,
    output wire [1:0] s_axi_bresp,
    output wire s_axi_bvalid,
    input wire s_axi_bready,
    input wire [31:0] s_axi_araddr,
    input wire [2:0] s_axi_arprot,
    input wire s_axi_arvalid,
    output wire s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire [1:0] s_axi_rresp,
    output wire s_axi_rvalid,
    input wire s_axi_rready,

    output wire [31:0] m0_axi_awaddr,
    output wire [2:0] m0_axi_awprot,
    output wire m0_axi_awvalid,
    input wire m0_axi_awready,
    output wire [31:0] m0_axi_wdata,
    output wire [3:0] m0_axi_wstrb,
    output wire m0_axi_wvalid,
    input wire m0_axi_wready,
    input wire [1:0] m0_axi_bresp,
    input wire m0_axi_bvalid,
    output wire m0_axi_bready,
    output wire [31:0] m0_axi_araddr,
    output wire [2:0] m0_axi_arprot,
    output wire m0_axi_arvalid,
    input wire m0_axi_arready,
    input wire [31:0] m0_axi_rdata,
    input wire [1:0] m0_axi_rresp,
    input wire m0_axi_rvalid,
    output wire m0_axi_rready,

    output wire [31:0] m1_axi_awaddr,
    output wire [2:0] m1_axi_awprot,
    output wire m1_axi_awvalid,
    input wire m1_axi_awready,
    output wire [31:0] m1_axi_wdata,
    output wire [3:0] m1_axi_wstrb,
    output wire m1_axi_wvalid,
    input wire m1_axi_wready,
    input wire [1:0] m1_axi_bresp,
    input wire m1_axi_bvalid,
    output wire m1_axi_bready,
    output wire [31:0] m1_axi_araddr,
    output wire [2:0] m1_axi_arprot,
    output wire m1_axi_arvalid,
    input wire m1_axi_arready,
    input wire [31:0] m1_axi_rdata,
    input wire [1:0] m1_axi_rresp,
    input wire m1_axi_rvalid,
    output wire m1_axi_rready
);
    localparam [32:0] M0_END = {1'b0, M0_BASE_ADDR} + {1'b0, M0_SIZE_BYTES};
    localparam [32:0] M1_END = {1'b0, M1_BASE_ADDR} + {1'b0, M1_SIZE_BYTES};
    localparam [1:0] ROUTE_0 = 2'd0, ROUTE_1 = 2'd1, ROUTE_MISS = 2'd2;
    localparam [1:0] W_COLLECT = 2'd0, W_SEND = 2'd1, W_WAIT = 2'd2, W_MISS = 2'd3;
    localparam [1:0] R_IDLE = 2'd0, R_SEND = 2'd1, R_WAIT = 2'd2, R_MISS = 2'd3;

    reg [1:0] write_state, read_state;
    reg aw_pending, w_pending;
    reg [31:0] awaddr_q, wdata_q, araddr_q;
    reg [2:0] awprot_q, arprot_q;
    reg [3:0] wstrb_q;
    reg [1:0] write_route, read_route;
    reg aw_sent, w_sent;

    function [1:0] decode_route;
        input [31:0] address;
        begin
            // Alignment and register legality are checked by the subordinate.
            if (({1'b0, address} >= {1'b0, M0_BASE_ADDR}) &&
                ({1'b0, address} < M0_END))
                decode_route = ROUTE_0;
            else if (({1'b0, address} >= {1'b0, M1_BASE_ADDR}) &&
                     ({1'b0, address} < M1_END))
                decode_route = ROUTE_1;
            else
                decode_route = ROUTE_MISS;
        end
    endfunction

    // Upstream slots are independent: W may arrive before AW. Once paired,
    // neither slot is reused until the corresponding B response is consumed.
    assign s_axi_awready = rst_n && (write_state == W_COLLECT) && !aw_pending;
    assign s_axi_wready = rst_n && (write_state == W_COLLECT) && !w_pending;
    assign s_axi_arready = rst_n && (read_state == R_IDLE);
    wire s_aw_fire = s_axi_awvalid && s_axi_awready;
    wire s_w_fire = s_axi_wvalid && s_axi_wready;
    wire s_ar_fire = s_axi_arvalid && s_axi_arready;

    assign m0_axi_awaddr = awaddr_q;
    assign m1_axi_awaddr = awaddr_q;
    assign m0_axi_awprot = awprot_q;
    assign m1_axi_awprot = awprot_q;
    assign m0_axi_wdata = wdata_q;
    assign m1_axi_wdata = wdata_q;
    assign m0_axi_wstrb = wstrb_q;
    assign m1_axi_wstrb = wstrb_q;
    assign m0_axi_awvalid = rst_n && (write_state == W_SEND) &&
        (write_route == ROUTE_0) && !aw_sent;
    assign m1_axi_awvalid = rst_n && (write_state == W_SEND) &&
        (write_route == ROUTE_1) && !aw_sent;
    assign m0_axi_wvalid = rst_n && (write_state == W_SEND) &&
        (write_route == ROUTE_0) && !w_sent;
    assign m1_axi_wvalid = rst_n && (write_state == W_SEND) &&
        (write_route == ROUTE_1) && !w_sent;
    wire m_aw_fire = (m0_axi_awvalid && m0_axi_awready) ||
                     (m1_axi_awvalid && m1_axi_awready);
    wire m_w_fire = (m0_axi_wvalid && m0_axi_wready) ||
                    (m1_axi_wvalid && m1_axi_wready);

    // Forward only the selected response. The route is held until upstream
    // consumption, so normal AXI response holding preserves the payload.
    assign s_axi_bvalid = rst_n &&
        ((write_state == W_MISS) || ((write_state == W_WAIT) &&
            (((write_route == ROUTE_0) && m0_axi_bvalid) ||
             ((write_route == ROUTE_1) && m1_axi_bvalid))));
    assign s_axi_bresp = (write_state == W_MISS) ? 2'b11 :
        (write_state == W_WAIT) ?
            ((write_route == ROUTE_0) ? m0_axi_bresp : m1_axi_bresp) : 2'b00;
    assign m0_axi_bready = rst_n && (write_state == W_WAIT) &&
        (write_route == ROUTE_0) && s_axi_bready;
    assign m1_axi_bready = rst_n && (write_state == W_WAIT) &&
        (write_route == ROUTE_1) && s_axi_bready;
    wire s_b_fire = s_axi_bvalid && s_axi_bready;

    assign m0_axi_araddr = araddr_q;
    assign m1_axi_araddr = araddr_q;
    assign m0_axi_arprot = arprot_q;
    assign m1_axi_arprot = arprot_q;
    assign m0_axi_arvalid = rst_n && (read_state == R_SEND) &&
        (read_route == ROUTE_0);
    assign m1_axi_arvalid = rst_n && (read_state == R_SEND) &&
        (read_route == ROUTE_1);
    wire m_ar_fire = (m0_axi_arvalid && m0_axi_arready) ||
                     (m1_axi_arvalid && m1_axi_arready);
    assign s_axi_rvalid = rst_n &&
        ((read_state == R_MISS) || ((read_state == R_WAIT) &&
            (((read_route == ROUTE_0) && m0_axi_rvalid) ||
             ((read_route == ROUTE_1) && m1_axi_rvalid))));
    assign s_axi_rdata = (read_state == R_WAIT) ?
        ((read_route == ROUTE_0) ? m0_axi_rdata : m1_axi_rdata) : 32'd0;
    assign s_axi_rresp = (read_state == R_MISS) ? 2'b11 :
        (read_state == R_WAIT) ?
            ((read_route == ROUTE_0) ? m0_axi_rresp : m1_axi_rresp) : 2'b00;
    assign m0_axi_rready = rst_n && (read_state == R_WAIT) &&
        (read_route == ROUTE_0) && s_axi_rready;
    assign m1_axi_rready = rst_n && (read_state == R_WAIT) &&
        (read_route == ROUTE_1) && s_axi_rready;
    wire s_r_fire = s_axi_rvalid && s_axi_rready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_state <= W_COLLECT;
            read_state <= R_IDLE;
            aw_pending <= 1'b0;
            w_pending <= 1'b0;
            awaddr_q <= 32'd0;
            awprot_q <= 3'd0;
            wdata_q <= 32'd0;
            wstrb_q <= 4'd0;
            araddr_q <= 32'd0;
            arprot_q <= 3'd0;
            write_route <= ROUTE_MISS;
            read_route <= ROUTE_MISS;
            aw_sent <= 1'b0;
            w_sent <= 1'b0;
        end else begin
            case (write_state)
                W_COLLECT: begin
                    if (s_aw_fire) begin
                        aw_pending <= 1'b1;
                        awaddr_q <= s_axi_awaddr;
                        awprot_q <= s_axi_awprot;
                    end
                    if (s_w_fire) begin
                        w_pending <= 1'b1;
                        wdata_q <= s_axi_wdata;
                        wstrb_q <= s_axi_wstrb;
                    end
                    if (aw_pending && w_pending) begin
                        write_route <= decode_route(awaddr_q);
                        aw_sent <= 1'b0;
                        w_sent <= 1'b0;
                        write_state <= (decode_route(awaddr_q) == ROUTE_MISS) ? W_MISS : W_SEND;
                    end
                end
                W_SEND: begin
                    // No READY-to-VALID dependency across either channel.
                    if (m_aw_fire) aw_sent <= 1'b1;
                    if (m_w_fire) w_sent <= 1'b1;
                    if ((aw_sent || m_aw_fire) && (w_sent || m_w_fire))
                        write_state <= W_WAIT;
                end
                W_WAIT, W_MISS: begin
                    if (s_b_fire) begin
                        write_state <= W_COLLECT;
                        aw_pending <= 1'b0;
                        w_pending <= 1'b0;
                        write_route <= ROUTE_MISS;
                        aw_sent <= 1'b0;
                        w_sent <= 1'b0;
                    end
                end
            endcase
            case (read_state)
                R_IDLE: begin
                    if (s_ar_fire) begin
                        araddr_q <= s_axi_araddr;
                        arprot_q <= s_axi_arprot;
                        read_route <= decode_route(s_axi_araddr);
                        read_state <= (decode_route(s_axi_araddr) == ROUTE_MISS) ? R_MISS : R_SEND;
                    end
                end
                R_SEND: begin
                    if (m_ar_fire) read_state <= R_WAIT;
                end
                R_WAIT, R_MISS: begin
                    if (s_r_fire) begin
                        read_state <= R_IDLE;
                        read_route <= ROUTE_MISS;
                    end
                end
            endcase
        end
    end

    // synthesis translate_off
    initial begin
        if (M0_SIZE_BYTES == 0 || M1_SIZE_BYTES == 0 ||
            M0_BASE_ADDR[1:0] != 0 || M1_BASE_ADDR[1:0] != 0 ||
            M0_SIZE_BYTES[1:0] != 0 || M1_SIZE_BYTES[1:0] != 0 ||
            M0_END > 33'h100000000 || M1_END > 33'h100000000 ||
            !((M0_END <= {1'b0, M1_BASE_ADDR}) ||
              (M1_END <= {1'b0, M0_BASE_ADDR})))
            $fatal(1, "axi_lite_1x2 ranges must be positive, aligned, disjoint and within 4 GiB");
    end
    // synthesis translate_on
endmodule
