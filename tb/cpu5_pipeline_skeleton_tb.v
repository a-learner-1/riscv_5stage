`timescale 1ns/1ps
// Score identities as a queue; stage handshakes are not reproduced in oracle.
module cpu5_pipeline_skeleton_tb;
    reg clk=0,rst_n=0,in_valid=0,id_enable=1,ex_enable=1,mem_enable=1,wb_ready=1,flush_valid=0;
    always #5 clk=~clk;
    reg [31:0] pc=0,instr=0,pred=0,tval=0;
    reg pt=0,ph=0,err=0;
    reg [63:0] seq=0,cut=0;
    reg [7:0] epoch=0;
    wire ready,wv,xv;
    wire [31:0] wp,wi,xp,xi;
    wire [63:0] ws;
    wire [7:0] xe;
    reg test_pass=0;
    string trace_dir;
    integer i,j,k,head=0,tail=0,accepted=0,delivered=0,killed=0,checks=0,fd;
    integer wb_hold_checks=0,old_wb_during_mem_wait=0,old_wb_during_flush=0;
    reg [63:0] queue[0:255];
    reg held=0;
    reg [127:0] held_wb;
    localparam [63:0] BASE=64'h0000000100000100;
    cpu5_pipeline_skeleton dut(.clk(clk),.rst_n(rst_n),.in_valid(in_valid),.in_ready(ready),
        .in_pc(pc),.in_instr(instr),.in_pred_next_pc(pred),.in_pred_taken(pt),.in_pred_hit(ph),
        .in_fetch_error(err),.in_fetch_tval(tval),.in_seq(seq),.in_epoch(epoch),
        .id_enable(id_enable),.ex_enable(ex_enable),.mem_enable(mem_enable),.wb_ready(wb_ready),
        .flush_valid(flush_valid),.flush_cut_seq(cut),.debug_wb_valid(wv),
        .debug_wb_pc(wp),.debug_wb_instr(wi),.debug_wb_seq(ws),.debug_ex_epoch(xe),
        .debug_ex_valid(xv),.debug_ex_pc(xp),.debug_ex_instr(xi));
    function [31:0] p(input [63:0] s);p=32'h1000+s[15:0]*4;endfunction
    function [31:0] ins(input [63:0] s);ins=32'h12340013^(s[15:0]<<8);endfunction
    task put(input [63:0] s,input bad);
        begin
            @(negedge clk);in_valid=1;seq=s;pc=p(s);instr=ins(s);pred=p(s)+32'h40;
            pt=s[0];ph=s[1];epoch=s[7:0]^8'h5a;err=bad;tval=bad?p(s):0;
            begin:wait_accept
                forever begin @(posedge clk);if(ready)disable wait_accept;end
            end
        end
    endtask
    task idle;begin @(negedge clk);in_valid=0;end endtask
    task drain;begin wait(head==tail);repeat(3)@(negedge clk);end endtask
    always @(posedge clk) if(rst_n)begin
        if(flush_valid)begin
            $fwrite(fd,"flush,%0d,%016h,%08h,%08h\n",$time,cut,0,0);
            k=0;
            for(j=head;j<tail;j=j+1)begin
                if(queue[j]<cut)begin queue[k]=queue[j];k=k+1;end
                else killed=killed+1;
            end
            head=0;tail=k;
        end
        if(held && !flush_valid)begin
            if(!wv || {ws,wp,wi}!==held_wb)$fatal(1,"WB packet changed under hold");
            wb_hold_checks=wb_hold_checks+1;
        end
        held=wv&&!wb_ready;held_wb={ws,wp,wi};
        if(wv&&wb_ready)begin
            if(head==tail || ws!==queue[head] || wp!==p(ws) || wi!==ins(ws))
                $fatal(1,"queue identity lost/replayed wb=%h expected=%h",ws,queue[head]);
            head=head+1;delivered=delivered+1;
            if(!mem_enable)old_wb_during_mem_wait=old_wb_during_mem_wait+1;
            if(flush_valid)old_wb_during_flush=old_wb_during_flush+1;
            $fwrite(fd,"release,%0d,%016h,%08h,%08h\n",$time,ws,wp,wi);
        end
        if(in_valid&&ready)begin
            queue[tail]=seq;tail=tail+1;accepted=accepted+1;
            $fwrite(fd,"accept,%0d,%016h,%08h,%08h\n",$time,seq,pc,instr);
        end
        if(dut.idex_valid_q && (!flush_valid||dut.idex_q.seq<cut))begin
            if(dut.idex_q.pc!==p(dut.idex_q.seq) || dut.idex_q.instr!==ins(dut.idex_q.seq) ||
              dut.idex_q.pred_next_pc!==p(dut.idex_q.seq)+32'h40 ||
              dut.idex_q.pred_taken!==dut.idex_q.seq[0] || dut.idex_q.pred_hit!==dut.idex_q.seq[1] ||
              dut.idex_q.epoch!==(dut.idex_q.seq[7:0]^8'h5a))$fatal(1,"EX metadata mismatch");
            checks=checks+1;
        end
        if(dut.exmem_valid_q && (!flush_valid||dut.exmem_q.seq<cut))begin
            if(dut.exmem_q.pc!==p(dut.exmem_q.seq) || dut.exmem_q.instr!==ins(dut.exmem_q.seq) ||
              dut.exmem_q.pred_next_pc!==p(dut.exmem_q.seq)+32'h40 ||
              dut.exmem_q.pred_taken!==dut.exmem_q.seq[0] || dut.exmem_q.pred_hit!==dut.exmem_q.seq[1] ||
              dut.exmem_q.epoch!==(dut.exmem_q.seq[7:0]^8'h5a))$fatal(1,"MEM metadata mismatch");
            checks=checks+1;
        end
    end
    initial begin
        if(!$value$plusargs("SCAFFOLD_TRACE_DIR=%s",trace_dir))trace_dir="build/cpu5_s1_scaffold";
        fd=$fopen({trace_dir,"/pipeline_trace.csv"},"w");
        if(!fd)$fatal(1,"cannot open scaffold trace");
        $fwrite(fd,"event,time_ns,seq,pc,instr\n");
        repeat(4)@(negedge clk);rst_n=1;
        // Cross the 32-bit boundary. A truncated age comparison would kill
        // both older packets because their low words are greater than zero.
        wb_ready=0;
        put(64'h00000000fffffffe,0);put(64'h00000000ffffffff,0);put(64'h0000000100000000,0);idle;
        cut=64'h0000000100000000;flush_valid=1;wb_ready=1;
        @(negedge clk);flush_valid=0;drain;
        if(delivered!=2 || killed!=1)$fatal(1,"64-bit age boundary gate");
        // Continuous tokens with prolonged WB backpressure, then drain once.
        fork
            begin for(i=0;i<12;i=i+1)put(BASE+i,0);idle;end
            begin repeat(4)@(negedge clk);wb_ready=0;repeat(7)@(negedge clk);wb_ready=1;end
        join
        drain;
        if(delivered!=14 || killed!=1 || wb_hold_checks<4)$fatal(1,"normal/hold gate");
        // With MEM stopped, an already older WB token is consumed exactly once.
        put(BASE+20,0);put(BASE+21,0);put(BASE+22,0);idle;
        mem_enable=0;repeat(4)@(negedge clk);
        if(!old_wb_during_mem_wait)$fatal(1,"WB did not drain independently");
        mem_enable=1;drain;
        // Inclusive first-killed cut: keep older WB, kill younger MEM/EX.
        wb_ready=0;
        put(BASE+30,0);put(BASE+31,0);put(BASE+32,0);idle;
        if(!dut.memwb_valid_q || dut.memwb_q.seq!=BASE+30)$fatal(1,"flush setup");
        cut=BASE+31;flush_valid=1;wb_ready=1;
        // An upstream-held younger packet is canceled by the same flush,
        // not consumed by ready. Its source must withdraw it after the edge.
        in_valid=1;seq=BASE+33;pc=p(seq);instr=ins(seq);pred=p(seq)+32'h40;
        pt=seq[0];ph=seq[1];epoch=seq[7:0]^8'h5a;err=0;tval=0;
        #1;if(ready)$fatal(1,"killed ingress was accepted");
        @(negedge clk);flush_valid=0;in_valid=0;
        drain;
        if(killed!=3 || old_wb_during_flush!=2)$fatal(1,"age flush lost older WB");
        // Epochs intentionally change on every token. They never kill EX/MEM.
        put(BASE+40,0);put(BASE+41,0);idle;drain;
        // Fetch error packet waits at MEM. It cannot become a WB token.
        put(BASE+50,1);put(BASE+51,0);idle;
        wait(dut.exmem_valid_q && dut.exmem_q.exception_valid);
        repeat(4)@(negedge clk);
        if(dut.exmem_q.exception_cause!=1 || dut.exmem_q.exception_tval!=p(BASE+50) ||
           dut.memwb_valid_q)$fatal(1,"fault escaped MEM or descriptor corrupted");
        cut=BASE+50;flush_valid=1;@(negedge clk);flush_valid=0;drain;
        put(BASE+60,0);idle;drain;
        if(accepted!=delivered+killed || head!=tail)$fatal(1,"final ledger");
        // Reset while all three stages contain data. No stale packet survives.
        wb_ready=0;put(BASE+70,0);put(BASE+71,0);put(BASE+72,0);idle;
        rst_n=0;#1;
        if(dut.idex_valid_q||dut.exmem_valid_q||dut.memwb_valid_q||wv||ready)$fatal(1,"reset retained token");
        $fwrite(fd,"reset,%0d,%016h,%08h,%08h\n",$time,0,0,0);
        $fclose(fd);test_pass=1;
        $display("CPU5 PIPELINE SKELETON PASS accepted=%0d released=%0d age_killed=%0d checks=%0d WBholds=%0d (last 3 tokens reset-discarded)",accepted,delivered,killed,checks,wb_hold_checks);
        $stop;
    end
    initial begin #100000;$fatal(1,"pipeline skeleton timeout accepted=%0d delivered=%0d head=%0d tail=%0d",accepted,delivered,head,tail);end
endmodule
