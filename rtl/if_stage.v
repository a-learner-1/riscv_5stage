module if_stage (
    input  wire        clk,
    input  wire        rst_n,

    output reg  [31:0] pc_f,
    output reg  [31:0] pc_x,
    output reg  [31:0] instr_x,
    output reg         valid_x
);

    reg [31:0] instr_f;

    // Instruction ROM.
    always @(*) begin
        case (pc_f)
            32'd0:
                instr_f = 32'h00500093; // addi x1, x0, 5

            32'd4:
                instr_f = 32'h00308113; // addi x2, x1, 3

            32'd8:
                instr_f = 32'h002081b3; // add x3, x1, x2

            32'd12:
                instr_f = 32'h00318233; // add x4, x3, x3

            32'd16:
                instr_f = 32'h403202b3; // sub x5, x4, x3

            32'd20:
                instr_f = 32'h40508333; // sub x6, x1, x5

            32'd24:
                instr_f = 32'h004373b3; // and x7, x6, x4

            32'd28:
                instr_f = 32'h0070e433; // or x8, x1, x7

            32'd32:
                instr_f = 32'h007444b3; // xor x9, x8, x7

            default:
                instr_f = 32'h00000013; // addi x0, x0, 0: NOP
        endcase
    end

    // PC and IF/EX pipeline registers.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_f    <= 32'd0;
            pc_x    <= 32'd0;
            instr_x <= 32'h00000013;
            valid_x <= 1'b0;
        end else begin
            pc_x    <= pc_f;
            instr_x <= instr_f;
            valid_x <= 1'b1;
            pc_f    <= pc_f + 32'd4;
        end
    end

endmodule
