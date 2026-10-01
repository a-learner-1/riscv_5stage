// Single-outstanding local data-bus endpoint. The RAM itself remains in
// cpu_top so its initialization and testbench hierarchy are unchanged.
// WAIT parameters insert extra clock edges before request acceptance and
// response consumption. Zero waits still complete on the edge AFTER accept.
module data_bus_adapter #(
    parameter integer REQ_WAIT_CYCLES = 0,
    parameter integer RSP_WAIT_CYCLES = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        req_valid,
    output wire        req_ready,
    input  wire        req_write,
    input  wire        req_mmio,
    input  wire        req_access_ok,
    input  wire [31:0] mmio_rdata,
    input  wire [31:0] ram_rdata,
    output wire        rsp_valid,
    input  wire        rsp_ready,
    output wire [31:0] rsp_rdata,
    output wire        rsp_error
);
    reg pending;
    reg write_q;
    reg mmio_q;
    reg access_ok_q;
    reg [31:0] mmio_rdata_q;
    integer req_wait_count;
    integer rsp_wait_count;

    assign req_ready = rst_n && !pending &&
                       (req_wait_count >= REQ_WAIT_CYCLES);
    assign rsp_valid = rst_n && pending &&
                       (rsp_wait_count >= RSP_WAIT_CYCLES);
    // A synchronous RAM updates its output at the acceptance edge and then
    // holds it. No next request can be accepted until this response is used.
    assign rsp_rdata = write_q ? 32'd0 :
                       mmio_q ? mmio_rdata_q : ram_rdata;
    assign rsp_error = !access_ok_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending <= 1'b0;
            write_q <= 1'b0;
            mmio_q <= 1'b0;
            access_ok_q <= 1'b1;
            mmio_rdata_q <= 32'd0;
            req_wait_count <= 0;
            rsp_wait_count <= 0;
        end else if (pending) begin
            req_wait_count <= 0;
            if (rsp_valid && rsp_ready) begin
                pending <= 1'b0;
                rsp_wait_count <= 0;
            end else if (rsp_wait_count < RSP_WAIT_CYCLES) begin
                rsp_wait_count <= rsp_wait_count + 1;
            end
        end else begin
            rsp_wait_count <= 0;
            if (req_valid && req_ready) begin
                pending <= 1'b1;
                write_q <= req_write;
                mmio_q <= req_mmio;
                access_ok_q <= req_access_ok;
                // Captured before RX FIFO pop or a GPIO/counter update.
                mmio_rdata_q <= mmio_rdata;
                req_wait_count <= 0;
            end else if (req_valid) begin
                if (req_wait_count < REQ_WAIT_CYCLES)
                    req_wait_count <= req_wait_count + 1;
            end else begin
                req_wait_count <= 0;
            end
        end
    end

    // synthesis translate_off
    initial begin
        if (REQ_WAIT_CYCLES < 0 || RSP_WAIT_CYCLES < 0)
            $fatal(1, "data_bus_adapter wait parameters must be nonnegative");
    end
    // synthesis translate_on
endmodule
