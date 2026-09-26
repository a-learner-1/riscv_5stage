module decoder (
    input  wire [31:0] instr,

    output wire [4:0]  rs1_addr,
    output wire [4:0]  rs2_addr,
    output wire [4:0]  rd_addr,
    output wire [31:0] imm_i,

    output wire        is_addi,
    output wire        is_add,
    output wire        is_sub,
    output wire        is_and,
    output wire        is_or,
    output wire        is_xor,

    output wire        is_andi,
    output wire        is_ori,
    output wire        is_xori
);

    wire [6:0] opcode;
    wire [2:0] funct3;
    wire [6:0] funct7;

    assign opcode = instr[6:0];
    assign funct3 = instr[14:12];
    assign funct7 = instr[31:25];

    // Extract register address fields.
    assign rs1_addr = instr[19:15];
    assign rs2_addr = instr[24:20];
    assign rd_addr  = instr[11:7];

    // Sign-extend the 12-bit I-type immediate to 32 bits.
    assign imm_i = {{20{instr[31]}}, instr[31:20]};

    // I-type arithmetic and logic instructions.
    // instr[31:20] is an immediate, so do not check funct7 here.
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

endmodule
