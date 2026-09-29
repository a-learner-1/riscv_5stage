module if_stage #(
    parameter PROGRAM_FILE = "programs/rv32i_regression.hex",
    parameter integer IMEM_WORDS = 1024
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        redirect_x,
    input  wire [31:0] redirect_pc_x,
    input  wire        stall_x,

    output reg  [31:0] pc_f,
    output reg  [31:0] pc_x,
    output reg  [31:0] instr_x,
    output reg         valid_x
);
    wire [31:0] instr_f;
    wire fetch_ok_f;
    wire [31:0] fetch_addr_f;
    wire imem_en_f;

    // Metadata belonging to the response currently held by instr_mem.
    reg [31:0] fetch_pc_q;
    reg        fetch_pending_q;

    // A redirect request is issued immediately at the branch/jump edge.
    // During a data-memory stall the current instruction response is held.
    assign fetch_addr_f = redirect_x ? redirect_pc_x : pc_f;
    assign imem_en_f = rst_n && !stall_x;

    instr_mem #(
        .WORDS(IMEM_WORDS),
        .INIT_FILE(PROGRAM_FILE)
    ) u_instr_mem (
        .clk(clk),
        .en(imem_en_f),
        .addr(fetch_addr_f),
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
            fetch_pc_q <= 32'd0;
            fetch_pending_q <= 1'b0;
        end else if (redirect_x) begin
            // Discard the sequential response and start a target fetch.
            pc_x    <= fetch_pc_q;
            instr_x <= 32'h00000013;
            valid_x <= 1'b0;
            fetch_pc_q <= redirect_pc_x;
            fetch_pending_q <= 1'b1;
            pc_f    <= redirect_pc_x + 32'd4;
        end else if (stall_x) begin
            pc_f    <= pc_f;
            pc_x    <= pc_x;
            instr_x <= instr_x;
            valid_x <= valid_x;
            fetch_pc_q <= fetch_pc_q;
            fetch_pending_q <= fetch_pending_q;
        end else begin
            // Consume the response from the previous request while issuing
            // the next sequential request to the synchronous instruction RAM.
            pc_x    <= fetch_pc_q;
            instr_x <= instr_f;
            valid_x <= fetch_pending_q && fetch_ok_f;
            fetch_pc_q <= pc_f;
            fetch_pending_q <= 1'b1;
            pc_f    <= pc_f + 32'd4;
        end
    end
endmodule


