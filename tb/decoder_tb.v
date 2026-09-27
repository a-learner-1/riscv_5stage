`timescale 1ns/1ps

module decoder_tb;

    // Flag order:
    // ADDI ADD SUB AND OR XOR ANDI ORI XORI SLL SRL SRA SLLI SRLI SRAI
    localparam [14:0] DEC_NONE = 15'b000000000000000;
    localparam [14:0] DEC_ADDI = 15'b100000000000000;
    localparam [14:0] DEC_ADD  = 15'b010000000000000;
    localparam [14:0] DEC_SUB  = 15'b001000000000000;
    localparam [14:0] DEC_AND  = 15'b000100000000000;
    localparam [14:0] DEC_OR   = 15'b000010000000000;
    localparam [14:0] DEC_XOR  = 15'b000001000000000;
    localparam [14:0] DEC_ANDI = 15'b000000100000000;
    localparam [14:0] DEC_ORI  = 15'b000000010000000;
    localparam [14:0] DEC_XORI = 15'b000000001000000;
    localparam [14:0] DEC_SLL  = 15'b000000000100000;
    localparam [14:0] DEC_SRL  = 15'b000000000010000;
    localparam [14:0] DEC_SRA  = 15'b000000000001000;

    localparam [14:0] DEC_SLLI = 15'b000000000000100;
    localparam [14:0] DEC_SRLI = 15'b000000000000010;
    localparam [14:0] DEC_SRAI = 15'b000000000000001;
    integer sh, upper;
    reg [31:0] instr;

    wire [4:0]  rs1_addr;
    wire [4:0]  rs2_addr;
    wire [4:0]  rd_addr;
    wire [31:0] imm_i;

    wire is_addi;
    wire is_add;
    wire is_sub;
    wire is_and;
    wire is_or;
    wire is_xor;
    wire is_andi;
    wire is_ori;
    wire is_xori;
    wire is_sll;
    wire is_srl;
    wire is_sra;
    wire is_slli, is_srli, is_srai;

    wire [14:0] decode_flags;

    integer test_count;

    decoder dut (
        .instr    (instr),
        .rs1_addr (rs1_addr),
        .rs2_addr (rs2_addr),
        .rd_addr  (rd_addr),
        .imm_i    (imm_i),

        .is_addi  (is_addi),
        .is_add   (is_add),
        .is_sub   (is_sub),
        .is_and   (is_and),
        .is_or    (is_or),
        .is_xor   (is_xor),

        .is_andi  (is_andi),
        .is_ori   (is_ori),
        .is_xori  (is_xori),

        .is_sll   (is_sll),
        .is_srl   (is_srl),
        .is_sra   (is_sra),
        .is_slli  (is_slli),
        .is_srli  (is_srli),
        .is_srai  (is_srai)
    );

    assign decode_flags = {
        is_addi,
        is_add,
        is_sub,
        is_and,
        is_or,
        is_xor,
        is_andi,
        is_ori,
        is_xori,
        is_sll,
        is_srl,
        is_sra, is_slli, is_srli, is_srai
    };

    task check_decode;
        input [31:0] test_instr;
        input [4:0]  expected_rs1;
        input [4:0]  expected_rs2;
        input [4:0]  expected_rd;
        input [31:0] expected_imm;
        input [14:0] expected_flags;
        begin
            instr = test_instr;
            #1;

            if (rs1_addr !== expected_rs1 ||
                rs2_addr !== expected_rs2 ||
                rd_addr !== expected_rd ||
                decode_flags !== expected_flags) begin

                $display("FAIL: case=%0d instr=%h",
                         test_count + 1, instr);

                $display("actual: rs1=%0d rs2=%0d rd=%0d flags=%b",
                         rs1_addr, rs2_addr, rd_addr, decode_flags);

                $display("expected: rs1=%0d rs2=%0d rd=%0d flags=%b",
                         expected_rs1,
                         expected_rs2,
                         expected_rd,
                         expected_flags);

                $fatal(1, "Decoder field or flag mismatch");
            end

            // Only these supported instructions consume imm_i.
            if ((expected_flags == DEC_ADDI) ||
                (expected_flags == DEC_ANDI) ||
                (expected_flags == DEC_ORI) ||
                (expected_flags == DEC_XORI) ||
                (expected_flags == DEC_SLLI) ||
                (expected_flags == DEC_SRLI) ||
                (expected_flags == DEC_SRAI)) begin

                if (imm_i !== expected_imm) begin
                    $display("FAIL: instr=%h imm=%h expected=%h",
                             instr, imm_i, expected_imm);
                    $fatal(1, "Immediate sign-extension mismatch");
                end
            end

            test_count = test_count + 1;

            $display(
                "PASS: case=%0d instr=%h rs1=%0d rs2=%0d rd=%0d flags=%b",
                test_count,
                instr,
                rs1_addr,
                rs2_addr,
                rd_addr,
                decode_flags
            );
        end
    endtask

    initial begin
        instr = 32'd0;
        test_count = 0;

        $display(
            "Flag order: ADDI ADD SUB AND OR XOR ANDI ORI XORI SLL SRL SRA SLLI SRLI SRAI"
        );

        // Arguments:
        // instruction, rs1, raw rs2 field, rd, immediate, flags.
        //
        // For I-type instructions, the raw rs2 field is part
        // of the immediate, not a second source register.

        // 1. addi x1, x0, 5
        check_decode(
            32'h00500093, 5'd0, 5'd5, 5'd1, 32'd5, DEC_ADDI
        );

        // 2. addi x2, x0, 3
        check_decode(
            32'h00300113, 5'd0, 5'd3, 5'd2, 32'd3, DEC_ADDI
        );

        // 3. addi x2, x1, 3
        check_decode(
            32'h00308113, 5'd1, 5'd3, 5'd2, 32'd3, DEC_ADDI
        );

        // 4. addi x3, x1, -1
        check_decode(
            32'hfff08193, 5'd1, 5'd31, 5'd3,
            32'hffffffff, DEC_ADDI
        );

        // 5. NOP
        check_decode(
            32'h00000013, 5'd0, 5'd0, 5'd0, 32'd0, DEC_ADDI
        );

        // 6. SLTI: not supported yet.
        check_decode(
            32'h00502093, 5'd0, 5'd5, 5'd1, 32'd0, DEC_NONE
        );

        // 7. add x3, x1, x2
        check_decode(
            32'h002081b3, 5'd1, 5'd2, 5'd3, 32'd0, DEC_ADD
        );

        // 8. add x0, x0, x0
        check_decode(
            32'h00000033, 5'd0, 5'd0, 5'd0, 32'd0, DEC_ADD
        );

        // 9. sub x3, x1, x2
        check_decode(
            32'h402081b3, 5'd1, 5'd2, 5'd3, 32'd0, DEC_SUB
        );

        // 10. xor x3, x1, x2
        check_decode(
            32'h0020c1b3, 5'd1, 5'd2, 5'd3, 32'd0, DEC_XOR
        );

        // 11. sub x5, x4, x3
        check_decode(
            32'h403202b3, 5'd4, 5'd3, 5'd5, 32'd0, DEC_SUB
        );

        // 12. sub x0, x0, x0
        check_decode(
            32'h40000033, 5'd0, 5'd0, 5'd0, 32'd0, DEC_SUB
        );

        // 13. sra x3, x1, x2: now supported.
        check_decode(
            32'h4020d1b3, 5'd1, 5'd2, 5'd3, 32'd0, DEC_SRA
        );

        // 14. addi x3, x1, 1026
        check_decode(
            32'h40208193, 5'd1, 5'd2, 5'd3, 32'd1026, DEC_ADDI
        );

        // 15. and x3, x1, x2
        check_decode(
            32'h0020f1b3, 5'd1, 5'd2, 5'd3, 32'd0, DEC_AND
        );

        // 16. or x3, x1, x2
        check_decode(
            32'h0020e1b3, 5'd1, 5'd2, 5'd3, 32'd0, DEC_OR
        );

        // 17. and x0, x0, x0
        check_decode(
            32'h00007033, 5'd0, 5'd0, 5'd0, 32'd0, DEC_AND
        );

        // 18. or x0, x0, x0
        check_decode(
            32'h00006033, 5'd0, 5'd0, 5'd0, 32'd0, DEC_OR
        );

        // 19. xor x0, x0, x0
        check_decode(
            32'h00004033, 5'd0, 5'd0, 5'd0, 32'd0, DEC_XOR
        );

        // 20-22. Wrong funct7 for register logic instructions.
        check_decode(
            32'h4020f1b3, 5'd1, 5'd2, 5'd3, 32'd0, DEC_NONE
        );
        check_decode(
            32'h4020e1b3, 5'd1, 5'd2, 5'd3, 32'd0, DEC_NONE
        );
        check_decode(
            32'h4020c1b3, 5'd1, 5'd2, 5'd3, 32'd0, DEC_NONE
        );

        // 23. andi x3, x1, 2
        check_decode(
            32'h0020f193, 5'd1, 5'd2, 5'd3, 32'd2, DEC_ANDI
        );

        // 24. ori x3, x1, 2
        check_decode(
            32'h0020e193, 5'd1, 5'd2, 5'd3, 32'd2, DEC_ORI
        );

        // 25. xori x3, x1, 2
        check_decode(
            32'h0020c193, 5'd1, 5'd2, 5'd3, 32'd2, DEC_XORI
        );

        // 26. sll x3, x1, x2: now supported.
        check_decode(
            32'h002091b3, 5'd1, 5'd2, 5'd3, 32'd0, DEC_SLL
        );

        // 27-31. ANDI immediate tests.
        check_decode(
            32'h0000f193, 5'd1, 5'd0, 5'd3, 32'd0, DEC_ANDI
        );
        check_decode(
            32'hfff0f193, 5'd1, 5'd31, 5'd3,
            32'hffffffff, DEC_ANDI
        );
        check_decode(
            32'h7ff0f193, 5'd1, 5'd31, 5'd3,
            32'h000007ff, DEC_ANDI
        );
        check_decode(
            32'h8000f193, 5'd1, 5'd0, 5'd3,
            32'hfffff800, DEC_ANDI
        );
        check_decode(
            32'h4020f193, 5'd1, 5'd2, 5'd3, 32'd1026, DEC_ANDI
        );

        // 32-36. ORI immediate tests.
        check_decode(
            32'h0000e193, 5'd1, 5'd0, 5'd3, 32'd0, DEC_ORI
        );
        check_decode(
            32'hfff0e193, 5'd1, 5'd31, 5'd3,
            32'hffffffff, DEC_ORI
        );
        check_decode(
            32'h7ff0e193, 5'd1, 5'd31, 5'd3,
            32'h000007ff, DEC_ORI
        );
        check_decode(
            32'h8000e193, 5'd1, 5'd0, 5'd3,
            32'hfffff800, DEC_ORI
        );
        check_decode(
            32'h4020e193, 5'd1, 5'd2, 5'd3, 32'd1026, DEC_ORI
        );

        // 37-41. XORI immediate tests.
        check_decode(
            32'h0000c193, 5'd1, 5'd0, 5'd3, 32'd0, DEC_XORI
        );
        check_decode(
            32'hfff0c193, 5'd1, 5'd31, 5'd3,
            32'hffffffff, DEC_XORI
        );
        check_decode(
            32'h7ff0c193, 5'd1, 5'd31, 5'd3,
            32'h000007ff, DEC_XORI
        );
        check_decode(
            32'h8000c193, 5'd1, 5'd0, 5'd3,
            32'hfffff800, DEC_XORI
        );
        check_decode(
            32'h4020c193, 5'd1, 5'd2, 5'd3, 32'd1026, DEC_XORI
        );

        // 42. SLLI is now supported.
        check_decode(
            32'h00209193, 5'd1, 5'd2, 5'd3, 32'd2, DEC_SLLI
        );

        // 43. SRLI is now supported.
        check_decode(
            32'h0020d193, 5'd1, 5'd2, 5'd3, 32'd2, DEC_SRLI
        );

        // 44. Wrong opcode: must not be recognized as ANDI.
        check_decode(
            32'h0020f183, 5'd1, 5'd2, 5'd3, 32'd0, DEC_NONE
        );

        // 45. srl x3, x1, x2
        check_decode(
            32'h0020d1b3, 5'd1, 5'd2, 5'd3, 32'd0, DEC_SRL
        );

        // 46. sll x0, x0, x0
        check_decode(
            32'h00001033, 5'd0, 5'd0, 5'd0, 32'd0, DEC_SLL
        );

        // 47. srl x0, x0, x0
        check_decode(
            32'h00005033, 5'd0, 5'd0, 5'd0, 32'd0, DEC_SRL
        );

        // 48. sra x0, x0, x0
        check_decode(
            32'h40005033, 5'd0, 5'd0, 5'd0, 32'd0, DEC_SRA
        );

        // 49. sll x31, x31, x31
        check_decode(
            32'h01ff9fb3, 5'd31, 5'd31, 5'd31, 32'd0, DEC_SLL
        );

        // 50. srl x31, x31, x31
        check_decode(
            32'h01ffdfb3, 5'd31, 5'd31, 5'd31, 32'd0, DEC_SRL
        );

        // 51. sra x31, x31, x31
        check_decode(
            32'h41ffdfb3, 5'd31, 5'd31, 5'd31, 32'd0, DEC_SRA
        );

        // 52. SLL-like encoding with funct7 = 0100000.
        // There is no separate arithmetic-left-shift instruction.
        check_decode(
            32'h402091b3, 5'd1, 5'd2, 5'd3, 32'd0, DEC_NONE
        );

        // 53. SLL-like encoding with funct7 = 0000001.
        check_decode(
            32'h022091b3, 5'd1, 5'd2, 5'd3, 32'd0, DEC_NONE
        );

        // 54. Right-shift-like encoding with funct7 = 0000001.
        check_decode(
            32'h0220d1b3, 5'd1, 5'd2, 5'd3, 32'd0, DEC_NONE
        );

        // 55. SRAI is now supported; imm_i retains its raw I-immediate.
        check_decode(
            32'h4020d193, 5'd1, 5'd2, 5'd3, 32'd1026, DEC_SRAI
        );

        // 56. SLLI with shamt=31.
        check_decode(
            32'h01f09193, 5'd1, 5'd31, 5'd3, 32'd31, DEC_SLLI
        );

        // 96 legal cases, including rd=rs1=31 and every shamt 0..31.
        for (sh = 0; sh < 32; sh = sh + 1) begin
            check_decode({7'b0000000, sh[4:0], 5'd31, 3'b001, 5'd31, 7'h13},
                         5'd31, sh[4:0], 5'd31, sh, DEC_SLLI);
            check_decode({7'b0000000, sh[4:0], 5'd31, 3'b101, 5'd31, 7'h13},
                         5'd31, sh[4:0], 5'd31, sh, DEC_SRLI);
            check_decode({7'b0100000, sh[4:0], 5'd31, 3'b101, 5'd31, 7'h13},
                         5'd31, sh[4:0], 5'd31, 1024+sh, DEC_SRAI);
        end
        // 253 unsupported upper encodings: all except the three RV32 forms.
        for (upper = 0; upper < 128; upper = upper + 1) begin
            if (upper != 0)
                check_decode({upper[6:0], 5'd31, 5'd1, 3'b001, 5'd3, 7'h13},
                             5'd1, 5'd31, 5'd3, 32'd0, DEC_NONE);
            if ((upper != 0) && (upper != 32))
                check_decode({upper[6:0], 5'd31, 5'd1, 3'b101, 5'd3, 7'h13},
                             5'd1, 5'd31, 5'd3, 32'd0, DEC_NONE);
        end
        // A shift-like bit pattern with a different opcode is not an OP-IMM.
        check_decode(32'h00109183, 5'd1, 5'd1, 5'd3, 32'd0, DEC_NONE);
        check_decode(32'h0010d183, 5'd1, 5'd1, 5'd3, 32'd0, DEC_NONE);
        check_decode(32'h4010d183, 5'd1, 5'd1, 5'd3, 32'd0, DEC_NONE);
        if (test_count != 408) begin
            $fatal(1, "Unexpected test count");
        end

        $display(
            "PASS: decoder immediate shift test passed, %0d cases",
            test_count
        );

        $stop;
    end

endmodule
