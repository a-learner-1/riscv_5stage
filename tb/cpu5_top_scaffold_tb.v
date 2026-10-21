`timescale 1ns/1ps
module cpu5_top_scaffold_tb;
    wire [1:0] done;
    reg test_pass=0;
    cpu5_top_scaffold_case #(.FAULT(0),.ID_BRANCH(0)) normal(done[0]);
    cpu5_top_scaffold_case #(.FAULT(1),.ID_BRANCH(1)) fault(done[1]);
    initial begin wait(&done);test_pass=1;$display("CPU5 TOP SCAFFOLD PASS: two elaborations, metadata only, zero architecture effects");$stop;end
    initial begin #100000;$fatal(1,"top scaffold timeout done=%b",done);end
endmodule

module cpu5_top_scaffold_case #(parameter FAULT=0,ID_BRANCH=0)(output reg done=0);
    reg clk=0,rst_n=0,pending=0;
    always #5 clk=~clk;
    wire qv,qr,sv,sr;
    wire [31:0] qa;
    reg [31:0] addr=0;
    reg [1:0] delay=0;
    integer requests=0,responses=0,releases=0,cycles=0;
    wire rv,we,dqv,dqw,dsr,df,tf,ifault;
    wire [31:0] wpc,wdata,dqa,dqd,tpc,tc,tv,ifpc;
    wire [4:0] wrd;
    wire [1:0] dz;
    wire [3:0] dst;
    wire [63:0] cc,ic;
    wire [9:0] perf;
    wire [7:0] gout,goe;
    wire tx;
    assign qr=rst_n && requests<(FAULT?5:12) && (!pending||(sv&&sr));
    assign sv=pending && delay==0;
    function [31:0] word(input [31:0] a);word=32'h20000013^(a<<8);endfunction
    cpu5_top #(.PROGRAM_FILE("programs/data_handshake_blank.hex"),.IMEM_WORDS(256),
        .ENABLE_BRANCH_PRED(!FAULT),.BRANCH_RESOLVE_IN_ID(ID_BRANCH)) dut(
        .clk(clk),.rst_n(rst_n),.pc_x(),.instr_x(),.valid_x(),
        .wb_pc(wpc),.wb_rd(wrd),.wb_data(wdata),.wb_we(we),.retire_valid(rv),
        .cycle_count(cc),.instret_count(ic),.uart_tx(tx),.uart_rx(1'b1),
        .gpio_in(8'hff),.gpio_out(gout),.gpio_oe(goe),
        .dmem_req_valid(dqv),.dmem_req_ready(1'b1),.dmem_req_write(dqw),.dmem_req_addr(dqa),
        .dmem_req_size(dz),.dmem_req_wdata(dqd),.dmem_req_wstrb(dst),
        .dmem_rsp_valid(1'b1),.dmem_rsp_ready(dsr),.dmem_rsp_rdata(32'hdeadbeef),
        .dmem_rsp_error(1'b1),.dmem_fault(df),
        .imem_req_valid(qv),.imem_req_ready(qr),.imem_req_addr(qa),
        .imem_rsp_valid(sv),.imem_rsp_ready(sr),.imem_rsp_rdata(word(addr)),
        .imem_rsp_error(FAULT&&addr==16),.imem_fault(ifault),.imem_fault_pc(ifpc),
        .trap_valid(tf),.trap_pc(tpc),.trap_cause(tc),.trap_tval(tv),
        .bp_lookup_count(),.bp_hit_count(),.bp_taken_count(),.bp_resolved_count(),
        .bp_mispredict_count(),.bp_direction_error_count(),.bp_target_error_count(),
        .irq_external(1'b1),.perf_cycle_events(perf));
    initial begin repeat(4)@(negedge clk);rst_n=1;end
    always @(posedge clk) if(rst_n&&!done)begin
        cycles=cycles+1;
        if({rv,we,wpc,wrd,wdata,cc,ic,perf,dqv,dqw,dqa,dz,dqd,dst,dsr,df,tf,tpc,tc,tv,gout,goe}!==0 || tx!==1)
            $fatal(1,"Unimplemented architecture output activated");
        if(sv&&sr)begin pending<=0;responses=responses+1;end
        if(pending&&delay!=0)delay<=delay-1'b1;
        if(qv&&qr)begin
            if(qa!==requests*4)$fatal(1,"fetch PC mismatch got=%h request=%0d",qa,requests);
            addr<=qa;pending<=1;delay<=requests%3;requests=requests+1;
        end
        if(dut.debug_wb_valid)begin
            if(dut.debug_wb_seq!==releases || dut.debug_wb_pc!==releases*4 ||
               dut.debug_wb_instr!==word(releases*4))$fatal(1,"top metadata sequence mismatch");
            releases=releases+1;
        end
        if(!FAULT&&releases==12)begin
            if(requests!=12||responses!=12||ifault)$fatal(1,"normal ledger");
            done=1;$display("CPU5 TOP NORMAL PASS req=%0d rsp=%0d debug_release=%0d",requests,responses,releases);
        end
        if(FAULT&&dut.u_pipeline.exmem_valid_q&&dut.u_pipeline.exmem_q.exception_valid)begin
            if(!ifault || ifpc!=16 || dut.u_pipeline.exmem_q.pc!=16 ||
               dut.u_pipeline.exmem_q.seq!=4 || dut.u_pipeline.exmem_q.exception_cause!=1 ||
               releases!=4 || requests!=5 || responses!=5)$fatal(1,"fault packet age/ledger");
            if(cycles>35)begin done=1;$display("CPU5 TOP FAULT PASS: old packets drained, fault seq4 held MEM, no Trap/retirement");end
        end
    end
endmodule
