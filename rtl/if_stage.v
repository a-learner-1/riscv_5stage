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

            32'd36:
                instr_f = 32'h0094f513; // andi x10, x9, 9
            32'd40:
                instr_f = 32'h00a56593; // ori x11, x10, 10
            32'd44:
                instr_f = 32'h00b5c613; // xori x12, x11, 11
            32'd48:
                instr_f = 32'hfff64693; // xori x13, x12, -1
            32'd52:
                instr_f = 32'h8006f713; // andi x14, x13, -2048
            32'd56:
                instr_f = 32'hfff76793; // ori x15, x14, -1

            32'd60: instr_f = 32'h00a79833; // sll x16, x15, x10
            32'd64: instr_f = 32'h00a858b3; // srl x17, x16, x10
            32'd68: instr_f = 32'h40a85933; // sra x18, x16, x10
            32'd72: instr_f = 32'h02100993; // addi x19, x0, 33
            32'd76: instr_f = 32'h41335a33; // sra x20, x6, x19
            32'd80: instr_f = 32'h01351ab3; // sll x21, x10, x19
            32'd84: instr_f = 32'h00aadb33; // srl x22, x21, x10
            32'd88: instr_f = 32'h016b1bb3; // sll x23, x22, x22
            32'd92: instr_f = 32'h02000c13; // addi x24, x0, 32
            32'd96: instr_f = 32'h01885cb3; // srl x25, x16, x24

            default:
                instr_f = 32'h00000013; // NOP
        endcase
    end

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

