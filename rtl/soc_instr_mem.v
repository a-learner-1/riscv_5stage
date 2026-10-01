// CPU-external instruction ROM, physically implemented inside the FPGA.
// Requests use byte addresses; one accepted request is outstanding.
module soc_instr_mem #(
    parameter integer WORDS = 8192,
    parameter INIT_FILE = "programs/c_demo.hex",
    parameter integer REQ_WAIT_CYCLES = 0,
    parameter integer RSP_WAIT_CYCLES = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        req_valid,
    output wire        req_ready,
    input  wire [31:0] req_addr,
    output wire        rsp_valid,
    input  wire        rsp_ready,
    output wire [31:0] rsp_rdata,
    output wire        rsp_error
);
    wire req_fire = req_valid && req_ready;
    wire request_ok = (req_addr[1:0] == 2'b00) &&
                      (req_addr[31:2] < WORDS);
    wire [31:0] instr_data;
    wire unused_access_ok;
    wire [31:0] adapter_rdata;

    instr_mem #(.WORDS(WORDS), .INIT_FILE(INIT_FILE)) u_instr_mem (
        .clk(clk), .en(req_fire && rst_n), .addr(req_addr),
        .instr(instr_data), .access_ok(unused_access_ok)
    );
    instr_bus_adapter #(
        .REQ_WAIT_CYCLES(REQ_WAIT_CYCLES), .RSP_WAIT_CYCLES(RSP_WAIT_CYCLES)
    ) u_adapter (
        .clk(clk), .rst_n(rst_n),
        .req_valid(req_valid), .req_ready(req_ready),
        .req_access_ok(request_ok), .instr_data(instr_data),
        .rsp_valid(rsp_valid), .rsp_ready(rsp_ready),
        .rsp_rdata(adapter_rdata), .rsp_error(rsp_error)
    );
    assign rsp_rdata = rsp_error ? 32'd0 : adapter_rdata;
    // synthesis translate_off
    initial begin
        if (WORDS <= 0)
            $fatal(1, "soc_instr_mem WORDS must be positive");
    end
    // synthesis translate_on
endmodule
