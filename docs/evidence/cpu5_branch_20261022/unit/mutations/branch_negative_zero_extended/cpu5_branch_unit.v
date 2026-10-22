// RV32I control-flow decode and result calculation. An unsupported encoding
// has no control-flow side effects. The caller owns stalls and redirection.
module cpu5_branch_unit (
    input  wire [31:0] instr,
    input  wire [31:0] pc,
    input  wire [31:0] rs1_value,
    input  wire [31:0] rs2_value,
    output wire        supported,
    output wire        is_branch,
    output wire        is_jal,
    output wire        is_jalr,
    output wire        uses_rs1,
    output wire        uses_rs2,
    output wire        writes_rd,
    output wire [4:0]  rs1,
    output wire [4:0]  rs2,
    output wire [4:0]  rd,
    output wire [31:0] imm,
    output wire [31:0] target,
    output wire [31:0] actual_next_pc,
    output wire [31:0] link_value,
    output wire        taken,
    output wire        misaligned
);
    wire legal_branch_funct3 = (instr[14:12] == 3'b000) ||
                              (instr[14:12] == 3'b001) ||
                              (instr[14:12] == 3'b100) ||
                              (instr[14:12] == 3'b101) ||
                              (instr[14:12] == 3'b110) ||
                              (instr[14:12] == 3'b111);
    assign is_branch = (instr[6:0] == 7'b1100011) && legal_branch_funct3;
    assign is_jal = (instr[6:0] == 7'b1101111);
    assign is_jalr = (instr[6:0] == 7'b1100111) && (instr[14:12] == 3'b000);
    assign supported = is_branch || is_jal || is_jalr;
    assign uses_rs1 = is_branch || is_jalr;
    assign uses_rs2 = is_branch;
    // Raw source indices are harmless when the corresponding uses flag is 0.
    assign rs1 = instr[19:15];
    assign rs2 = instr[24:20];
    assign rd = (is_jal || is_jalr) ? instr[11:7] : 5'd0;
    assign writes_rd = (is_jal || is_jalr) && (rd != 5'd0);
    assign imm = is_branch ? {{19{1'b0}}, instr[31], instr[7],
                              instr[30:25], instr[11:8], 1'b0} :
                 is_jal ? {{11{instr[31]}}, instr[31], instr[19:12],
                           instr[20], instr[30:21], 1'b0} :
                 is_jalr ? {{20{instr[31]}}, instr[31:20]} : 32'd0;

    reg branch_condition;
    always @(*) begin
        branch_condition = 1'b0;
        case (instr[14:12])
            3'b000: branch_condition = (rs1_value == rs2_value);
            3'b001: branch_condition = (rs1_value != rs2_value);
            3'b100: branch_condition = ($signed(rs1_value) < $signed(rs2_value));
            3'b101: branch_condition = ($signed(rs1_value) >= $signed(rs2_value));
            3'b110: branch_condition = (rs1_value < rs2_value);
            3'b111: branch_condition = (rs1_value >= rs2_value);
            default: begin end
        endcase
    end
    assign link_value = pc + 32'd4;
    // IALIGN=32. JALR clears bit zero before the alignment check.
    assign target = is_jalr ? ((rs1_value + imm) & 32'hffff_fffe) :
                    (is_branch || is_jal) ? (pc + imm) : link_value;
    assign taken = is_jal || is_jalr || (is_branch && branch_condition);
    assign actual_next_pc = taken ? target : link_value;
    assign misaligned = taken && (target[1:0] != 2'b00);
endmodule
