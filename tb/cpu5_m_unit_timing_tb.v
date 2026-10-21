`timescale 1ns/1ps
// Directed arithmetic/edge oracle independent from CoreMark operation coverage.
module cpu5_m_unit_timing_tb;
    reg clk=0,rst_n=0,start=0,test_pass=0;
    reg [2:0] op=0;
    reg [31:0] lhs=0,rhs=0;
    wire busy,done;
    wire [31:0] result;
    string output_dir;
    integer f,cases=0,latency;
    always #5 clk=~clk;
    rv32m_unit dut(clk,rst_n,start,op,lhs,rhs,busy,done,result);

    task check(input [2:0] which,input [31:0] a,b,expected,input integer expected_latency);
        begin
            @(negedge clk);
            if(busy)$fatal(1,"previous unit owner still busy");
            op=which;lhs=a;rhs=b;start=1;
            @(posedge clk);#1;latency=0;
            if((done && busy) || (!done && !busy))$fatal(1,"command did not establish owner");
            @(negedge clk);start=0;op=~which;lhs=~a;rhs=~b;
            while(!done && latency<40)begin @(posedge clk);#1;latency=latency+1;end
            if(!done || busy || latency!=expected_latency || result!==expected)
                $fatal(1,"directed unit op=%0d got=%h expected=%h latency=%0d/%0d",which,result,expected,latency,expected_latency);
            $fwrite(f,"%0d,%0d,%08h,%08h,%08h,%0d\n",cases,which,a,b,result,latency);
            // New start must disambiguate sticky done; all input bits changed above.
            repeat(3)begin @(posedge clk);#1;if(!done || busy || result!==expected)$fatal(1,"sticky completion changed");end
            cases=cases+1;
        end
    endtask
    initial begin
        if(!$value$plusargs("M_OUTPUT=%s",output_dir))$fatal(1,"M_OUTPUT required");
        f=$fopen({output_dir,"/unit_directed.csv"},"w");
        if(!f)$fatal(1,"cannot open directed output");
        $fwrite(f,"case,op,lhs,rhs,result,start_to_unit_done_edges\n");
        repeat(3)@(negedge clk);rst_n=1;
        check(0,32'hffffffff,3,32'hfffffffd,2);
        check(1,32'hffffffff,3,32'hffffffff,2);
        check(2,32'hffffffff,32'hffffffff,32'hffffffff,2);
        check(3,32'hffffffff,32'hffffffff,32'hfffffffe,2);
        check(4,32'hfffffff9,3,32'hfffffffe,32);
        check(5,32'hfffffff9,3,32'd1431655763,32);
        check(6,32'hfffffff9,3,32'hffffffff,32);
        check(7,32'hfffffff9,3,0,32);
        check(4,123,0,32'hffffffff,0);
        check(5,123,0,32'hffffffff,0);
        check(6,123,0,123,0);
        check(7,123,0,123,0);
        check(4,32'h80000000,32'hffffffff,32'h80000000,0);
        check(6,32'h80000000,32'hffffffff,0,0);
        $fclose(f);test_pass=1;
        $display("CPU5 M UNIT TIMING PASS cases=%0d; all 8 ops, DIV0/overflow fast paths, sticky done and changed inputs",cases);
        $stop;
    end
    initial begin #100000;$fatal(1,"unit directed timeout");end
endmodule
