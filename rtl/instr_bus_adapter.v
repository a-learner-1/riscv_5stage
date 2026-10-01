// Adapt the synchronous internal instruction RAM to ready/valid.
// Zero extra waits preserve one accepted fetch per clock. Responses cannot
// be consumed on their request edge and remain valid under backpressure.
module instr_bus_adapter #(
    parameter integer REQ_WAIT_CYCLES = 0,
    parameter integer RSP_WAIT_CYCLES = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        req_valid,
    output wire        req_ready,
    input  wire        req_access_ok,
    input  wire [31:0] instr_data,
    output wire        rsp_valid,
    input  wire        rsp_ready,
    output wire [31:0] rsp_rdata,
    output wire        rsp_error
);
    reg pending;
    reg error_q;
    integer req_wait_count;
    integer rsp_wait_count;
    wire req_fire = req_valid && req_ready;
    wire rsp_fire = rsp_valid && rsp_ready;
    wire space = !pending || rsp_fire;
    assign req_ready = rst_n && space && (req_wait_count >= REQ_WAIT_CYCLES);
    assign rsp_valid = rst_n && pending && (rsp_wait_count == 0);
    // The RAM only updates at request acceptance, keeping the previous
    // response stable until its consume edge even with consecutive fetches.
    assign rsp_rdata = instr_data;
    assign rsp_error = error_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending <= 1'b0;
            error_q <= 1'b0;
            req_wait_count <= 0;
            rsp_wait_count <= 0;
        end else begin
            if (!req_valid || !space || req_fire)
                req_wait_count <= 0;
            else if (req_wait_count < REQ_WAIT_CYCLES)
                req_wait_count <= req_wait_count + 1;
            if (pending && rsp_wait_count > 0)
                rsp_wait_count <= rsp_wait_count - 1;
            if (rsp_fire)
                pending <= 1'b0;
            if (req_fire) begin
                pending <= 1'b1;
                error_q <= !req_access_ok;
                rsp_wait_count <= RSP_WAIT_CYCLES;
            end
        end
    end
    // synthesis translate_off
    initial begin
        if (REQ_WAIT_CYCLES < 0 || RSP_WAIT_CYCLES < 0)
            $fatal(1, "Instruction wait parameters must be nonnegative");
    end
    // synthesis translate_on
endmodule
