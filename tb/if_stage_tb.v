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
        check_fetch(32'd100, 32'h001c9d13);
        check_fetch(32'd104, 32'h001d5d93);
        check_fetch(32'd108, 32'h401d5e13);
        check_fetch(32'd112, 32'h01f51e93);
        check_fetch(32'd116, 32'h01fedf13);
        check_fetch(32'd120, 32'h41fedf93);
        check_fetch(32'd124, 32'h000f9d13);
        check_fetch(32'd128, 32'h000d5d93);
        check_fetch(32'd132, 32'h400dde13);
        check_fetch(32'd136, 32'h01ce1e93);
        check_fetch(32'd140, 32'h01dedf13);
        check_fetch(32'd144, 32'h41eedf93);
        check_fetch(32'd148, 32'h001f9013);
        check_fetch(32'd152, 32'h00106d13);
        check_fetch(32'd156, 32'h001d5d93);
        check_fetch(32'd160, 32'h401d5e13);
        check_fetch(32'd164, 32'h01afa0b3);
        check_fetch(32'd168, 32'h01afb133);
        check_fetch(32'd172, 32'h000fa193);
        check_fetch(32'd176, 32'h000fb213);
        check_fetch(32'd180, 32'hfffdb293);
        check_fetch(32'd184, 32'hffffa313);
        check_fetch(32'd188, 32'h01d8a3b3);
        check_fetch(32'd192, 32'h01d8b433);
        check_fetch(32'd196, 32'h800ea493);
        check_fetch(32'd200, 32'h800eb513);
        check_fetch(32'd204, 32'h001d2593);
        check_fetch(32'd208, 32'h001d3613);
        check_fetch(32'd212, 32'h01fd26b3);
        check_fetch(32'd216, 32'h01fd3733);
        check_fetch(32'd220, 32'h01a727b3);
        check_fetch(32'd224, 32'h00f73833);
        check_fetch(32'd228, 32'h010828b3);
        check_fetch(32'd232, 32'h0118b913);
        check_fetch(32'd236, 32'h01afa033);
        check_fetch(32'd240, 32'hffff3993);
        check_fetch(32'd244, 32'h7fff2a13);
        check_fetch(32'd248, 32'h011eaab3);
        check_fetch(32'd252, 32'h115a80b7);
        check_fetch(32'd256, 32'h00508113);
        check_fetch(32'd260, 32'h00000197);
        check_fetch(32'd264, 32'hefc18213);
        check_fetch(32'd268, 32'h800002b7);
        check_fetch(32'd272, 32'hfe528317);
        check_fetch(32'd276, 32'h00630037);
        check_fetch(32'd280, 32'h000003b7);
        check_fetch(32'd284, 32'h7ffff417);
        check_fetch(32'd288, 32'h80000497);
        check_fetch(32'd292, 32'h00000537);
        check_fetch(32'd296, 32'h12345597);
        check_fetch(32'd300, 32'h00758613);
        check_fetch(32'd304, 32'h00b086b3);
        check_fetch(32'd308, 32'h00000013);

        $display("PASS: IF stage 77-instruction test passed");
        $stop;
    end

    initial begin
        #2000;
        $fatal(1, "IF test timeout");
    end

endmodule

