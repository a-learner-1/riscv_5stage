// Stage 3A-1 supports only the 21 RV32I integer ALU instructions.
// supported=0 also covers architecturally legal instructions whose execution
// has not been implemented in this independent CPU5 stage.
module cpu5_alu_decode (
    input  wire [31:0] instr,
    output reg         supported,
    output reg         uses_rs1,
    output reg         uses_rs2,
    output wire        writes_rd,
    output wire [4:0]  rs1,
    output wire [4:0]  rs2,
    output wire [4:0]  rd,
    output reg  [31:0] imm,
    output reg  [3:0]  alu_op,
    output reg         alu_a_pc,
    output reg         alu_a_zero,
    output reg         alu_b_imm
);
    localparam [3:0] ALU_ADD = 4'd0, ALU_SUB = 4'd1,
                     ALU_AND = 4'd2, ALU_OR = 4'd3,
                     ALU_XOR = 4'd4, ALU_SLL = 4'd5,
                     ALU_SRL = 4'd6, ALU_SRA = 4'd7,
                     ALU_SLT = 4'd8, ALU_SLTU = 4'd9;

    assign rs1 = instr[19:15];
    assign rs2 = instr[24:20];
    assign rd = instr[11:7];
    assign writes_rd = supported && (rd != 5'd0);

    always @(*) begin
        supported = 1'b0;
        uses_rs1 = 1'b0;
        uses_rs2 = 1'b0;
        imm = 32'd0;
        alu_op = ALU_ADD;
        alu_a_pc = 1'b0;
        alu_a_zero = 1'b0;
        alu_b_imm = 1'b0;
        case (instr[6:0])
            7'b0110011: begin
                // Match all funct7 bits: M and reserved encodings must not
                // alias ADD/SUB or the ordinary shifts.
                case ({instr[31:25], instr[14:12]})
                    10'b0000001_000: begin supported = 1'b1; alu_op = ALU_ADD;  end
                    10'b0000000_000: begin supported = 1'b1; alu_op = ALU_ADD;  end
                    10'b0100000_000: begin supported = 1'b1; alu_op = ALU_SUB;  end
                    10'b0000000_111: begin supported = 1'b1; alu_op = ALU_AND;  end
                    10'b0000000_110: begin supported = 1'b1; alu_op = ALU_OR;   end
                    10'b0000000_100: begin supported = 1'b1; alu_op = ALU_XOR;  end
                    10'b0000000_001: begin supported = 1'b1; alu_op = ALU_SLL;  end
                    10'b0000000_101: begin supported = 1'b1; alu_op = ALU_SRL;  end
                    10'b0100000_101: begin supported = 1'b1; alu_op = ALU_SRA;  end
                    10'b0000000_010: begin supported = 1'b1; alu_op = ALU_SLT;  end
                    10'b0000000_011: begin supported = 1'b1; alu_op = ALU_SLTU; end
                    default: begin end
                endcase
                uses_rs1 = supported;
                uses_rs2 = supported;
            end
            7'b0010011: begin
                case (instr[14:12])
                    3'b000: begin supported = 1'b1; alu_op = ALU_ADD;  end
                    3'b111: begin supported = 1'b1; alu_op = ALU_AND;  end
                    3'b110: begin supported = 1'b1; alu_op = ALU_OR;   end
                    3'b100: begin supported = 1'b1; alu_op = ALU_XOR;  end
                    3'b010: begin supported = 1'b1; alu_op = ALU_SLT;  end
                    3'b011: begin supported = 1'b1; alu_op = ALU_SLTU; end
                    3'b001: begin
                        if (instr[31:25] == 7'b0000000) begin
                            supported = 1'b1;
                            alu_op = ALU_SLL;
                        end
                    end
                    3'b101: begin
                        if (instr[31:25] == 7'b0000000) begin
                            supported = 1'b1;
                            alu_op = ALU_SRL;
                        end else if (instr[31:25] == 7'b0100000) begin
                            supported = 1'b1;
                            alu_op = ALU_SRA;
                        end
                    end
                    default: begin end
                endcase
                if (supported) begin
                    uses_rs1 = 1'b1;
                    alu_b_imm = 1'b1;
                    // The ALU consumes only imm[4:0] for shifts. Preserve
                    // the sign-extended encoded I-immediate for observation.
                    imm = {{20{instr[31]}}, instr[31:20]};
                end
            end
            7'b0110111: begin
                supported = 1'b1;
                imm = {instr[31:12], 12'd0};
                alu_a_zero = 1'b1;
                alu_b_imm = 1'b1;
            end
            7'b0010111: begin
                supported = 1'b1;
                imm = {instr[31:12], 12'd0};
                alu_a_pc = 1'b1;
                alu_b_imm = 1'b1;
            end
            default: begin end
        endcase
    end
endmodule
