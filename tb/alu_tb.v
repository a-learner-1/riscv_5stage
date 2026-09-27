`timescale 1ns/1ps

module alu_tb;

    localparam [3:0] ALU_ADD = 4'b000;
    localparam [3:0] ALU_SUB = 4'b001;
    localparam [3:0] ALU_AND = 4'b010;
    localparam [3:0] ALU_OR  = 4'b011;
    localparam [3:0] ALU_XOR = 4'b100;

    localparam [3:0] ALU_SLT = 4'b1000;
    localparam [3:0] ALU_SLTU = 4'b1001;
    reg  [31:0] a;
    reg  [31:0] b;
    reg  [3:0]  alu_op;
    wire [31:0] result;

    integer test_count;

    alu dut (
        .a      (a),
        .b      (b),
        .alu_op (alu_op),
        .result (result)
    );

    task check_alu;
        input [3:0]  test_op;
        input [31:0] test_a;
        input [31:0] test_b;
        input [31:0] expected;
        begin
            alu_op = test_op;
            a      = test_a;
            b      = test_b;
            #1;

            if (result !== expected) begin
                $display(
                    "FAIL: op=%b a=%h b=%h result=%h expected=%h",
                    alu_op, a, b, result, expected
                );
                $fatal(1);
            end

            test_count = test_count + 1;

            $display(
                "PASS: case=%0d op=%b a=%h b=%h result=%h",
                test_count, alu_op, a, b, result
            );
        end
    endtask

    initial begin
        test_count = 0;

        // ----------------------------------------
        // Original 14 ADD/SUB cases.
        // ----------------------------------------

        // 1. 0 + 5 = 5
        check_alu(ALU_ADD, 32'd0, 32'd5, 32'd5);

        // 2. 5 + 3 = 8
        check_alu(ALU_ADD, 32'd5, 32'd3, 32'd8);

        // 3. 5 + (-1) = 4
        check_alu(ALU_ADD, 32'd5, 32'hffffffff, 32'd4);

        // 4. Addition wraparound.
        check_alu(ALU_ADD, 32'hffffffff, 32'd1, 32'd0);

        // 5. Signed overflow, keep the low 32 bits.
        check_alu(
            ALU_ADD, 32'h7fffffff, 32'd1, 32'h80000000
        );

        // 6. 13 - 8 = 5
        check_alu(ALU_SUB, 32'd13, 32'd8, 32'd5);

        // 7. 5 - 8 = -3
        check_alu(ALU_SUB, 32'd5, 32'd8, 32'hfffffffd);

        // 8. 5 - 5 = 0
        check_alu(ALU_SUB, 32'd5, 32'd5, 32'd0);

        // 9. 0 - 1 = -1
        check_alu(ALU_SUB, 32'd0, 32'd1, 32'hffffffff);

        // 10. 5 - (-1) = 6
        check_alu(ALU_SUB, 32'd5, 32'hffffffff, 32'd6);

        // 11. Subtraction wraparound.
        check_alu(
            ALU_SUB, 32'h80000000, 32'd1, 32'h7fffffff
        );

        // 12-14. Change only the operation.
        check_alu(ALU_ADD, 32'd7, 32'd2, 32'd9);
        check_alu(ALU_SUB, 32'd7, 32'd2, 32'd5);
        check_alu(ALU_ADD, 32'd7, 32'd2, 32'd9);

        // ----------------------------------------
        // AND tests.
        // ----------------------------------------

        // 15. AND with all ones preserves the input.
        check_alu(
            ALU_AND, 32'ha5a5a5a5, 32'hffffffff, 32'ha5a5a5a5
        );

        // 16. AND with zero produces zero.
        check_alu(
            ALU_AND, 32'ha5a5a5a5, 32'h00000000, 32'h00000000
        );

        // 17. Apply a mask to every byte.
        check_alu(
            ALU_AND, 32'ha5a5a5a5, 32'h0f0f0f0f, 32'h05050505
        );

        // ----------------------------------------
        // OR tests.
        // ----------------------------------------

        // 18. OR with zero preserves the input.
        check_alu(
            ALU_OR, 32'ha5a5a5a5, 32'h00000000, 32'ha5a5a5a5
        );

        // 19. OR with all ones produces all ones.
        check_alu(
            ALU_OR, 32'ha5a5a5a5, 32'hffffffff, 32'hffffffff
        );

        // 20. Set the low four bits of every byte.
        check_alu(
            ALU_OR, 32'ha5a5a5a5, 32'h0f0f0f0f, 32'hafafafaf
        );

        // ----------------------------------------
        // XOR tests.
        // ----------------------------------------

        // 21. XOR with itself produces zero.
        check_alu(
            ALU_XOR, 32'ha5a5a5a5, 32'ha5a5a5a5, 32'h00000000
        );

        // 22. XOR with all ones inverts every bit.
        check_alu(
            ALU_XOR, 32'ha5a5a5a5, 32'hffffffff, 32'h5a5a5a5a
        );

        // 23. Invert the low four bits of every byte.
        check_alu(
            ALU_XOR, 32'ha5a5a5a5, 32'h0f0f0f0f, 32'haaaaaaaa
        );

        // ----------------------------------------
        // Same inputs, five different operations.
        // a = 12 (1100), b = 10 (1010).
        // ----------------------------------------

        // 24. 12 + 10 = 22
        check_alu(ALU_ADD, 32'd12, 32'd10, 32'd22);

        // 25. 12 - 10 = 2
        check_alu(ALU_SUB, 32'd12, 32'd10, 32'd2);

        // 26. 1100 AND 1010 = 1000
        check_alu(ALU_AND, 32'd12, 32'd10, 32'd8);

        // 27. 1100 OR 1010 = 1110
        check_alu(ALU_OR, 32'd12, 32'd10, 32'd14);

        // 28. 1100 XOR 1010 = 0110
        check_alu(ALU_XOR, 32'd12, 32'd10, 32'd6);

        // ----------------------------------------
        // Shift operations, including masking of the full B operand.
        check_alu(3'd5, 32'h00000001, 32'd0, 32'h00000001);
        check_alu(3'd5, 32'h00000001, 32'd1, 32'h00000002);
        check_alu(3'd5, 32'h00000001, 32'd31, 32'h80000000);
        check_alu(3'd5, 32'h00000001, 32'd32, 32'h00000001);
        check_alu(3'd5, 32'h00000001, 32'd33, 32'h00000002);
        check_alu(3'd5, 32'hffffffff, 32'd31, 32'h80000000);
        check_alu(3'd6, 32'h80000000, 32'd0, 32'h80000000);
        check_alu(3'd6, 32'hfffffffe, 32'd1, 32'h7fffffff);
        check_alu(3'd6, 32'h80000000, 32'd31, 32'h00000001);
        check_alu(3'd6, 32'hfffffffe, 32'd32, 32'hfffffffe);
        check_alu(3'd6, 32'hfffffffe, 32'd33, 32'h7fffffff);
        check_alu(3'd6, 32'h00000000, 32'd31, 32'h00000000);
        check_alu(3'd7, 32'hfffffff8, 32'd0, 32'hfffffff8);
        check_alu(3'd7, 32'hfffffff8, 32'd1, 32'hfffffffc);
        check_alu(3'd7, 32'h80000000, 32'd31, 32'hffffffff);
        check_alu(3'd7, 32'hfffffff8, 32'd32, 32'hfffffff8);
        check_alu(3'd7, 32'hfffffff8, 32'd33, 32'hfffffffc);
        check_alu(3'd7, 32'h7fffffff, 32'd31, 32'h00000000);
        check_alu(ALU_SLT, 32'h00000000, 32'h00000000, 32'd0);
        check_alu(ALU_SLT, 32'hffffffff, 32'h00000000, 32'd1);
        check_alu(ALU_SLT, 32'h00000000, 32'hffffffff, 32'd0);
        check_alu(ALU_SLT, 32'h80000000, 32'h7fffffff, 32'd1);
        check_alu(ALU_SLT, 32'h7fffffff, 32'h80000000, 32'd0);
        check_alu(ALU_SLT, 32'hffffffff, 32'hffffffff, 32'd0);
        check_alu(ALU_SLT, 32'h80000000, 32'hffffffff, 32'd1);
        check_alu(ALU_SLT, 32'hffffffff, 32'h80000000, 32'd0);
        check_alu(ALU_SLTU, 32'h00000000, 32'h00000000, 32'd0);
        check_alu(ALU_SLTU, 32'hffffffff, 32'h00000000, 32'd0);
        check_alu(ALU_SLTU, 32'h00000000, 32'hffffffff, 32'd1);
        check_alu(ALU_SLTU, 32'h80000000, 32'h7fffffff, 32'd0);
        check_alu(ALU_SLTU, 32'h7fffffff, 32'h80000000, 32'd1);
        check_alu(ALU_SLTU, 32'hffffffff, 32'hffffffff, 32'd0);
        check_alu(ALU_SLTU, 32'h80000000, 32'hffffffff, 32'd1);
        check_alu(ALU_SLTU, 32'hffffffff, 32'h80000000, 32'd0);
        if (test_count != 62) $fatal(1, "ALU case count mismatch");
        $display("PASS: ALU regression passed, %0d cases", test_count);
        $stop;
    end
endmodule
