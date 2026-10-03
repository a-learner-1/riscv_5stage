`timescale 1ns/1ps
module axi_lite_icache_stats_tb;
    reg clk=0,rst_n=0;
    reg [31:0] accesses=100,hits=80,misses=20,words=80,errors=0;
    reg [31:0] awaddr=0,wdata=0,araddr=0;
    reg [3:0] wstrb=15;
    reg awvalid=0,wvalid=0,bready=0,arvalid=0,rready=0;
    wire awready,wready,bvalid,arready,rvalid;
    wire [1:0] bresp,rresp;
    wire [31:0] rdata;
    reg test_pass=0;
    integer k;
    axi_lite_icache_stats dut(.clk(clk),.rst_n(rst_n),
        .access_count(accesses),.hit_count(hits),.miss_count(misses),.refill_word_count(words),.error_count(errors),
        .s_axi_awaddr(awaddr),.s_axi_awprot(3'd0),.s_axi_awvalid(awvalid),.s_axi_awready(awready),
        .s_axi_wdata(wdata),.s_axi_wstrb(wstrb),.s_axi_wvalid(wvalid),.s_axi_wready(wready),
        .s_axi_bresp(bresp),.s_axi_bvalid(bvalid),.s_axi_bready(bready),
        .s_axi_araddr(araddr),.s_axi_arprot(3'd0),.s_axi_arvalid(arvalid),.s_axi_arready(arready),
        .s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rvalid(rvalid),.s_axi_rready(rready));
    always #5 clk=~clk;
    task read_word(input [31:0] offset,input [31:0] expected,input [1:0] response);
        begin
            @(negedge clk);araddr=32'h30000000+offset;arvalid=1;rready=0;
            @(posedge clk);while(!arready) @(posedge clk);
            @(negedge clk);arvalid=0;
            repeat(5) begin
                @(negedge clk);
                if(!rvalid || rdata!==expected || rresp!==response) $fatal(1,"Cache stats response/backpressure offset=%h",offset);
                accesses=accesses+1;hits=hits+1;
            end
            rready=1;@(posedge clk);@(negedge clk);rready=0;
        end
    endtask
    task send_aw;
        begin @(negedge clk);awvalid=1;@(posedge clk);while(!awready) @(posedge clk);@(negedge clk);awvalid=0;end
    endtask
    task send_w;
        begin @(negedge clk);wvalid=1;@(posedge clk);while(!wready) @(posedge clk);@(negedge clk);wvalid=0;end
    endtask
    task check_write;
        begin
            wait(bvalid);
            repeat(5) begin @(negedge clk);if(!bvalid || bresp!==2 || awready || wready) $fatal(1,"Cache stats held write error");end
            bready=1;@(posedge clk);@(negedge clk);bready=0;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        read_word(8,0,0);
        accesses=100;hits=80;
        read_word(0,32'h49433241,0);
        read_word(4,32'h02400010,0);read_word(8,100,0);read_word(12,80,0);
        read_word(16,20,0);read_word(20,80,0);read_word(24,0,0);
        read_word(1,0,2);read_word(28,0,2);read_word(32'hfffffffc,0,2);read_word(256,0,2);
        send_aw;repeat(4) @(negedge clk);if(bvalid) $fatal(1,"Write responded without W");send_w;check_write;
        send_w;repeat(4) @(negedge clk);if(bvalid) $fatal(1,"Write responded without AW");send_aw;check_write;
        fork send_aw;send_w;join
        check_write;
        accesses=41;hits=33;misses=8;words=30;errors=1;
        read_word(0,32'h49433241,0);read_word(8,41,0);read_word(12,33,0);
        read_word(16,8,0);read_word(20,30,0);read_word(24,1,0);
        // Reset both a pending half-write and a held read response.
        send_aw;
        @(negedge clk);araddr=32'h30000000;arvalid=1;
        @(posedge clk);@(negedge clk);arvalid=0;rst_n=0;#1;
        if(bvalid||rvalid||awready||arready) $fatal(1,"Stats reset left a live transaction");
        repeat(3) @(negedge clk);rst_n=1;read_word(8,0,0);
        test_pass=1;$display("ICACHE STATS TESTS PASS: atomic snapshot, independent AW/W, read-only errors, backpressure and reset");$stop;
    end
    initial begin #100000;$fatal(1,"Cache statistics timeout");end
endmodule
