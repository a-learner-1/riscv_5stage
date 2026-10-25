`timescale 1ns/1ps
// The expected queue contains hand-built architectural instructions, not a
// Boolean reimplementation of the DUT decoder. Every accepted token has one
// architectural terminal event; every retirement has exactly one later WB.
module cpu5_fence_decode_case #(
    parameter integer ID_MODE=0,FWD=0,CASE_ID=0,FENCE_ENABLE=1
)(output reg done=0);
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,in_valid=0,in_fetch_error=0,in_pred_taken=0,in_pred_hit=0;
    reg [31:0] in_pc=0,in_instr=0,in_pred_next_pc=0,in_fetch_tval=0;
    reg [63:0] in_seq=0,flush_cut_seq=0;reg [7:0] in_epoch=0;
    reg id_enable=1,ex_enable=1,mem_enable=1,wb_ready=1,flush_valid=0;
    wire irq_external=0,irq_software=0,irq_timer=0;
    wire in_ready,ex_valid,wb_we,retire_valid,retire_writes_rd;
    wire [31:0] ex_pc,ex_instr,wb_pc,wb_data,retire_pc,retire_instr,retire_value,arch_next_pc_q;
    wire [4:0] wb_rd,retire_rd;wire [63:0] retire_seq,cycle_count,instret_count;
    wire halted,halt_fetch_error,id_raw_wait,retire_fire,wb_fire,flush_ready,flush_fire;
    wire [31:0] halt_pc,halt_instr,halt_cause,halt_tval;wire [63:0] halt_seq;
    wire redirect_valid,redirect_kill_ifid;wire [31:0] redirect_pc;wire [63:0] redirect_seq;
    wire bp_commit_valid,bp_commit_taken,bp_commit_is_branch,bp_commit_is_jal;
    wire [63:0] bp_commit_seq;wire [31:0] bp_commit_pc,bp_commit_target;
    wire [31:0] bp_resolved_count,bp_mispredict_count,bp_direction_error_count,bp_target_error_count;
    wire trap_fire,trap_valid;wire [31:0] trap_pc,trap_cause,trap_tval;wire [63:0] trap_seq;
    wire dmem_req_valid,dmem_req_write,dmem_rsp_ready,dmem_fault;
    wire dmem_req_ready=1,dmem_rsp_valid=0,dmem_rsp_error=0;wire [31:0] dmem_rsp_rdata=0;
    wire [31:0] dmem_req_addr,dmem_req_wdata;wire [1:0] dmem_req_size;wire [3:0] dmem_req_wstrb;
    cpu5_alu_pipeline #(.ENABLE_FENCE(FENCE_ENABLE),.ENABLE_FORWARDING(FWD),
        .ENABLE_CONTROL_FLOW(1),.BRANCH_RESOLVE_IN_ID(ID_MODE),.ENABLE_BRANCH_PRED(1),
        .ENABLE_SYNC_TRAPS(1),.ENABLE_RAM(0)) dut(.perf_cycle_events(),.*);

    // kind: 0=FENCE, 1=ADDI, 2=precise synchronous exception.
    reg [1:0] ekind[0:4399];reg [63:0] eseq[0:4399];
    reg [31:0] epc[0:4399],eins[0:4399],eval[0:4399],ecause[0:4399],etval[0:4399];
    reg [4:0] erd[0:4399];integer wb_index[0:4399];
    reg [31:0] model_gpr[0:31];reg [31:0] model_known=1;
    integer offered=0,accepted=0,committed=0,retired=0,wbs=0,traps=0;
    integer fences=0,matrix_fences=0,producer_alias_edges=0,unknown_operand_edges=0;
    integer cycles=0,timeout=0,i,j,ri,wi,ti,trace_fd,summary_fd;
    reg last_accept=0;reg [63:0] last_accept_seq=0;
    reg pre_retire,pre_trap,pre_wb;reg [31:0] arch_expected=0;
    function [31:0] fenceword(input integer fields,input integer a,input integer d,input integer f3);
        begin fenceword=(fields<<20)|(a<<15)|(f3<<12)|(d<<7)|32'h0f;end
    endfunction
    function [31:0] addi(input integer d,input integer v);
        begin addi=(v<<20)|(d<<7)|32'h13;end
    endfunction
    task tick;begin @(posedge clk);#2;end endtask
    task send(input [31:0] word,input integer kind,input integer dest,input [31:0] value,
              input [31:0] cause,input [31:0] tval,input integer fetch_error);
        begin
            @(negedge clk);
            ekind[offered]=kind;eseq[offered]=64'h00000001fffff000+offered;
            epc[offered]=32'h200+offered*4;eins[offered]=word;erd[offered]=dest;
            eval[offered]=value;ecause[offered]=cause;etval[offered]=tval;
            in_valid=1;in_pc=epc[offered];in_instr=word;in_seq=eseq[offered];
            in_epoch=offered;in_pred_next_pc=in_pc+4;in_fetch_error=fetch_error;in_fetch_tval=tval;
            offered=offered+1;timeout=0;tick;
            while(!(last_accept&&last_accept_seq==in_seq))begin
                tick;timeout=timeout+1;
                if(timeout>100)$fatal(1,"FENCE decode oracle progress/admission case=%0d accepted=%0d offered=%0d word=%h",CASE_ID,accepted,offered,word);
            end
            in_valid=0;
        end
    endtask
    task drain;
        begin timeout=0;
            while(committed<offered||wbs<retired)begin
                tick;timeout=timeout+1;
                if(timeout>100)$fatal(1,"FENCE decode oracle progress/terminal case=%0d offered=%0d committed=%0d retired=%0d wb=%0d",CASE_ID,offered,committed,retired,wbs);
            end
            repeat(4)tick;
        end
    endtask
    // Vary stage admission and WB capacity while preserving all offers.
    always @(negedge clk)if(rst_n&&!done)begin
        id_enable=(cycles%13!=5);ex_enable=(cycles%17!=8);
        mem_enable=(cycles%19!=11);wb_ready=(cycles%7!=3&&cycles%7!=4);
    end
    always @(posedge clk)begin
        last_accept=0;
        if(rst_n&&!done)begin
            cycles=cycles+1;if(cycles>50000)$fatal(1,"FENCE decode oracle global timeout case=%0d",CASE_ID);
            if(halted||dmem_req_valid||dmem_rsp_ready||dmem_fault||dut.csr_commit_fire||dut.mret_fire)
                $fatal(1,"FENCE decode oracle unexpected side effect case=%0d",CASE_ID);
            pre_retire=retire_fire;pre_trap=trap_fire;pre_wb=wb_fire;ri=committed;wi=wbs;ti=committed;
            if(in_valid&&accepted<offered&&ekind[accepted]==0)begin
                if(id_raw_wait)$fatal(1,"FENCE decode oracle reserved operands created RAW dependency case=%0d",CASE_ID);
                if(!model_known[in_instr[19:15]])unknown_operand_edges=unknown_operand_edges+1;
                if((dut.idex_valid_q&&dut.idex_q.writes_rd&&dut.idex_q.rd==in_instr[19:15])||
                   (dut.exmem_valid_q&&dut.exmem_q.writes_rd&&dut.exmem_q.rd==in_instr[19:15])||
                   (dut.memwb_valid_q&&dut.memwb_q.writes_rd&&dut.memwb_q.rd==in_instr[19:15]))
                    producer_alias_edges=producer_alias_edges+1;
            end
            if(in_valid&&in_ready)begin
                if(accepted>=offered||in_seq!==eseq[accepted]||in_pc!==epc[accepted]||in_instr!==eins[accepted])
                    $fatal(1,"FENCE decode oracle accepted-token ownership case=%0d",CASE_ID);
                accepted=accepted+1;last_accept=1;last_accept_seq=in_seq;
            end
            if(pre_wb)begin
                if(wi>=retired)$fatal(1,"FENCE decode oracle WB without prior retirement case=%0d",CASE_ID);
                j=wb_index[wi];
                if(dut.memwb_q.seq!==eseq[j]||wb_pc!==epc[j]||wb_rd!==erd[j]||wb_data!==eval[j]||wb_we!==(erd[j]!=0))
                    $fatal(1,"FENCE decode oracle WB architectural stream case=%0d index=%0d rd=%0d value=%h",CASE_ID,j,wb_rd,wb_data);
                if(erd[j]!=0)begin model_gpr[erd[j]]=eval[j];model_known[erd[j]]=1;end
                wbs=wbs+1;
            end
            if(pre_retire)begin
                if(ri>=accepted||ekind[ri]==2||dut.exmem_q.seq!==eseq[ri])
                    $fatal(1,"FENCE decode oracle unsupported instruction retired case=%0d index=%0d",CASE_ID,ri);
                if(!bp_commit_valid||bp_commit_seq!==eseq[ri]||bp_commit_pc!==epc[ri]||bp_commit_is_branch||bp_commit_is_jal||bp_commit_taken)
                    $fatal(1,"FENCE decode oracle non-control commit metadata case=%0d",CASE_ID);
                wb_index[retired]=ri;arch_expected=epc[ri]+4;
            end
            if(pre_trap)begin
                if(ti>=accepted||ekind[ti]!=2||dut.exmem_q.seq!==eseq[ti]||halt_pc!==epc[ti]||
                   halt_cause!==ecause[ti]||halt_tval!==etval[ti]||pre_retire||bp_commit_valid||
                   !redirect_valid||!redirect_kill_ifid||redirect_pc!==32'h100||redirect_seq!==eseq[ti])
                    $fatal(1,"FENCE decode oracle precise exception case=%0d index=%0d cause=%h expected=%h",CASE_ID,ti,halt_cause,ecause[ti]);
                arch_expected=32'h100;
            end else if(redirect_valid)$fatal(1,"FENCE decode oracle unexpected control transfer case=%0d",CASE_ID);
            #1;
            if(retire_valid!==pre_retire||trap_valid!==pre_trap)$fatal(1,"FENCE decode oracle registered event case=%0d",CASE_ID);
            if(pre_retire)begin
                if(retire_seq!==eseq[ri]||retire_pc!==epc[ri]||retire_instr!==eins[ri]||retire_rd!==erd[ri]||
                   retire_value!==eval[ri]||retire_writes_rd!==(erd[ri]!=0))
                    $fatal(1,"FENCE decode oracle retirement architectural stream case=%0d index=%0d rd=%0d value=%h",CASE_ID,ri,retire_rd,retire_value);
                if(ekind[ri]==0)begin fences=fences+1;if(ri<4096)matrix_fences=matrix_fences+1;end
                retired=retired+1;committed=committed+1;
                $fdisplay(trace_fd,"retire,%0d,%h,%h,%h,%0d,%h",cycles,retire_seq,retire_pc,retire_instr,retire_rd,retire_value);
            end
            if(pre_trap)begin
                if(trap_seq!==eseq[ti]||trap_pc!==epc[ti]||trap_cause!==ecause[ti]||trap_tval!==etval[ti])
                    $fatal(1,"FENCE decode oracle persistent exception descriptor case=%0d",CASE_ID);
                traps=traps+1;committed=committed+1;
                $fdisplay(trace_fd,"trap,%0d,%h,%h,%h,0,%h",cycles,trap_seq,trap_pc,trap_cause,trap_tval);
            end
            if(instret_count!==retired||arch_next_pc_q!==arch_expected)$fatal(1,"FENCE decode oracle instret/next-PC case=%0d",CASE_ID);
            for(j=1;j<32;j=j+1)begin
                if(model_known[j])begin
                    if(dut.u_regfile.regs[j]!==model_gpr[j])$fatal(1,"FENCE decode oracle GPR side effect case=%0d x%0d",CASE_ID,j);
                end else if(dut.u_regfile.regs[j]!==32'hxxxxxxxx)
                    $fatal(1,"FENCE decode oracle unknown GPR was written case=%0d x%0d",CASE_ID,j);
            end
        end
    end
    initial begin
        trace_fd=$fopen($sformatf("build/cpu5_s12_fence_decode/case%0d_trace.csv",CASE_ID),"w");
        $fdisplay(trace_fd,"event,cycle,seq,pc,instruction_or_cause,rd,value_or_tval");
        repeat(3)tick;@(negedge clk);rst_n=1;
        if(FENCE_ENABLE)begin
            // Exact cross product of 16 fm, 16 predecessor and 16 successor
            // values. Both reserved register fields rotate through x1..x31;
            // every nonzero GPR is still unknown throughout this phase.
            for(i=0;i<4096;i=i+1)send(fenceword(i,i%31+1,(i*7)%31+1,0),0,0,0,0,0,0);
            drain;
            if(matrix_fences!=4096||model_known!==32'd1)$fatal(1,"FENCE decode oracle full field cross product case=%0d",CASE_ID);
            // Each reserved source aliases a genuinely older producer. In
            // forwarding-off mode a mistaken source-use bit would RAW stall.
            for(i=1;i<32;i=i+1)begin
                send(addi(i,512+i),1,i,512+i,0,0,0);
                send(fenceword((i*137)%4096,i,i,0),0,0,0,0,0,0);
            end
            for(i=0;i<16;i=i+1)send(fenceword(i*273,0,0,0),0,0,0,0,0,0);
            drain;
            if(producer_alias_edges<16||unknown_operand_edges<4096)$fatal(1,"FENCE decode oracle operand coverage case=%0d",CASE_ID);
        end else begin
            // The default-off core preserves the pre-S12 illegal instruction
            // behavior even for words accepted by the enabled implementation.
            for(i=0;i<16;i=i+1)begin
                send(fenceword(i*273,i+1,31-i,0),2,0,0,2,fenceword(i*273,i+1,31-i,0),0);drain;
            end
        end
        // FENCE.I and every other funct3 are deliberately unsupported.
        for(i=1;i<8;i=i+1)begin
            send(fenceword(4095,i,31-i,i),2,0,0,2,fenceword(4095,i,31-i,i),0);drain;
        end
        // Fetch access failure wins even when the payload looks like FENCE.
        send(fenceword(0,31,31,0),2,0,0,1,32'hdead0002,1);drain;
        if(accepted!=offered||committed!=offered||wbs!=retired||traps!=(FENCE_ENABLE?8:24)||
           (FENCE_ENABLE&&(fences!=4143||retired!=4174)))$fatal(1,"FENCE decode oracle terminal totals case=%0d",CASE_ID);
        summary_fd=$fopen($sformatf("build/cpu5_s12_fence_decode/case%0d_summary.json",CASE_ID),"w");
        $fdisplay(summary_fd,"{\"status\":\"PASS\",\"case\":%0d,\"id_mode\":%0d,\"forwarding\":%0d,\"enabled\":%0d,\"matrix_fences\":%0d,\"fences\":%0d,\"accepted\":%0d,\"retired\":%0d,\"wb\":%0d,\"traps\":%0d,\"producer_alias_edges\":%0d,\"unknown_operand_edges\":%0d}",CASE_ID,ID_MODE,FWD,FENCE_ENABLE,matrix_fences,fences,accepted,retired,wbs,traps,producer_alias_edges,unknown_operand_edges);
        $fclose(summary_fd);$fclose(trace_fd);done=1;
    end
endmodule

module cpu5_fence_decode_tb;
    wire [4:0] done;reg test_pass=0;
    cpu5_fence_decode_case #(.CASE_ID(0),.ID_MODE(0),.FWD(0)) c0(done[0]);
    cpu5_fence_decode_case #(.CASE_ID(1),.ID_MODE(0),.FWD(1)) c1(done[1]);
    cpu5_fence_decode_case #(.CASE_ID(2),.ID_MODE(1),.FWD(0)) c2(done[2]);
    cpu5_fence_decode_case #(.CASE_ID(3),.ID_MODE(1),.FWD(1)) c3(done[3]);
    cpu5_fence_decode_case #(.CASE_ID(4),.ID_MODE(1),.FWD(1),.FENCE_ENABLE(0)) off(done[4]);
    initial begin wait(&done);test_pass=1;$display("CPU5 FENCE DECODE SEMANTIC PASS");$finish;end
endmodule
