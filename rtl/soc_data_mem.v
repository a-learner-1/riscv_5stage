// CPU-external FPGA RAM endpoint. Accepted writes happen once, on req_fire.
// Reset cancels protocol state, but never clears RAM or rolls back a write.
module soc_data_mem #(
    parameter integer WORDS = 4096,
    parameter [31:0] BASE_ADDR = 32'h00010000,
    parameter INIT_FILE = "programs/c_demo_data.hex",
    parameter integer REQ_WAIT_CYCLES = 0,
    parameter integer RSP_WAIT_CYCLES = 0
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
    output wire        rsp_error
);
    wire req_fire = req_valid && req_ready;
    wire mem_access_ok;
    wire [31:0] ram_rdata, adapter_rdata;
    wire [3:0] expected_wstrb =
        (req_size == 2'd0) ? (4'b0001 << req_addr[1:0]) :
        (req_size == 2'd1) ? (4'b0011 << req_addr[1:0]) :
        (req_size == 2'd2) ? 4'b1111 : 4'b0000;
    wire request_ok = mem_access_ok &&
                      (!req_write || req_wstrb == expected_wstrb);
    wire mem_re = rst_n && req_fire && !req_write && request_ok;
    wire mem_we = rst_n && req_fire && req_write && request_ok;

    data_mem #(
        .WORDS(WORDS), .BASE_ADDR(BASE_ADDR), .INIT_FILE(INIT_FILE)
    ) u_data_mem (
        .clk(clk), .re(mem_re), .we(mem_we),
        .addr(req_addr), .size(req_size),
        .wdata(req_wdata), .wstrb(req_wstrb),
        .rdata(ram_rdata), .access_ok(mem_access_ok)
    );
    data_bus_adapter #(
        .REQ_WAIT_CYCLES(REQ_WAIT_CYCLES), .RSP_WAIT_CYCLES(RSP_WAIT_CYCLES)
    ) u_adapter (
        .clk(clk), .rst_n(rst_n),
        .req_valid(req_valid), .req_ready(req_ready),
        .req_write(req_write), .req_mmio(1'b0),
        .req_access_ok(request_ok), .mmio_rdata(32'd0),
        .ram_rdata(ram_rdata), .rsp_valid(rsp_valid), .rsp_ready(rsp_ready),
        .rsp_rdata(adapter_rdata), .rsp_error(rsp_error)
    );
    // Do not expose the old RAM output on an invalid read response.
    assign rsp_rdata = rsp_error ? 32'd0 : adapter_rdata;
    // synthesis translate_off
    initial begin
        if (WORDS <= 0 || BASE_ADDR[1:0] != 0 ||
            ({32'd0, BASE_ADDR} + 64'd4 * WORDS) > 64'h100000000)
            $fatal(1, "soc_data_mem requires positive WORDS and a valid aligned address range");
    end
    // synthesis translate_on
endmodule
