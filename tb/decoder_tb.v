`timescale 1ns/1ps

module decoder_tb;

    // Flag order:
    // ADDI ADD SUB AND OR XOR ANDI ORI XORI
    localparam [8:0] DEC_NONE = 9'b000000000;
    localparam [8:0] DEC_ADDI = 9'b100000000;
    localparam [8:0] DEC_ADD  = 9'b010000000;
    localparam [8:0] DEC_SUB  = 9'b001000000;
    localparam [8:0] DEC_AND  = 9'b000100000;
    localparam [8:0] DEC_OR   = 9'b000010000;
    localparam [8:0] DEC_XOR  = 9'b000001000;
    localparam [8:0] DEC_ANDI = 9'b000000100;
    localparam [8:0] DEC_ORI  = 9'b000000010;
    localparam [8:0] DEC_XORI = 9'b000000001;

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

    wire [8:0] decode_flags;

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
        .is_xori  (is_xori)
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
        is_xori
    };

    task check_decode;
        input [31:0] test_instr;
        input [4:0]  expected_rs1;
        input [4:0]  expected_rs2;
        input [4:0]  expected_rd;
        input [31:0] expected_imm;
        input [8:0]  expected_flags;
        begin
            instr = test_instr;
            #1;

            // Check extracted fields and all instruction flags.
            if (rs1_addr !== expected_rs1 ||
                rs2_addr !== expected_rs2 ||
                rd_addr !== expected_rd ||
                decode_flags !== expected_flags) begin

                $display("FAIL: case=%0d instr=%h",
                         test_count + 1, instr);

                $display("  actual: rs1=%0d rs2=%0d rd=%0d flags=%b",
                         rs1_addr,
                         rs2_addr,
                         rd_addr,
                         decode_flags);

                $display("  expected: rs1=%0d rs2=%0d rd=%0d flags=%b",
                         expected_rs1,
                         expected_rs2,
                         expected_rd,
                         expected_flags);

                $fatal(1, "Decoder field or flag mismatch");
            end

            // Check the sign-extended immediate for all supported
            // I-type arithmetic and logic instructions.
            if ((expected_flags == DEC_ADDI) ||
                (expected_flags == DEC_ANDI) ||
                (expected_flags == DEC_ORI) ||
                (expected_flags == DEC_XORI)) begin

                if (imm_i !== expected_imm) begin
                    $display("FAIL: case=%0d instr=%h",
                             test_count + 1, instr);

                    $display("  immediate actual=%h expected=%h",
                             imm_i, expected_imm);

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

        $display("Flag order: ADDI ADD SUB AND OR XOR ANDI ORI XORI");

        // Arguments:
        // instruction, rs1, raw rs2 field, rd, immediate, flags.
        //
        // For I-type instructions, instr[24:20] is part of the
        // immediate. The raw rs2 field is not a source register.
        //
        // The immediate argument is checked only for:
        // ADDI, ANDI, ORI and XORI.

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

        // 5. NOP: addi x0, x0, 0
        check_decode(
            32'h00000013, 5'd0, 5'd0, 5'd0, 32'd0, DEC_ADDI
        );

        // 6. SLTI is not supported yet.
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

        // 13. SRA is not supported yet.
        check_decode(
            32'h4020d1b3, 5'd1, 5'd2, 5'd3, 32'd0, DEC_NONE
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

        // 20. AND-like R-type encoding with wrong funct7.
        check_decode(
            32'h4020f1b3, 5'd1, 5'd2, 5'd3, 32'd0, DEC_NONE
        );

        // 21. OR-like R-type encoding with wrong funct7.
        check_decode(
            32'h4020e1b3, 5'd1, 5'd2, 5'd3, 32'd0, DEC_NONE
        );

        // 22. XOR-like R-type encoding with wrong funct7.
        check_decode(
            32'h4020c1b3, 5'd1, 5'd2, 5'd3, 32'd0, DEC_NONE
        );

        // 23. andi x3, x1, 2: now supported.
        check_decode(
            32'h0020f193, 5'd1, 5'd2, 5'd3, 32'd2, DEC_ANDI
        );

        // 24. ori x3, x1, 2: now supported.
        check_decode(
            32'h0020e193, 5'd1, 5'd2, 5'd3, 32'd2, DEC_ORI
        );

        // 25. xori x3, x1, 2: now supported.
        check_decode(
            32'h0020c193, 5'd1, 5'd2, 5'd3, 32'd2, DEC_XORI
        );

        // 26. SLL is not supported yet.
        check_decode(
            32'h002091b3, 5'd1, 5'd2, 5'd3, 32'd0, DEC_NONE
        );

        // 27. andi x3, x1, 0
        check_decode(
            32'h0000f193, 5'd1, 5'd0, 5'd3, 32'd0, DEC_ANDI
        );

        // 28. andi x3, x1, -1
        check_decode(
            32'hfff0f193, 5'd1, 5'd31, 5'd3,
            32'hffffffff, DEC_ANDI
        );

        // 29. andi x3, x1, 2047: maximum positive immediate.
        check_decode(
            32'h7ff0f193, 5'd1, 5'd31, 5'd3,
            32'h000007ff, DEC_ANDI
        );

        // 30. andi x3, x1, -2048: minimum negative immediate.
        check_decode(
            32'h8000f193, 5'd1, 5'd0, 5'd3,
            32'hfffff800, DEC_ANDI
        );

        // 31. andi x3, x1, 1026
        // Upper immediate bits must not be treated as funct7.
        check_decode(
            32'h4020f193, 5'd1, 5'd2, 5'd3, 32'd1026, DEC_ANDI
        );

        // 32. ori x3, x1, 0
        check_decode(
            32'h0000e193, 5'd1, 5'd0, 5'd3, 32'd0, DEC_ORI
        );

        // 33. ori x3, x1, -1
        check_decode(
            32'hfff0e193, 5'd1, 5'd31, 5'd3,
            32'hffffffff, DEC_ORI
        );

        // 34. ori x3, x1, 2047
        check_decode(
            32'h7ff0e193, 5'd1, 5'd31, 5'd3,
            32'h000007ff, DEC_ORI
        );

        // 35. ori x3, x1, -2048
        check_decode(
            32'h8000e193, 5'd1, 5'd0, 5'd3,
            32'hfffff800, DEC_ORI
        );

        // 36. ori x3, x1, 1026
        check_decode(
            32'h4020e193, 5'd1, 5'd2, 5'd3, 32'd1026, DEC_ORI
        );

        // 37. xori x3, x1, 0
        check_decode(
            32'h0000c193, 5'd1, 5'd0, 5'd3, 32'd0, DEC_XORI
        );

        // 38. xori x3, x1, -1
        check_decode(
            32'hfff0c193, 5'd1, 5'd31, 5'd3,
            32'hffffffff, DEC_XORI
        );

        // 39. xori x3, x1, 2047
        check_decode(
            32'h7ff0c193, 5'd1, 5'd31, 5'd3,
            32'h000007ff, DEC_XORI
        );

        // 40. xori x3, x1, -2048
        check_decode(
            32'h8000c193, 5'd1, 5'd0, 5'd3,
            32'hfffff800, DEC_XORI
        );

        // 41. xori x3, x1, 1026
        check_decode(
            32'h4020c193, 5'd1, 5'd2, 5'd3, 32'd1026, DEC_XORI
        );

        // 42. SLLI is not supported yet.
        check_decode(
            32'h00209193, 5'd1, 5'd2, 5'd3, 32'd0, DEC_NONE
        );

        // 43. SRLI is not supported yet.
        check_decode(
            32'h0020d193, 5'd1, 5'd2, 5'd3, 32'd0, DEC_NONE
        );

        // 44. Same fields as ANDI, but opcode is 0000011.
        // Must not be recognized as ANDI.
        check_decode(
            32'h0020f183, 5'd1, 5'd2, 5'd3, 32'd0, DEC_NONE
        );

        if (test_count != 44) begin
            $fatal(1, "Unexpected test count");
        end

        $display(
            "PASS: decoder ADDI/ADD/SUB/AND/OR/XOR/ANDI/ORI/XORI test passed, %0d cases",
            test_count
        );

        $stop;
    end

endmodule
