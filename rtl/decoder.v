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
    output wire        is_xor
);

    // Extract register address fields.
    assign rs1_addr = instr[19:15];
    assign rs2_addr = instr[24:20];
    assign rd_addr  = instr[11:7];

    // Sign-extend the 12-bit I-type immediate.
    assign imm_i = {{20{instr[31]}}, instr[31:20]};

    // ADDI
    assign is_addi = (instr[6:0]   == 7'b0010011) &&
                     (instr[14:12] == 3'b000);

    // ADD
    assign is_add = (instr[6:0]   == 7'b0110011) &&
                    (instr[14:12] == 3'b000) &&
                    (instr[31:25] == 7'b0000000);

    // SUB
    assign is_sub = (instr[6:0]   == 7'b0110011) &&
                    (instr[14:12] == 3'b000) &&
                    (instr[31:25] == 7'b0100000);

    // AND
    assign is_and = (instr[6:0]   == 7'b0110011) &&
                    (instr[14:12] == 3'b111) &&
                    (instr[31:25] == 7'b0000000);

    // OR
    assign is_or = (instr[6:0]   == 7'b0110011) &&
                   (instr[14:12] == 3'b110) &&
                   (instr[31:25] == 7'b0000000);

    // XOR
    assign is_xor = (instr[6:0]   == 7'b0110011) &&
                    (instr[14:12] == 3'b100) &&
                    (instr[31:25] == 7'b0000000);

endmodule
