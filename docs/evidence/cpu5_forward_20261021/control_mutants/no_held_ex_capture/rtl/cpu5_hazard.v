// CPU5 source selection contract, not a complete pipeline controller.
// CHECK_EX_PRODUCER=1 is for ID branch/JALR resolution. EX values never
// feed ID combinationally: an EX match blocks even when EX reports ready.
module cpu5_hazard #(
    parameter CHECK_EX_PRODUCER = 0
) (
    input wire consumer_valid,
    input wire uses_rs1,
    input wire uses_rs2,
    input wire [4:0] rs1,
    input wire [4:0] rs2,
    input wire [31:0] rf_rs1_value,
    input wire [31:0] rf_rs2_value,
    input wire ex_valid,
    input wire ex_writes_rd,
    input wire [4:0] ex_rd,
    input wire ex_result_ready,
    input wire mem_valid,
    input wire mem_writes_rd,
    input wire [4:0] mem_rd,
    input wire mem_result_ready,
    input wire [31:0] mem_result_value,
    input wire wb_valid,
    input wire wb_writes_rd,
    input wire [4:0] wb_rd,
    input wire wb_result_ready,
    input wire [31:0] wb_result_value,
    output wire [31:0] rs1_value,
    output wire [31:0] rs2_value,
    output wire [2:0] fwd1,
    output wire [2:0] fwd2,
    output wire stall1,
    output wire stall2,
    output wire stall,
    output wire ex_block1,
    output wire ex_block2,
    output wire ex_block
);
    localparam [2:0] FWD_RF = 3'd0;
    localparam [2:0] FWD_ZERO = 3'd1;
    localparam [2:0] FWD_MEM = 3'd2;
    localparam [2:0] FWD_WB = 3'd3;
    localparam [2:0] FWD_BLOCK = 3'd4;

    // Bundle: {stall, blocked_by_EX, selection, value}. A blocked value is
    // deliberately zero; consumers must honor stall before using it.
    function [36:0] select_source;
        input consumer_is_valid;
        input use_source;
        input [4:0] source;
        input [31:0] rf_value;
        input ex_is_valid;
        input ex_does_write;
        input [4:0] ex_destination;
        input mem_is_valid;
        input mem_does_write;
        input [4:0] mem_destination;
        input mem_is_ready;
        input [31:0] mem_value;
        input wb_is_valid;
        input wb_does_write;
        input [4:0] wb_destination;
        input wb_is_ready;
        input [31:0] wb_value;
        begin
            select_source = {1'b0, 1'b0, FWD_RF, rf_value};
            if (consumer_is_valid && use_source) begin
                if (source == 5'd0)
                    select_source = {1'b0, 1'b0, FWD_ZERO, 32'd0};
                else if (CHECK_EX_PRODUCER && ex_is_valid && ex_does_write &&
                             ex_destination != 5'd0 && ex_destination == source)
                    select_source = {1'b1, 1'b1, FWD_BLOCK, 32'd0};
                else if (mem_is_valid && mem_does_write && mem_destination != 5'd0 &&
                             mem_destination == source) begin
                    if (mem_is_ready)
                        select_source = {1'b0, 1'b0, FWD_MEM, mem_value};
                    else
                        select_source = {1'b1, 1'b0, FWD_BLOCK, 32'd0};
                end else if (wb_is_valid && wb_does_write && wb_destination != 5'd0 &&
                             wb_destination == source) begin
                    if (wb_is_ready)
                        select_source = {1'b0, 1'b0, FWD_WB, wb_value};
                    else
                        select_source = {1'b1, 1'b0, FWD_BLOCK, 32'd0};
                end
            end
        end
    endfunction

    assign {stall1, ex_block1, fwd1, rs1_value} =
        select_source(consumer_valid, uses_rs1, rs1, rf_rs1_value,
                      ex_valid, ex_writes_rd, ex_rd,
                      mem_valid, mem_writes_rd, mem_rd, mem_result_ready, mem_result_value,
                      wb_valid, wb_writes_rd, wb_rd, wb_result_ready, wb_result_value);
    assign {stall2, ex_block2, fwd2, rs2_value} =
        select_source(consumer_valid, uses_rs2, rs2, rf_rs2_value,
                      ex_valid, ex_writes_rd, ex_rd,
                      mem_valid, mem_writes_rd, mem_rd, mem_result_ready, mem_result_value,
                      wb_valid, wb_writes_rd, wb_rd, wb_result_ready, wb_result_value);
    assign stall = stall1 || stall2;
    assign ex_block = ex_block1 || ex_block2;

    // ex_result_ready is an interface fact for diagnostics. It never bypasses
    // the deliberate absence of an EX-to-ID data path.
endmodule
