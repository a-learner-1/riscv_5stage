`timescale 1ns/1ps

module if_stage_tb;

    reg clk;
    reg rst_n;

    wire [31:0] pc_f;
    wire [31:0] pc_x;
    wire [31:0] instr_x;
    wire valid_x;

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

                $display("FAIL: IF stage at time=%0t", $time);
                $display("expected pc=%h instr=%h",
                         expected_pc, expected_instr);
                $display("actual pc=%h instr=%h pc_f=%h valid=%b",
                         pc_x, instr_x, pc_f, valid_x);
                $fatal(1, "IF stage mismatch");
            end

            $display("PASS: pc_x=%h instr_x=%h",
                     pc_x, instr_x);
        end
    endtask

    initial begin
        rst_n = 1'b0;

        #1;
        if (pc_f !== 32'd0 ||
            pc_x !== 32'd0 ||
            instr_x !== 32'h00000013 ||
            valid_x !== 1'b0) begin
            $fatal(1, "IF reset mismatch");
        end

        #11;
        rst_n = 1'b1;

        check_fetch(32'd0,  32'h00500093);
        check_fetch(32'd4,  32'h00308113);
        check_fetch(32'd8,  32'h002081b3);
        check_fetch(32'd12, 32'h00318233);
        check_fetch(32'd16, 32'h403202b3);
        check_fetch(32'd20, 32'h40508333);
        check_fetch(32'd24, 32'h004373b3);
        check_fetch(32'd28, 32'h0070e433);
        check_fetch(32'd32, 32'h007444b3);

        check_fetch(32'd36, 32'h0094f513);
        check_fetch(32'd40, 32'h00a56593);
        check_fetch(32'd44, 32'h00b5c613);
        check_fetch(32'd48, 32'hfff64693);
        check_fetch(32'd52, 32'h8006f713);
        check_fetch(32'd56, 32'hfff76793);

        check_fetch(32'd60, 32'h00a79833);
        check_fetch(32'd64, 32'h00a858b3);
        check_fetch(32'd68, 32'h40a85933);
        check_fetch(32'd72, 32'h02100993);
        check_fetch(32'd76, 32'h41335a33);
        check_fetch(32'd80, 32'h01351ab3);
        check_fetch(32'd84, 32'h00aadb33);
        check_fetch(32'd88, 32'h016b1bb3);
        check_fetch(32'd92, 32'h02000c13);
        check_fetch(32'd96, 32'h01885cb3);
        check_fetch(32'd100, 32'h00000013);

        $display("PASS: IF stage 25-instruction test passed");
        $stop;
    end

    initial begin
        #2000;
        $fatal(1, "IF test timeout");
    end

endmodule

