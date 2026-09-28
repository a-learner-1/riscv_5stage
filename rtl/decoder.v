module decoder (
    input  wire [31:0] instr,

    output wire [4:0]  rs1_addr,
    output wire [4:0]  rs2_addr,
    output wire [4:0]  rd_addr,
    output wire [31:0] imm_i,
    output wire [31:0] imm_u,
    output wire [31:0] imm_b,
    output wire [31:0] imm_j,

    output wire        is_addi,
    output wire        is_add,
    output wire        is_sub,
    output wire        is_and,
    output wire        is_or,
    output wire        is_xor,

    output wire        is_andi,
    output wire        is_ori,
    output wire        is_xori,

    output wire        is_sll,
    output wire        is_srl,
    output wire        is_sra,
    output wire        is_slli,
    output wire        is_srli,
    output wire        is_srai,
    output wire        is_slt,
    output wire        is_sltu,
    output wire        is_slti,
    output wire        is_sltiu,
    output wire        is_lui,
    output wire        is_auipc,
    output wire        is_beq,
    output wire        is_bne,
    output wire        is_blt,
    output wire        is_bge,
    output wire        is_bltu,
    output wire        is_bgeu,
    output wire        is_jal,
    output wire        is_jalr,
    output wire        is_lw,
    output wire        is_sw,
    output wire [31:0] imm_s
);

    wire [6:0] opcode;
    wire [2:0] funct3;
    wire [6:0] funct7;

    assign opcode = instr[6:0];
    assign funct3 = instr[14:12];
    assign funct7 = instr[31:25];

    assign rs1_addr = instr[19:15];
    assign rs2_addr = instr[24:20];
    assign rd_addr  = instr[11:7];

    // Sign-extend the 12-bit I-type immediate.
    assign imm_i = {{20{instr[31]}}, instr[31:20]};
    assign imm_u = {instr[31:12], 12'b0};
    // B immediate: imm[12|10:5|4:1|11|0]. Bit 0 is always zero.
    assign imm_b = {{19{instr[31]}}, instr[31], instr[7],
                    instr[30:25], instr[11:8], 1'b0};
    // J immediate: imm[20|10:1|11|19:12|0], sign extended.
    assign imm_j = {{11{instr[31]}}, instr[31], instr[19:12],
                    instr[20], instr[30:21], 1'b0};

    // I-type arithmetic and logic instructions.
    assign is_addi =
        (opcode == 7'b0010011) &&
        (funct3 == 3'b000);

    assign is_andi =
        (opcode == 7'b0010011) &&
        (funct3 == 3'b111);

    assign is_ori =
        (opcode == 7'b0010011) &&
        (funct3 == 3'b110);

    assign is_xori =
        (opcode == 7'b0010011) &&
        (funct3 == 3'b100);

    // R-type arithmetic and logic instructions.
    assign is_add =
        (opcode == 7'b0110011) &&
        (funct3 == 3'b000) &&
        (funct7 == 7'b0000000);

    assign is_sub =
        (opcode == 7'b0110011) &&
        (funct3 == 3'b000) &&
        (funct7 == 7'b0100000);

    assign is_and =
        (opcode == 7'b0110011) &&
        (funct3 == 3'b111) &&
        (funct7 == 7'b0000000);

    assign is_or =
        (opcode == 7'b0110011) &&
        (funct3 == 3'b110) &&
        (funct7 == 7'b0000000);

    assign is_xor =
        (opcode == 7'b0110011) &&
        (funct3 == 3'b100) &&
        (funct7 == 7'b0000000);

    // Register shift instructions.
    assign is_sll =
        (opcode == 7'b0110011) &&
        (funct3 == 3'b001) &&
        (funct7 == 7'b0000000);

    assign is_srl =
        (opcode == 7'b0110011) &&
        (funct3 == 3'b101) &&
        (funct7 == 7'b0000000);

    assign is_sra =
        (opcode == 7'b0110011) &&
        (funct3 == 3'b101) &&
        (funct7 == 7'b0100000);

// RV32 shift immediates have a 5-bit shamt in instr[24:20].
    // Check all seven upper bits; RV64 shamt[5] is not legal here.
    assign is_slli = (opcode == 7'b0010011) &&
                     (funct3 == 3'b001) && (funct7 == 7'b0000000);
    assign is_srli = (opcode == 7'b0010011) &&
                     (funct3 == 3'b101) && (funct7 == 7'b0000000);
    assign is_srai = (opcode == 7'b0010011) &&
                     (funct3 == 3'b101) && (funct7 == 7'b0100000);
    // SLTIU still sign-extends the 12-bit immediate; only comparison is unsigned.
    assign is_slti  = (opcode == 7'b0010011) && (funct3 == 3'b010);
    assign is_sltiu = (opcode == 7'b0010011) && (funct3 == 3'b011);
    assign is_slt   = (opcode == 7'b0110011) && (funct3 == 3'b010) &&
                      (funct7 == 7'b0000000);
    assign is_sltu  = (opcode == 7'b0110011) && (funct3 == 3'b011) &&
                      (funct7 == 7'b0000000);
    assign is_lui   = (opcode == 7'b0110111);
    assign is_auipc = (opcode == 7'b0010111);
    assign is_beq   = (opcode == 7'b1100011) && (funct3 == 3'b000);
    assign is_bne   = (opcode == 7'b1100011) && (funct3 == 3'b001);
    assign is_blt   = (opcode == 7'b1100011) && (funct3 == 3'b100);
    assign is_bge   = (opcode == 7'b1100011) && (funct3 == 3'b101);
    assign is_bltu  = (opcode == 7'b1100011) && (funct3 == 3'b110);
    assign is_bgeu  = (opcode == 7'b1100011) && (funct3 == 3'b111);
    assign is_jal   = (opcode == 7'b1101111);
    assign is_jalr  = (opcode == 7'b1100111) && (funct3 == 3'b000);
    assign imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    assign is_lw = (opcode == 7'b0000011) && (funct3 == 3'b010);
    assign is_sw = (opcode == 7'b0100011) && (funct3 == 3'b010);
endmodule
