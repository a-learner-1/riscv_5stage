`timescale 1ns/1ps
module cpu5_alu_decode_tb;
    reg [31:0] instr;
    wire supported, uses_rs1, uses_rs2, writes_rd;
    wire [4:0] rs1, rs2, rd;
    wire [31:0] imm;
    wire [3:0] alu_op;
    wire alu_a_pc, alu_a_zero, alu_b_imm;
    reg test_pass = 1'b0;
    integer cases = 0, legal_cases = 0, unsupported_cases = 0;
    integer upper, fn, shamt, value, k, j, opcode, destination;
    integer key, found, signed_value;
    integer r_keys [0:9];
    integer r_ops [0:9];
    integer i_funct3 [0:5];
    integer i_ops [0:5];
    reg [19:0] u_values [0:5];
    reg [31:0] semantic_instr [0:20];
    reg [31:0] semantic_expected [0:20];
    wire [31:0] semantic_a = alu_a_pc ? 32'h12345678 :
                                alu_a_zero ? 32'd0 : 32'h80000001;
    wire [31:0] semantic_b = alu_b_imm ? imm : 32'd1;
    wire [31:0] semantic_result;

    cpu5_alu_decode dut (
        .instr(instr), .supported(supported), .uses_rs1(uses_rs1),
        .uses_rs2(uses_rs2), .writes_rd(writes_rd), .rs1(rs1),
        .rs2(rs2), .rd(rd), .imm(imm), .alu_op(alu_op),
        .alu_a_pc(alu_a_pc), .alu_a_zero(alu_a_zero), .alu_b_imm(alu_b_imm)
    );
    // Integration checks reuse the unchanged legacy ALU; no new datapath ALU.
    alu operation (.a(semantic_a), .b(semantic_b), .alu_op(alu_op),
                   .result(semantic_result));

    function [31:0] r_encoding;
        input integer encoding_key, dest, source1, source2;
        begin
            r_encoding = ((encoding_key / 8) << 25) | (source2 << 20) |
                         (source1 << 15) | ((encoding_key % 8) << 12) |
                         (dest << 7) | 32'h33;
        end
    endfunction
    function [31:0] i_encoding;
        input integer immediate12, funct3, dest, source1;
        begin
            i_encoding = (immediate12 << 20) | (source1 << 15) |
                         (funct3 << 12) | (dest << 7) | 32'h13;
        end
    endfunction

    task check;
        input [31:0] encoding;
        input expected_supported, expected_rs1, expected_rs2;
        input [31:0] expected_imm;
        input [3:0] expected_op;
        input expected_pc, expected_zero, expected_b_imm;
        begin
            instr = encoding;
            #1;
            cases = cases + 1;
            if (expected_supported) legal_cases = legal_cases + 1;
            else unsupported_cases = unsupported_cases + 1;
            if ({supported, uses_rs1, uses_rs2, writes_rd, imm, alu_op,
                 alu_a_pc, alu_a_zero, alu_b_imm} !==
                {expected_supported, expected_rs1, expected_rs2,
                 (expected_supported && encoding[11:7] != 0), expected_imm,
                 expected_op, expected_pc, expected_zero, expected_b_imm}) begin
                $display("DECODE FAIL case=%0d instr=%08h supported=%b uses=%b%b writes=%b imm=%08h op=%d operands=%b%b%b",
                    cases, encoding, supported, uses_rs1, uses_rs2, writes_rd,
                    imm, alu_op, alu_a_pc, alu_a_zero, alu_b_imm);
                $display("expected supported=%b uses=%b%b imm=%08h op=%d operands=%b%b%b",
                    expected_supported, expected_rs1, expected_rs2, expected_imm,
                    expected_op, expected_pc, expected_zero, expected_b_imm);
                $fatal(1, "decode controls differ");
            end
            if (rs1 !== encoding[19:15] || rs2 !== encoding[24:20] ||
                rd !== encoding[11:7]) $fatal(1, "raw register indices changed");
        end
    endtask

    initial begin
        // ISA encoding truth set, independent of the decoder's branch order.
        // key = funct7 * 8 + funct3; every other R key must be unsupported.
        r_keys[0]=0;   r_ops[0]=0; // ADD
        r_keys[1]=256; r_ops[1]=1; // SUB
        r_keys[2]=7;   r_ops[2]=2; // AND
        r_keys[3]=6;   r_ops[3]=3; // OR
        r_keys[4]=4;   r_ops[4]=4; // XOR
        r_keys[5]=1;   r_ops[5]=5; // SLL
        r_keys[6]=5;   r_ops[6]=6; // SRL
        r_keys[7]=261; r_ops[7]=7; // SRA
        r_keys[8]=2;   r_ops[8]=8; // SLT
        r_keys[9]=3;   r_ops[9]=9; // SLTU
        for (key=0; key<1024; key=key+1) begin
            found = -1;
            for (j=0; j<10; j=j+1)
                if (key==r_keys[j]) found=j;
            if (found>=0)
                check(r_encoding(key, 13, 17, 29), 1, 1, 1,
                      0, r_ops[found], 0, 0, 0);
            else check(r_encoding(key, 13, 17, 29), 0, 0, 0,
                       0, 0, 0, 0, 0);
        end
        // All destinations, including x0; independently varied source fields.
        for (k=0; k<10; k=k+1)
            for (destination=0; destination<32; destination=destination+1)
                check(r_encoding(r_keys[k], destination, destination,
                                 31-destination), 1, 1, 1,
                      0, r_ops[k], 0, 0, 0);

        // Non-shift I encodings accept every 12-bit immediate, even values
        // which would be an invalid funct7 on an R or shift instruction.
        i_funct3[0]=0; i_ops[0]=0; // ADDI
        i_funct3[1]=7; i_ops[1]=2; // ANDI
        i_funct3[2]=6; i_ops[2]=3; // ORI
        i_funct3[3]=4; i_ops[3]=4; // XORI
        i_funct3[4]=2; i_ops[4]=8; // SLTI
        i_funct3[5]=3; i_ops[5]=9; // SLTIU
        for (k=0; k<6; k=k+1)
            for (value=0; value<4096; value=value+1) begin
                signed_value = value < 2048 ? value : value-4096;
                check(i_encoding(value, i_funct3[k], value%32,
                                 (value/32)%32), 1, 1, 0,
                      signed_value, i_ops[k], 0, 0, 1);
            end

        // Entire shift-immediate upper encoding space, all shamt values.
        for (upper=0; upper<128; upper=upper+1)
            for (shamt=0; shamt<32; shamt=shamt+1) begin
                value=upper*32+shamt;
                if (upper==0)
                    check(i_encoding(value, 1, shamt, 31-shamt),
                          1, 1, 0, shamt, 5, 0, 0, 1);
                else check(i_encoding(value, 1, shamt, 31-shamt),
                           0, 0, 0, 0, 0, 0, 0, 0);
                if (upper==0)
                    check(i_encoding(value, 5, shamt, 31-shamt),
                          1, 1, 0, shamt, 6, 0, 0, 1);
                else if (upper==32)
                    check(i_encoding(value, 5, shamt, 31-shamt),
                          1, 1, 0, 1024+shamt, 7, 0, 0, 1);
                else check(i_encoding(value, 5, shamt, 31-shamt),
                           0, 0, 0, 0, 0, 0, 0, 0);
            end

        // U-immediate zeros, ones, sign extremes and mixed patterns.
        u_values[0]=20'h00000; u_values[1]=20'hfffff;
        u_values[2]=20'h80000; u_values[3]=20'h7ffff;
        u_values[4]=20'h12345; u_values[5]=20'ha5a5a;
        for (k=0; k<6; k=k+1)
            for (destination=0; destination<32; destination=destination+1) begin
                check((u_values[k]*4096) | (destination*128) | 32'h37,
                      1, 0, 0, u_values[k]*4096, 0, 0, 1, 1);
                check((u_values[k]*4096) | (destination*128) | 32'h17,
                      1, 0, 0, u_values[k]*4096, 0, 1, 0, 1);
            end
        // Every other 7-bit opcode with sparse, sign and dense field patterns.
        // Includes loads/stores/branches/JAL/JALR/CSR/FENCE and non-32-bit words.
        for (opcode=0; opcode<128; opcode=opcode+1)
            if (opcode!=7'h33 && opcode!=7'h13 &&
                opcode!=7'h37 && opcode!=7'h17) begin
                check(opcode, 0, 0, 0, 0, 0, 0, 0, 0);
                check(32'h800a5a80 | opcode, 0, 0, 0, 0, 0, 0, 0, 0);
                check(32'hffffff80 | opcode, 0, 0, 0, 0, 0, 0, 0, 0);
            end

        // 21 hand-calculated integration results for a=0x80000001, b=1,
        // PC=0x12345678. Operand mux controls are tested as part of execution.
        for (k=0; k<10; k=k+1)
            semantic_instr[k]=r_encoding(r_keys[k], 9, 4, 5);
        semantic_expected[0]=32'h80000002;
        semantic_expected[1]=32'h80000000;
        semantic_expected[2]=32'h00000001;
        semantic_expected[3]=32'h80000001;
        semantic_expected[4]=32'h80000000;
        semantic_expected[5]=32'h00000002;
        semantic_expected[6]=32'h40000000;
        semantic_expected[7]=32'hc0000000;
        semantic_expected[8]=32'h00000001;
        semantic_expected[9]=32'h00000000;
        for (k=0; k<6; k=k+1)
            semantic_instr[10+k]=i_encoding(4095, i_funct3[k], 9, 4);
        semantic_expected[10]=32'h80000000; // ADDI -1
        semantic_expected[11]=32'h80000001; // ANDI -1
        semantic_expected[12]=32'hffffffff; // ORI -1
        semantic_expected[13]=32'h7ffffffe; // XORI -1
        semantic_expected[14]=32'h00000001; // SLTI -1
        semantic_expected[15]=32'h00000001; // SLTIU -1
        semantic_instr[16]=i_encoding(31, 1, 9, 4);
        semantic_expected[16]=32'h80000000; // SLLI 31
        semantic_instr[17]=i_encoding(31, 5, 9, 4);
        semantic_expected[17]=32'h00000001; // SRLI 31
        semantic_instr[18]=i_encoding(1055, 5, 9, 4);
        semantic_expected[18]=32'hffffffff; // SRAI 31
        semantic_instr[19]=32'habcd04b7; // LUI x9,0xabcd0
        semantic_expected[19]=32'habcd0000;
        semantic_instr[20]=32'habcd0497; // AUIPC x9,0xabcd0
        semantic_expected[20]=32'hbe015678;
        for (k=0; k<21; k=k+1) begin
            instr=semantic_instr[k]; #1;
            if (supported !== 1'b1 || semantic_result !== semantic_expected[k])
                $fatal(1, "ALU integration k=%0d instr=%08h result=%08h expected=%08h",
                       k, instr, semantic_result, semantic_expected[k]);
        end
        $display("CPU5_ALU_DECODE PASS controls=%0d supported=%0d unsupported=%0d semantic=21",
                 cases, legal_cases, unsupported_cases);
        test_pass=1'b1;
        $stop;
    end
    initial begin
        #100000;
        $fatal(1, "decode test timeout");
    end
endmodule
