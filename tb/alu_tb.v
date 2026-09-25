`timescale 1ns/1ps

module alu_tb;

    reg  [31:0] a;
    reg  [31:0] b;
    wire [31:0] result;

    alu dut (
        .a      (a),
        .b      (b),
        .result (result)
    );

    task check_add;
        input [31:0] test_a;
        input [31:0] test_b;
        input [31:0] expected;
        begin
            a = test_a;
            b = test_b;
            #1;

            if (result !== expected) begin
                $display("FAIL: %h + %h = %h, expected %h",
                         a, b, result, expected);
                $fatal(1);
            end

            $display("PASS: %h + %h = %h", a, b, result);
        end
    endtask

    initial begin
        check_add(32'd0,          32'd5,  32'd5);
        check_add(32'd5,          32'd3,  32'd8);
        check_add(32'd5,  32'hffffffff,  32'd4);  // 5 + (-1)
        check_add(32'hffffffff,   32'd1,  32'd0);  // 32-bit wraparound
        check_add(32'h7fffffff,   32'd1,  32'h80000000);

        $display("PASS: alu test passed");
        $stop;
    end

endmodule