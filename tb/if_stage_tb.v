`timescale 1ns/1ps

module if_stage_tb;

    reg clk;
    reg rst_n;

    wire [31:0] pc_f;
    wire [31:0] pc_x;
    wire [31:0] instr_x;
    wire        valid_x;

    if_stage dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .pc_f    (pc_f),
        .pc_x    (pc_x),
        .instr_x (instr_x),
        .valid_x (valid_x)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task check_fetch;
        input [31:0] expected_pc;
        input [31:0] expected_instr;
        begin
            @(posedge clk);
            #1;
            if (valid_x !== 1'b1 ||
                pc_x !== expected_pc ||
                instr_x !== expected_instr ||
                pc_f !== (expected_pc + 32'd4)) begin
                $display("FAIL: pc_f=%h pc_x=%h instr_x=%h valid_x=%b",
                         pc_f, pc_x, instr_x, valid_x);
                $fatal(1);
            end

            $display("PASS: pc_x=%h instr_x=%h", pc_x, instr_x);
        end
    endtask

    initial begin
        rst_n = 1'b0;
        #12 rst_n = 1'b1;

        check_fetch(32'd0,  32'h00500093);
        check_fetch(32'd4,  32'h00308113);
        check_fetch(32'd8,  32'h002081b3);
        check_fetch(32'd12, 32'h00318233);
        check_fetch(32'd16, 32'h403202b3);
        check_fetch(32'd20, 32'h40508333);
        check_fetch(32'd24, 32'h00000013);

        $display("PASS: IF stage six-instruction test passed");
        $stop;
    end

endmodule
