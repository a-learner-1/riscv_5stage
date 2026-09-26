`timescale 1ns/1ps

module decoder_tb;

    // Flag order: ADDI, ADD, SUB, AND, OR, XOR.
    localparam [5:0] DEC_NONE = 6'b000000;
    localparam [5:0] DEC_ADDI = 6'b100000;
    localparam [5:0] DEC_ADD  = 6'b010000;
    localparam [5:0] DEC_SUB  = 6'b001000;
    localparam [5:0] DEC_AND  = 6'b000100;
    localparam [5:0] DEC_OR   = 6'b000010;
    localparam [5:0] DEC_XOR  = 6'b000001;

    reg  [31:0] instr;

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

    wire [5:0] decode_flags;

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
        .is_xor   (is_xor)
    );

    assign decode_flags = {
        is_addi, is_add, is_sub, is_and, is_or, is_xor
    };

    task check_decode;
        input [31:0] test_instr;
        input [4:0]  expected_rs1;
        input [4:0]  expected_rs2;
        input [4:0]  expected_rd;
        input [31:0] expected_imm;
        input [5:0]  expected_flags;
        begin
            instr = test_instr;
            #1;

            if ((rs1_addr !== expected_rs1) ||
                (rs2_addr !== expected_rs2) ||
                (rd_addr !== expected_rd) ||
                (decode_flags !== expected_flags)) begin

                $display("FAIL: instr=%h", instr);
                $display(
                    "  actual: rs1=%d rs2=%d rd=%d flags=%b",
                    rs1_addr, rs2_addr, rd_addr, decode_flags
                );
                $display(
                    "  expected: rs1=%d rs2=%d rd=%d flags=%b",
                    expected_rs1, expected_rs2,
                    expected_rd, expected_flags
                );
                $fatal(1);
            end

            // Only ADDI uses the I-type immediate here.
            if ((expected_flags == DEC_ADDI) &&
                (imm_i !== expected_imm)) begin
                $display(
                    "FAIL: instr=%h imm=%h expected=%h",
                    instr, imm_i, expected_imm
                );
                $fatal(1);
            end

            test_count = test_count + 1;

            $display(
                "PASS: case=%0d instr=%h rs1=%d rs2=%d rd=%d flags=%b",
                test_count, instr,
                rs1_addr, rs2_addr, rd_addr, decode_flags
            );
        end
    endtask

    initial begin
        test_count = 0;
        $display("Flag order: ADDI ADD SUB AND OR XOR");

        // Arguments:
        // instr, rs1, raw rs2 field, rd, immediate, flags.
        // Immediate is checked only for ADDI.

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

        // 6. slti x1, x0, 5: not supported yet.
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

        // 10. xor x3, x1, x2: NOW supported.
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

        // 13. sra x3, x1, x2: not supported yet.
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

        // 20. AND-like funct3, but wrong funct7.
        check_decode(
            32'h4020f1b3, 5'd1, 5'd2, 5'd3, 32'd0, DEC_NONE
        );

        // 21. OR-like funct3, but wrong funct7.
        check_decode(
            32'h4020e1b3, 5'd1, 5'd2, 5'd3, 32'd0, DEC_NONE
        );

        // 22. XOR-like funct3, but wrong funct7.
        check_decode(
            32'h4020c1b3, 5'd1, 5'd2, 5'd3, 32'd0, DEC_NONE
        );

        // 23. andi x3, x1, 2: different opcode, not supported yet.
        check_decode(
            32'h0020f193, 5'd1, 5'd2, 5'd3, 32'd0, DEC_NONE
        );

        // 24. ori x3, x1, 2: different opcode, not supported yet.
        check_decode(
            32'h0020e193, 5'd1, 5'd2, 5'd3, 32'd0, DEC_NONE
        );

        // 25. xori x3, x1, 2: different opcode, not supported yet.
        check_decode(
            32'h0020c193, 5'd1, 5'd2, 5'd3, 32'd0, DEC_NONE
        );

        // 26. sll x3, x1, x2: different funct3, not supported yet.
        check_decode(
            32'h002091b3, 5'd1, 5'd2, 5'd3, 32'd0, DEC_NONE
        );

        $display(
            "PASS: decoder ADDI/ADD/SUB/AND/OR/XOR test passed, %0d cases",
            test_count
        );
        $stop;
    end

endmodule
