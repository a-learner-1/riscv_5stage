`timescale 1ns/1ps
module data_mem_tb;
    reg clk=0, re=0, we=0;
    reg [31:0] addr=0,wdata=0;
    wire [31:0] rdata;
    wire access_ok;
    data_mem dut(.clk(clk),.re(re),.we(we),.addr(addr),.wdata(wdata),
                 .rdata(rdata),.access_ok(access_ok));
    always #5 clk=~clk;
    task write_word;
        input [31:0] a,d;
        begin
            @(negedge clk); addr=a; wdata=d; we=1;
            @(posedge clk); #1;
            @(negedge clk); we=0;
        end
    endtask
    task read_word;
        input [31:0] a,d;
        input ok;
        begin
            addr=a; re=1; #1;
            if (rdata !== d || access_ok !== ok)
                $fatal(1,"RAM mismatch addr=%h got=%h expected=%h",a,rdata,d);
        end
    endtask
    initial begin
        write_word(0,32'h12345678);
        write_word(1020,32'h87654321);
        read_word(0,32'h12345678,1);
        read_word(1020,32'h87654321,1);
        // Bad addresses must neither alias a legal word nor modify RAM.
        write_word(2,32'hffffffff);
        write_word(1024,32'hffffffff);
        write_word(32'hfffffffc,32'hffffffff);
        read_word(2,0,0);
        read_word(1024,0,0);
        read_word(32'hfffffffc,0,0);
        read_word(0,32'h12345678,1);
        read_word(1020,32'h87654321,1);
        re=0; #1;
        if (rdata !== 0) $fatal(1,"Disabled read mismatch");
        $display("PASS: data RAM boundaries, read/write and no invalid-address aliasing");
        $stop;
    end
    initial begin #500; $fatal(1,"RAM test timeout"); end
endmodule
