module decoder (
    input  wire [31:0] instr,
    output wire [4:0]  rs1_addr,
    output wire [4:0]  rd_addr,
    output wire [31:0] imm_i,
    output wire        is_addi
);

    assign rs1_addr = instr[19:15];
    assign rd_addr  = instr[11:7];

    // Sign-extend the 12-bit I-type immediate to 32 bits.
    assign imm_i = {{20{instr[31]}}, instr[31:20]};

    // ADDI: opcode = 0010011, funct3 = 000.
    assign is_addi = (instr[6:0]   == 7'b0010011) &&
                     (instr[14:12] == 3'b000);

endmodule
