`timescale 1ns/1ps

module decoder_tb;

    reg  [31:0] instr;
    wire [4:0]  rs1_addr;
    wire [4:0]  rs2_addr;
    wire [4:0]  rd_addr;
    wire [31:0] imm_i;
    wire        is_addi;
    wire        is_add;
    wire        is_sub;

    decoder dut (
        .instr    (instr),
        .rs1_addr (rs1_addr),
        .rs2_addr (rs2_addr),
        .rd_addr  (rd_addr),
        .imm_i    (imm_i),
        .is_addi  (is_addi),
        .is_add   (is_add),
        .is_sub   (is_sub)
    );

    task check_decode;
        input [31:0] test_instr;
        input [4:0]  expected_rs1;
        input [4:0]  expected_rs2;
        input [4:0]  expected_rd;
        input [31:0] expected_imm;
        input        expected_is_addi;
        input        expected_is_add;
        input        expected_is_sub;
        begin
            instr = test_instr;
            #1;

            // Check raw address fields and instruction recognition.
            if ((rs1_addr !== expected_rs1) ||
                (rs2_addr !== expected_rs2) ||
                (rd_addr  !== expected_rd)  ||
                (is_addi  !== expected_is_addi) ||
                (is_add   !== expected_is_add) ||
                (is_sub   !== expected_is_sub)) begin

                $display("FAIL: instr=%h", instr);
                $display(
                    "  actual: rs1=%d rs2=%d rd=%d",
                    rs1_addr, rs2_addr, rd_addr
                );
                $display(
                    "  expected: rs1=%d rs2=%d rd=%d",
                    expected_rs1, expected_rs2, expected_rd
                );
                $display(
                    "  actual: addi=%b add=%b sub=%b",
                    is_addi, is_add, is_sub
                );
                $display(
                    "  expected: addi=%b add=%b sub=%b",
                    expected_is_addi, expected_is_add,
                    expected_is_sub
                );
                $fatal(1);
            end

            // Only ADDI uses the I-type immediate here.
            if (expected_is_addi &&
                (imm_i !== expected_imm)) begin
                $display(
                    "FAIL: instr=%h imm=%h expected=%h",
                    instr, imm_i, expected_imm
                );
                $fatal(1);
            end

            $display(
                "PASS: instr=%h rs1=%d rs2=%d rd=%d addi=%b add=%b sub=%b",
                instr, rs1_addr, rs2_addr, rd_addr,
                is_addi, is_add, is_sub
            );
        end
    endtask

    initial begin
        // Arguments:
        // instr, rs1, rs2 field, rd, immediate, ADDI, ADD, SUB.
        // The immediate argument is ignored for non-ADDI instructions.

        // 1. addi x1, x0, 5
        check_decode(
            32'h00500093, 5'd0, 5'd5, 5'd1,
            32'd5, 1'b1, 1'b0, 1'b0
        );

        // 2. addi x2, x0, 3
        check_decode(
            32'h00300113, 5'd0, 5'd3, 5'd2,
            32'd3, 1'b1, 1'b0, 1'b0
        );

        // 3. addi x2, x1, 3
        check_decode(
            32'h00308113, 5'd1, 5'd3, 5'd2,
            32'd3, 1'b1, 1'b0, 1'b0
        );

        // 4. addi x3, x1, -1: sign extension.
        check_decode(
            32'hfff08193, 5'd1, 5'd31, 5'd3,
            32'hffffffff, 1'b1, 1'b0, 1'b0
        );

        // 5. NOP: addi x0, x0, 0.
        check_decode(
            32'h00000013, 5'd0, 5'd0, 5'd0,
            32'd0, 1'b1, 1'b0, 1'b0
        );

        // 6. slti x1, x0, 5: none of the supported instructions.
        check_decode(
            32'h00502093, 5'd0, 5'd5, 5'd1,
            32'd0, 1'b0, 1'b0, 1'b0
        );

        // 7. add x3, x1, x2: must not decode as SUB.
        check_decode(
            32'h002081b3, 5'd1, 5'd2, 5'd3,
            32'd0, 1'b0, 1'b1, 1'b0
        );

        // 8. add x0, x0, x0.
        check_decode(
            32'h00000033, 5'd0, 5'd0, 5'd0,
            32'd0, 1'b0, 1'b1, 1'b0
        );

        // 9. sub x3, x1, x2: must not decode as ADD.
        check_decode(
            32'h402081b3, 5'd1, 5'd2, 5'd3,
            32'd0, 1'b0, 1'b0, 1'b1
        );

        // 10. xor x3, x1, x2: different funct3.
        check_decode(
            32'h0020c1b3, 5'd1, 5'd2, 5'd3,
            32'd0, 1'b0, 1'b0, 1'b0
        );

        // 11. sub x5, x4, x3: verify another set of addresses.
        check_decode(
            32'h403202b3, 5'd4, 5'd3, 5'd5,
            32'd0, 1'b0, 1'b0, 1'b1
        );

        // 12. sub x0, x0, x0: still a SUB instruction.
        check_decode(
            32'h40000033, 5'd0, 5'd0, 5'd0,
            32'd0, 1'b0, 1'b0, 1'b1
        );

        // 13. sra x3, x1, x2:
        // same funct7 as SUB, but different funct3.
        check_decode(
            32'h4020d1b3, 5'd1, 5'd2, 5'd3,
            32'd0, 1'b0, 1'b0, 1'b0
        );

        // 14. addi x3, x1, 1026:
        // bits [31:25] match SUB's funct7 value,
        // but these bits belong to the immediate.
        check_decode(
            32'h40208193, 5'd1, 5'd2, 5'd3,
            32'd1026, 1'b1, 1'b0, 1'b0
        );

        $display("PASS: decoder ADDI/ADD/SUB test passed, 14 cases");
        $stop;
    end

endmodule
