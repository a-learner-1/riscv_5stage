`timescale 1ns/1ps
// Real IF-adapter -> ID/EX -> MEM retirement -> physical WB. The last two
// instances run the identical program without forwarding for an A/B control.
module cpu5_forward_top_tb;
    wire [49:0] done;
    reg test_pass=0;
    cpu5_alu_top_case #(.CASE_ID(0),.KIND(0),.WAIT(0),.FORWARD(1),
        .TRACE_DIR("build/cpu5_s3_forward")) fast(done[0]);
    cpu5_alu_top_case #(.CASE_ID(1),.KIND(0),.WAIT(1),.FORWARD(1),
        .TRACE_DIR("build/cpu5_s3_forward")) waited(done[1]);
    cpu5_alu_top_case #(.CASE_ID(2),.KIND(1),.WAIT(1),.FORWARD(1),
        .TRACE_DIR("build/cpu5_s3_forward")) fetch_error(done[2]);
    genvar n;
    generate for(n=0;n<45;n=n+1)begin:g_unsupported
        cpu5_alu_top_case #(.CASE_ID(n+3),.KIND(2),.INDEX(n),.WAIT(n%2),.FORWARD(1),
            .TRACE_DIR("build/cpu5_s3_forward")) u(done[n+3]);
    end endgenerate
    cpu5_alu_top_case #(.CASE_ID(48),.KIND(0),.WAIT(0),.FORWARD(0),
        .TRACE_DIR("build/cpu5_s3_forward")) baseline_fast(done[48]);
    cpu5_alu_top_case #(.CASE_ID(49),.KIND(0),.WAIT(1),.FORWARD(0),
        .TRACE_DIR("build/cpu5_s3_forward")) baseline_waited(done[49]);
    initial begin
        wait(&done);test_pass=1;
        $display("CPU5 FORWARD TOP PASS 50 cases: 1193 forwarding + 1100 baseline retirements");
        $stop;
    end
    initial begin #2000000;$fatal(1,"CPU5 FORWARD TOP timeout done=%h",done);end
endmodule
