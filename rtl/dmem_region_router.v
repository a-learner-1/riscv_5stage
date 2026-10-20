// Single-outstanding native data router for the SoC data-cache backend.
// The ordinary RAM range uses m0; all other addresses use m1 (AXI bridge).
// Endpoints must capture a request at its handshake, hold a response until
// consumed, and share reset. Reset cancels protocol state, not RAM writes.
module dmem_region_router #(
    parameter [31:0] M0_BASE_ADDR = 32'h00010000,
    parameter integer M0_WORDS = 4096
) (
    input wire clk, rst_n,
    input wire req_valid, output wire req_ready,
    input wire req_write, input wire [31:0] req_addr,
    input wire [1:0] req_size, input wire [31:0] req_wdata,
    input wire [3:0] req_wstrb,
    output wire rsp_valid, input wire rsp_ready,
    output wire [31:0] rsp_rdata, output wire rsp_error,

    output wire m0_req_valid, input wire m0_req_ready,
    output wire m0_req_write, output wire [31:0] m0_req_addr,
    output wire [1:0] m0_req_size, output wire [31:0] m0_req_wdata,
    output wire [3:0] m0_req_wstrb,
    input wire m0_rsp_valid, output wire m0_rsp_ready,
    input wire [31:0] m0_rsp_rdata, input wire m0_rsp_error,

    output wire m1_req_valid, input wire m1_req_ready,
    output wire m1_req_write, output wire [31:0] m1_req_addr,
    output wire [1:0] m1_req_size, output wire [31:0] m1_req_wdata,
    output wire [3:0] m1_req_wstrb,
    input wire m1_rsp_valid, output wire m1_rsp_ready,
    input wire [31:0] m1_rsp_rdata, input wire m1_rsp_error
);
    localparam [63:0] M0_END_ADDR = {32'd0, M0_BASE_ADDR} + 64'd4 * M0_WORDS;
    wire select_m0 = ({32'd0, req_addr} >= {32'd0, M0_BASE_ADDR}) &&
                     ({32'd0, req_addr} < M0_END_ADDR);
    reg active;
    reg target_q;

    // Decode participates only in request acceptance. Once accepted, live
    // upstream address/data may change without redirecting its response.
    assign req_ready = rst_n && !active &&
                       (select_m0 ? m0_req_ready : m1_req_ready);
    assign m0_req_valid = rst_n && !active && req_valid && select_m0;
    assign m1_req_valid = rst_n && !active && req_valid && !select_m0;
    assign m0_req_write = req_write, m1_req_write = req_write;
    assign m0_req_addr = req_addr, m1_req_addr = req_addr;
    assign m0_req_size = req_size, m1_req_size = req_size;
    assign m0_req_wdata = req_wdata, m1_req_wdata = req_wdata;
    assign m0_req_wstrb = req_wstrb, m1_req_wstrb = req_wstrb;

    // Unsolicited and unselected responses are neither exposed nor consumed.
    // No response register is added: a synchronous endpoint remains one beat.
    assign rsp_valid = rst_n && active && (target_q ? m1_rsp_valid : m0_rsp_valid);
    assign rsp_rdata = active ? (target_q ? m1_rsp_rdata : m0_rsp_rdata) : 32'd0;
    assign rsp_error = active && (target_q ? m1_rsp_error : m0_rsp_error);
    assign m0_rsp_ready = rst_n && active && !target_q && rsp_ready;
    assign m1_rsp_ready = rst_n && active && target_q && rsp_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 1'b0;
            target_q <= 1'b0;
        end else if (active) begin
            if (rsp_valid && rsp_ready)
                active <= 1'b0;
        end else if (req_valid && req_ready) begin
            active <= 1'b1;
            target_q <= !select_m0;
        end
    end

    // synthesis translate_off
    initial begin
        if (M0_WORDS <= 0 || M0_BASE_ADDR[1:0] != 0 || M0_END_ADDR > 64'h100000000)
            $fatal(1, "dmem_region_router requires a positive, aligned, non-wrapping RAM range");
    end
    // synthesis translate_on
endmodule
