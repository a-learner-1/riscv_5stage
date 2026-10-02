`timescale 1ns/1ps
// New timer only: word-address decode, actual half-word writes, rollover,
// compare level/rearm and shared reset. CPU/AXI regressions are not invoked.
module machine_timer_tb;
    reg clk=0,rst_n=0,write_enable=0;
    always #5 clk=~clk;
    reg [31:0] addr=0,write_data=0;
    wire [31:0] read_data;
    wire read_hit,write_hit,mtip;
    wire [63:0] mtime,mtimecmp;
    reg test_pass=0;
    reg [63:0] before_time;
    integer ticks;
    machine_timer dut( .clk(clk),.rst_n(rst_n),.addr(addr),
        .write_enable(write_enable),.write_data(write_data),
        .read_data(read_data),.read_hit(read_hit),.write_hit(write_hit),
        .mtime(mtime),.mtimecmp(mtimecmp),.mtip(mtip));
    task put;
        input [31:0] a,d;
        begin
            @(negedge clk);addr=a;write_data=d;write_enable=1;
            #1;if(!write_hit || !read_hit) $fatal(1,"Timer valid word not decoded addr=%h",a);
            @(posedge clk);#1;
            @(negedge clk);write_enable=0;
        end
    endtask
    task get;
        input [31:0] a,d;
        begin addr=a;#1;if(!read_hit || read_data!==d) $fatal(1,"Timer read addr=%h got=%h want=%h",a,read_data,d);end
    endtask
    initial begin
        repeat(3) @(negedge clk);
        if(mtime!==0 || mtimecmp!==64'hffffffffffffffff || mtip) $fatal(1,"Timer reset state");
        rst_n=1;
        repeat(5) @(negedge clk);
        if(mtime!==5) $fatal(1,"Timer does not increment once per clock");
        before_time=mtime;
        addr=32'h20000041;write_enable=1;write_data=0;
        #1;if(read_hit || write_hit) $fatal(1,"Timer accepted misaligned word");
        @(posedge clk);#1;
        if(mtime!==before_time+1 || mtimecmp!==64'hffffffffffffffff) $fatal(1,"Invalid address changed timer");
        @(negedge clk);write_enable=0;addr=32'h20000050;
        #1;if(read_hit || write_hit) $fatal(1,"Timer accepted unmapped word");

        // Time writes replace that edge's increment and preserve the other half.
        put(32'h20000044,32'h12345678);
        if(mtime[63:32]!==32'h12345678) $fatal(1,"Timer high write");
        put(32'h20000040,32'hfffffffe);
        if(mtime!==64'h12345678fffffffe) $fatal(1,"Timer low write/half preservation");
        @(posedge clk);#1;if(mtime!==64'h12345678ffffffff) $fatal(1,"Timer carry first edge");
        @(posedge clk);#1;if(mtime!==64'h1234567900000000) $fatal(1,"Timer rollover lost carry");
        get(32'h20000044,32'h12345679);get(32'h20000040,0);

        put(32'h20000044,32'hffffffff);put(32'h20000040,32'hffffffff);
        if(mtime!==64'hffffffffffffffff || !mtip)$fatal(1,"Timer all-ones write/compare equality");
        @(posedge clk);#1;if(mtime!==0 || mtip)$fatal(1,"Timer full 64-bit rollover");

        put(32'h20000044,0);put(32'h20000040,0);
        // Safe three-write comparator update: low=all ones, high, final low.
        put(32'h20000048,32'hffffffff);
        put(32'h2000004c,0);
        if(mtip) $fatal(1,"Comparator safe intermediate update asserted MTIP");
        before_time=mtime;
        put(32'h20000048,before_time[31:0]+10);
        if(mtip) $fatal(1,"Comparator future deadline asserted early");
        ticks=0;
        while(!mtip) begin @(negedge clk);ticks=ticks+1;if(ticks>12) $fatal(1,"Timer deadline never asserted");end
        if(mtime<mtimecmp || mtimecmp[63:32]!==0) $fatal(1,"MTIP relation/compare half preservation");
        repeat(4) @(negedge clk);
        if(!mtip) $fatal(1,"MTIP is not level-sensitive");
        put(32'h20000048,32'hffffffff);put(32'h2000004c,32'hffffffff);
        if(mtip) $fatal(1,"Rearm did not clear MTIP");
        get(32'h20000048,32'hffffffff);get(32'h2000004c,32'hffffffff);
        put(32'h2000004c,0);put(32'h20000048,0);
        if(!mtip) $fatal(1,"Expired comparator did not assert immediately");
        // Time software rewrite can move time below the comparator too.
        put(32'h20000048,1000);put(32'h20000040,0);
        if(mtip || mtime!==0) $fatal(1,"Time rewrite failed to clear pending level");
        @(negedge clk);rst_n=0;write_enable=1;addr=32'h20000048;write_data=0;
        #1;if(mtime!==0 || mtimecmp!==64'hffffffffffffffff || mtip) $fatal(1,"Reset did not override simultaneous write");
        repeat(3) @(negedge clk);write_enable=0;rst_n=1;
        @(negedge clk);if(mtime!==1 || mtip) $fatal(1,"Timer reset recovery");
        test_pass=1;$display("PASS: machine timer exact word decode, half writes, rollover, safe compare update, level MTIP, rearm and reset");$stop;
    end
    initial begin #10000;$fatal(1,"Machine timer timeout");end
endmodule
