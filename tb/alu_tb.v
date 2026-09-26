`timescale 1ns/1ps

module alu_tb;

    reg  [31:0] a;
    reg  [31:0] b;
    reg         sub;
    wire [31:0] result;

    alu dut (
        .a      (a),
        .b      (b),
        .sub    (sub),
        .result (result)
    );

    task check_alu;
        input        test_sub;
        input [31:0] test_a;
        input [31:0] test_b;
        input [31:0] expected;
        begin
            sub = test_sub;
            a   = test_a;
            b   = test_b;
            #1;

            if (result !== expected) begin
                $display(
                    "FAIL: sub=%b a=%h b=%h result=%h expected=%h",
                    sub, a, b, result, expected
                );
                $fatal(1);
            end

            $display(
                "PASS: sub=%b a=%h b=%h result=%h",
                sub, a, b, result
            );
        end
    endtask

    initial begin
        // Keep the original addition tests.

        // 0 + 5 = 5
        check_alu(
            1'b0, 32'd0, 32'd5, 32'd5
        );

        // 5 + 3 = 8
        check_alu(
            1'b0, 32'd5, 32'd3, 32'd8
        );

        // 5 + (-1) = 4
        check_alu(
            1'b0, 32'd5, 32'hffffffff, 32'd4
        );

        // Keep only the low 32 bits.
        check_alu(
            1'b0, 32'hffffffff, 32'd1, 32'd0
        );

        // Signed overflow: no exception, keep the bit pattern.
        check_alu(
            1'b0, 32'h7fffffff, 32'd1, 32'h80000000
        );

        // New subtraction tests.

        // 13 - 8 = 5
        check_alu(
            1'b1, 32'd13, 32'd8, 32'd5
        );

        // 5 - 8 = -3
        check_alu(
            1'b1, 32'd5, 32'd8, 32'hfffffffd
        );

        // 5 - 5 = 0
        check_alu(
            1'b1, 32'd5, 32'd5, 32'd0
        );

        // 0 - 1 = -1
        check_alu(
            1'b1, 32'd0, 32'd1, 32'hffffffff
        );

        // 5 - (-1) = 6
        check_alu(
            1'b1, 32'd5, 32'hffffffff, 32'd6
        );

        // Signed overflow: 0x80000000 - 1 wraps to 0x7fffffff.
        check_alu(
            1'b1, 32'h80000000, 32'd1, 32'h7fffffff
        );

        // Keep a and b unchanged; change only the operation.
        // This verifies that sub controls the result immediately.

        // 7 + 2 = 9
        check_alu(
            1'b0, 32'd7, 32'd2, 32'd9
        );

        // 7 - 2 = 5
        check_alu(
            1'b1, 32'd7, 32'd2, 32'd5
        );

        // 7 + 2 = 9 again
        check_alu(
            1'b0, 32'd7, 32'd2, 32'd9
        );

        $display("PASS: ALU ADD/SUB test passed, 14 cases");
        $stop;
    end

endmodule