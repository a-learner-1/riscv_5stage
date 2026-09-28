module if_stage #(
    parameter PROGRAM_FILE = "programs/rv32i_regression.hex",
    parameter integer IMEM_WORDS = 1024
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        redirect_x,
    input  wire [31:0] redirect_pc_x,

    output reg  [31:0] pc_f,
    output reg  [31:0] pc_x,
    output reg  [31:0] instr_x,
    output reg         valid_x
);
    wire [31:0] instr_f;
    wire fetch_ok_f;

    instr_mem #(
        .WORDS(IMEM_WORDS),
        .INIT_FILE(PROGRAM_FILE)
    ) u_instr_mem (
        .addr(pc_f),
        .instr(instr_f),
        .access_ok(fetch_ok_f)
    );

    // The current teaching core has no instruction-access exception handler.
    // Invalid fetches become invalid pipeline entries instead of aliasing ROM.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_f    <= 32'd0;
            pc_x    <= 32'd0;
            instr_x <= 32'h00000013;
            valid_x <= 1'b0;
        end else if (redirect_x) begin
            pc_x    <= pc_f;
            instr_x <= 32'h00000013;
            valid_x <= 1'b0;
            pc_f    <= redirect_pc_x;
        end else begin
            pc_x    <= pc_f;
            instr_x <= instr_f;
            valid_x <= fetch_ok_f;
            pc_f    <= pc_f + 32'd4;
        end
    end
endmodule
