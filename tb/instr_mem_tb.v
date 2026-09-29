`timescale 1ns/1ps
module instr_mem_tb;
    reg clk = 1'b0;
    reg en = 1'b0;
    reg [31:0] addr;
    wire [31:0] instr;
    wire access_ok;
    integer i;

    reg [31:0] expected [0:13];

    instr_mem #(
        .WORDS(16),
        .INIT_FILE("programs/program_load_test.hex")
    ) dut (
        .clk(clk),
        .en(en),
        .addr(addr),
        .instr(instr),
        .access_ok(access_ok)
    );

    always #5 clk = ~clk;

    task check_fetch;
        input [31:0] a;
        input [31:0] expected_instr;
        input expected_ok;
        begin
            @(negedge clk);
            addr = a;
            en = 1'b1;
            @(posedge clk);
            #1;
            if (instr !== expected_instr || access_ok !== expected_ok)
                $fatal(1, "fetch addr=%h instr=%h expected=%h ok=%b",
                       a, instr, expected_instr, access_ok);
            @(negedge clk);
            en = 1'b0;
        end
    endtask

    initial begin
        expected[0]  = 32'h00500093;
        expected[1]  = 32'h00308113;
        expected[2]  = 32'h002081b3;
        expected[3]  = 32'h00302023;
        expected[4]  = 32'h00002203;
        expected[5]  = 32'h00120293;
        expected[6]  = 32'h00528463;
        expected[7]  = 32'h06300313;
        expected[8]  = 32'h008003ef;
        expected[9]  = 32'h06300413;
        expected[10] = 32'h005000a3;
        expected[11] = 32'h00104483;
        expected[12] = 32'h00148513;
        expected[13] = 32'h00000013;

        for (i = 0; i < 14; i = i + 1)
            check_fetch(i * 4, expected[i], 1'b1);

        // Unused in-range words were initialized to NOP before readmemh.
        check_fetch(32'd56, 32'h00000013, 1'b1);
        check_fetch(32'd60, 32'h00000013, 1'b1);

        // Misaligned and out-of-range fetches return NOP and access_ok=0.
        check_fetch(32'd2,  32'h00000013, 1'b0);
        check_fetch(32'd64, 32'h00000013, 1'b0);
        check_fetch(32'hffff_fffc, 32'h00000013, 1'b0);

        $display("PASS: external instruction image, NOP fill, alignment and range checks");
        $stop;
    end
endmodule


