`timescale 1ns/1ps
module data_mem_tb;
    reg clk = 1'b0;
    reg re = 1'b0;
    reg we = 1'b0;
    reg [31:0] addr = 32'd0;
    reg [1:0] size = 2'd2;
    reg [31:0] wdata = 32'd0;
    reg [3:0] wstrb = 4'd0;
    wire [31:0] rdata;
    wire access_ok;

    data_mem dut (
        .clk(clk), .re(re), .we(we), .addr(addr), .size(size),
        .wdata(wdata), .wstrb(wstrb), .rdata(rdata),
        .access_ok(access_ok)
    );

    always #5 clk = ~clk;

    task write_access;
        input [31:0] a;
        input [1:0] s;
        input [31:0] d;
        input [3:0] strobe;
        input expected_ok;
        begin
            @(negedge clk);
            addr = a; size = s; wdata = d; wstrb = strobe; we = 1'b1;
            #1;
            if (access_ok !== expected_ok)
                $fatal(1, "write access_ok mismatch addr=%h size=%0d", a, s);
            @(posedge clk); #1;
            @(negedge clk); we = 1'b0; wstrb = 4'b0000;
        end
    endtask

    task read_word;
        input [31:0] a;
        input [1:0] s;
        input [31:0] expected;
        input expected_ok;
        begin
            addr = a; size = s; re = 1'b1; #1;
            if (rdata !== expected || access_ok !== expected_ok)
                $fatal(1, "read mismatch addr=%h size=%0d got=%h expected=%h ok=%b",
                       a, s, rdata, expected, access_ok);
            re = 1'b0;
        end
    endtask

    initial begin
        write_access(32'd0, 2'd2, 32'h12345678, 4'b1111, 1'b1);
        write_access(32'd1, 2'd0, 32'h0000aa00, 4'b0010, 1'b1);
        write_access(32'd2, 2'd1, 32'hbeef0000, 4'b1100, 1'b1);
        read_word(32'd0, 2'd2, 32'hbeefaa78, 1'b1);

        write_access(32'd1020, 2'd2, 32'h11223344, 4'b1111, 1'b1);
        write_access(32'd1023, 2'd0, 32'hcc000000, 4'b1000, 1'b1);
        read_word(32'd1023, 2'd0, 32'hcc223344, 1'b1);
        write_access(32'd1022, 2'd1, 32'h80010000, 4'b1100, 1'b1);
        read_word(32'd1022, 2'd1, 32'h80013344, 1'b1);

        write_access(32'd1, 2'd1, 32'hffffffff, 4'b0011, 1'b0);
        write_access(32'd2, 2'd2, 32'hffffffff, 4'b1111, 1'b0);
        write_access(32'd1024, 2'd0, 32'hffffffff, 4'b0001, 1'b0);
        read_word(32'd1, 2'd1, 32'd0, 1'b0);
        read_word(32'd2, 2'd2, 32'd0, 1'b0);
        read_word(32'd1024, 2'd0, 32'd0, 1'b0);
        read_word(32'd0, 2'd2, 32'hbeefaa78, 1'b1);
        read_word(32'd1020, 2'd2, 32'h80013344, 1'b1);

        re = 1'b0; #1;
        if (rdata !== 32'd0) $fatal(1, "disabled read must return zero");
        $display("PASS: byte-enable RAM, byte/half/word alignment and 1 KiB boundaries");
        $stop;
    end

    initial begin #800; $fatal(1, "data_mem test timeout"); end
endmodule
