`timescale 1ns/1ps
// Four real M owners cross independently driven Stats boundaries. Golden
// categories come from fixed machine words and the primitive's latency
// contract, not CPU event bits or DUT Stats counters.
module cpu5_m_stats_window_tb;
    wire [3:0] done;reg test_pass=0;genvar n;
    generate for(n=0;n<4;n=n+1)begin:g
        cpu5_m_stats_window_case #(.CASE_ID(n)) u(done[n]);
    end endgenerate
    initial begin wait(&done);test_pass=1;$display("CPU5 M STATS WINDOW PASS");$stop;end
    initial begin #2000000;$fatal(1,"M Stats window timeout done=%h",done);end
endmodule

module cpu5_m_stats_window_case #(parameter CASE_ID=0)(output reg done=0);
    localparam FAST=CASE_ID==2,KILLED=CASE_ID==3;
    localparam [2:0] OP=CASE_ID==0?0:4;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,in_valid=0,flush_valid=0;reg [63:0] in_seq=64'h200000000,cut=0;
    reg [31:0] in_pc=0,in_instr=0;wire in_ready;wire [9:0] events;
    wire [63:0] cycles,instret;wire [31:0] wpc,wdata;wire [4:0] wrd;wire we,rfire,wfire;
    cpu5_alu_pipeline #(.ENABLE_FORWARDING(1),.ENABLE_CONTROL_FLOW(1),.ENABLE_CSR(1),.ENABLE_SYNC_TRAPS(1),.ENABLE_RV32M(1)) core(
        .clk(clk),.rst_n(rst_n),.irq_external(1'b0),.irq_software(1'b0),.irq_timer(1'b0),
        .in_valid(in_valid),.in_ready(in_ready),.in_pc(in_pc),.in_instr(in_instr),.in_pred_next_pc(in_pc+4),
        .in_pred_taken(1'b0),.in_pred_hit(1'b0),.in_fetch_error(1'b0),.in_fetch_tval(32'd0),.in_seq(in_seq),.in_epoch(8'd0),
        .id_enable(1'b1),.ex_enable(1'b1),.mem_enable(1'b1),.wb_ready(1'b1),.flush_valid(flush_valid),.flush_cut_seq(cut),
        .ex_valid(),.ex_pc(),.ex_instr(),.wb_pc(wpc),.wb_rd(wrd),.wb_data(wdata),.wb_we(we),
        .retire_valid(),.retire_pc(),.retire_instr(),.retire_value(),.retire_rd(),.retire_writes_rd(),.retire_seq(),
        .cycle_count(cycles),.instret_count(instret),.perf_cycle_events(events),.arch_next_pc_q(),.halted(),.halt_pc(),.halt_instr(),.halt_seq(),.halt_fetch_error(),
        .id_raw_wait(),.retire_fire(rfire),.wb_fire(wfire),.redirect_valid(),.redirect_kill_ifid(),.redirect_pc(),.redirect_seq(),
        .bp_commit_valid(),.bp_commit_seq(),.bp_commit_pc(),.bp_commit_target(),.bp_commit_taken(),.bp_commit_is_branch(),.bp_commit_is_jal(),
        .bp_resolved_count(),.bp_mispredict_count(),.bp_direction_error_count(),.bp_target_error_count(),.halt_cause(),.halt_tval(),
        .flush_ready(),.flush_fire(),.dmem_req_valid(),.dmem_req_ready(1'b1),.dmem_req_write(),.dmem_req_addr(),.dmem_req_size(),.dmem_req_wdata(),.dmem_req_wstrb(),
        .dmem_rsp_valid(1'b0),.dmem_rsp_ready(),.dmem_rsp_rdata(32'd0),.dmem_rsp_error(1'b0),.dmem_fault(),.trap_fire(),.trap_valid(),.trap_pc(),.trap_cause(),.trap_tval(),.trap_seq());
    reg av=0;reg [31:0] aa=32'h30000000;wire ar,rv;wire [31:0] rd;wire [1:0] rr;
    axi_lite_cpu5_stats #(.ENABLE_ICACHE(0),.ENABLE_DCACHE(0)) stats(
        .clk(clk),.rst_n(rst_n),.cycle_count(cycles),.instret_count(instret),.perf_cycle_events(events),
        .icache_access_count(32'd0),.icache_hit_count(32'd0),.icache_miss_count(32'd0),.icache_refill_word_count(32'd0),.icache_error_count(32'd0),
        .dcache_access_count(32'd0),.dcache_hit_count(32'd0),.dcache_miss_count(32'd0),.dcache_refill_word_count(32'd0),.dcache_error_count(32'd0),.dcache_write_count(32'd0),.dcache_bypass_count(32'd0),
        .bp_lookup_count(32'd0),.bp_hit_count(32'd0),.bp_taken_count(32'd0),.bp_resolved_count(32'd0),.bp_mispredict_count(32'd0),.bp_direction_error_count(32'd0),.bp_target_error_count(32'd0),
        .s_axi_awaddr(32'd0),.s_axi_awprot(3'd0),.s_axi_awvalid(1'b0),.s_axi_awready(),.s_axi_wdata(32'd0),.s_axi_wstrb(4'd0),.s_axi_wvalid(1'b0),.s_axi_wready(),
        .s_axi_bresp(),.s_axi_bvalid(),.s_axi_bready(1'b1),.s_axi_araddr(aa),.s_axi_arprot(3'd0),.s_axi_arvalid(av),.s_axi_arready(ar),
        .s_axi_rdata(rd),.s_axi_rresp(rr),.s_axi_rvalid(rv),.s_axi_rready(1'b1));
    function [31:0] addi(input [4:0] d,input integer v);addi={v[11:0],5'd0,3'b000,d,7'h13};endfunction
    function [31:0] mword;input [4:0] rhs;begin mword={7'd1,rhs,5'd1,OP,5'd3,7'h33};end endfunction
    integer edge_no=0,gold_instret=0,retired=0,wb=0,expected=0,start_count=0,stop_count=0,reads=0,responses=0,checks=0,starts=0,completions=0;
    integer start_edge=0,done_visible_edge=0;reg owner=0,killed=0;reg [63:0] owner_seq=0;
    reg [63:0] gcounts[0:9],start_values[0:9],stop_values[0:9];
    reg [63:0] start_cycle=0,stop_cycle=0,start_retire=0,stop_retire=0;
    reg start_owner=0,stop_owner=0,start_killed=0,stop_killed=0,start_issue=0;
    reg [63:0] start_seq=0,stop_seq=0,start_gen=0,stop_gen=0;
    reg [31:0] epc[0:7],eins[0:7],eval[0:7];reg [4:0] erd[0:7];reg [63:0] eseq[0:7];
    reg [31:0] pc_next=0;reg [63:0] seq_next=64'h200000000,mseq;
    integer i,category,trace,fd;reg [9:0] gold_event;reg golden_start,live_m,expected_retire,effective_killed;
    reg pre_owner,pre_killed,pre_issue,pre_busy,pre_done;reg [63:0] pre_seq,pre_gen,pre_ex_seq;reg [31:0] pre_ins;reg pre_ex,pre_mem,pre_flush,pre_start,pre_stop;
    always @(posedge clk)if(rst_n&&!done)begin
        edge_no=edge_no+1;
        if(rv)responses=responses+1;
        if(cycles!==edge_no-1||instret!==gold_instret)$fatal(1,"M window independent counter edge");
        effective_killed=killed||(owner&&flush_valid&&owner_seq>=cut);
        live_m=core.idex_valid_q && core.idex_q.instr[6:0]==7'h33 && core.idex_q.instr[31:25]==7'd1 &&
            !(flush_valid&&core.idex_q.seq>=cut);
        golden_start=live_m&&!owner&&!flush_valid;
        if(core.m_unit_start!==golden_start)$fatal(1,"M window independent start ownership");
        if(core.m_owner_valid!==owner||(owner&&(core.m_owner_seq!==owner_seq||core.m_owner_killed!==effective_killed||core.m_owner_generation!==0)))
            $fatal(1,"M window owner seq/generation/killed ledger");
        if(owner && core.m_unit_busy!==(edge_no<done_visible_edge))$fatal(1,"M window independent primitive latency");
        if(owner && core.m_unit_done!==(edge_no>=done_visible_edge))$fatal(1,"M window independent sticky done");
        category=0;
        if(live_m && (golden_start||edge_no<done_visible_edge))category=OP[2]?7:6;
        else if(!in_valid&&!flush_valid)category=1;
        gold_event=10'b1<<category;
        pre_owner=owner;pre_killed=effective_killed;pre_issue=golden_start;pre_busy=core.m_unit_busy;pre_done=core.m_unit_done;
        pre_seq=owner_seq;pre_gen=core.m_owner_generation;pre_ins=core.idex_q.instr;pre_ex_seq=core.idex_q.seq;pre_ex=core.idex_valid_q;pre_mem=core.exmem_valid_q;pre_flush=flush_valid;
        pre_start=av&&ar&&aa==32'h30000000;pre_stop=av&&ar&&aa==32'h30000004;
        if(pre_start||pre_stop)begin
            if(pre_start)begin
                start_count=start_count+1;start_cycle=edge_no-1;start_retire=gold_instret;
                start_owner=owner;start_killed=effective_killed;start_issue=golden_start;
                start_seq=golden_start?core.idex_q.seq:owner_seq;start_gen=core.m_owner_generation;
                for(i=0;i<10;i=i+1)start_values[i]=gcounts[i];
            end else begin
                stop_count=stop_count+1;stop_cycle=edge_no-1;stop_retire=gold_instret;
                stop_owner=owner;stop_killed=effective_killed;stop_seq=owner_seq;stop_gen=core.m_owner_generation;
                for(i=0;i<10;i=i+1)stop_values[i]=gcounts[i];
            end
        end
        expected_retire=core.exmem_valid_q&&!(flush_valid&&core.exmem_q.seq>=cut);
        if(rfire!==expected_retire)$fatal(1,"M window independent retire authorization");
        if(expected_retire)begin
            if(retired>=expected||core.exmem_q.seq!==eseq[retired]||core.exmem_q.pc!==epc[retired]||core.exmem_q.instr!==eins[retired]||
                core.exmem_q.rd!==erd[retired]||core.mem_result_value!==eval[retired])$fatal(1,"M window independent ISA result");
            retired=retired+1;gold_instret=gold_instret+1;
        end
        if(wfire)begin
            if(wb>=retired||wpc!==epc[wb]||wrd!==erd[wb]||wdata!==eval[wb]||!we)$fatal(1,"M window independent WB");wb=wb+1;
        end
        gcounts[category]=gcounts[category]+1;
        if(owner&&edge_no>=done_visible_edge)begin owner=0;completions=completions+1;end
        else if(owner)killed=effective_killed;
        if(golden_start)begin
            owner=1;killed=0;owner_seq=core.idex_q.seq;start_edge=edge_no;done_visible_edge=edge_no+(FAST?1:OP[2]?33:3);starts=starts+1;
        end
        #1;
        if(events!==gold_event)$fatal(1,"M window independently scheduled class expected=%h actual=%h case=%0d edge=%0d",gold_event,events,CASE_ID,edge_no);
        $fwrite(trace,"%0d,%0d,%03h,%03h,%0d,%0d,%016h,%016h,%0d,%0d,%0d,%0d,%08h,%016h,%0d,%0d,%0d,%0d\n",edge_no-1,cycles,gold_event,events,pre_owner,pre_killed,pre_seq,pre_gen,pre_issue,pre_busy,pre_done,pre_ex,pre_ins,pre_ex_seq,pre_mem,pre_flush,pre_start,pre_stop);
    end
    task tick;begin @(posedge clk);#2;end endtask
    task emit(input [31:0] ins,input [4:0] dest,input [31:0] value,input keep);
        integer timeout;begin
            @(negedge clk);in_valid=1;in_instr=ins;in_pc=pc_next;in_seq=seq_next;
            if(keep)begin epc[expected]=pc_next;eins[expected]=ins;erd[expected]=dest;eval[expected]=value;eseq[expected]=seq_next;expected=expected+1;end
            if(ins[6:0]==7'h33)mseq=seq_next;timeout=0;@(posedge clk);while(!in_ready)begin timeout=timeout+1;if(timeout>500)$fatal(1,"M window admission timeout");@(posedge clk);end
            #2;in_valid=0;pc_next=pc_next+4;seq_next=seq_next+1;
        end
    endtask
    task finish;
        integer timeout;begin timeout=0;while(retired!=expected||wb!=expected||core.idex_valid_q||core.exmem_valid_q||core.memwb_valid_q||core.m_owner_valid)begin
            tick;timeout=timeout+1;if(timeout>500)$fatal(1,"M window drain timeout");end end
    endtask
    function [31:0] word_gold(input integer offset);
        integer field,shift;reg [63:0] value;begin
            if(offset==0||offset==4)word_gold=32'h434d4158;
            else begin
                shift=(offset&4)?32:0;value=0;
                if(offset>=32'h40&&offset<32'h50)value=(offset<32'h48)?start_cycle:start_retire;
                else if(offset>=32'h80&&offset<32'h90)value=(offset<32'h88)?stop_cycle:stop_retire;
                else if(offset>=32'h100&&offset<32'h130)begin field=(offset-32'h100)/8;value=start_values[field];end
                else if(offset>=32'h140&&offset<32'h170)begin field=(offset-32'h140)/8;value=stop_values[field];end
                else if(offset>=32'h180&&offset<32'h1a0)begin field=6+(offset-32'h180)/8;value=start_values[field];end
                else if(offset>=32'h1c0&&offset<32'h1e0)begin field=6+(offset-32'h1c0)/8;value=stop_values[field];end
                else $fatal(1,"M window read unexpected offset");
                word_gold=value>>shift;
            end
        end
    endfunction
    task read_word(input integer offset);
        integer timeout;begin
            @(negedge clk);aa=32'h30000000+offset;av=1;
            timeout=0;@(posedge clk);while(!ar)begin timeout=timeout+1;if(timeout>100)$fatal(1,"M window AR timeout");@(posedge clk);end
            #2;if(!rv||rr!=0||rd!==word_gold(offset))$fatal(1,"M window snapshot word offset=%h expected=%h actual=%h",offset,word_gold(offset),rd);
            av=0;reads=reads+1;checks=checks+1;
        end
    endtask
    integer t,base,bank,pass_no;reg [63:0] sum;
    initial begin
        for(t=0;t<10;t=t+1)begin gcounts[t]=0;start_values[t]=0;stop_values[t]=0;end
        trace=$fopen($sformatf("build/cpu5_s16_m_stats_window/case%0d.csv",CASE_ID),"w");
        $fwrite(trace,"edge_id,cycle_count,gold_event,actual_event,owner_valid,owner_killed,owner_seq,owner_generation,unit_start,unit_busy,unit_done,ex_valid,ex_instr,ex_seq,mem_valid,flush,start,stop\n");
        repeat(3)@(negedge clk);rst_n=1;
        emit(addi(1,7),1,7,1);emit(addi(2,3),2,3,1);finish;
        emit(mword(FAST?0:2),3,FAST?32'hffffffff:OP[2]?2:21,!KILLED);
        if(FAST)read_word(0);
        else begin
            while(!core.m_owner_valid)tick;
            if(KILLED)begin
                @(negedge clk);cut=mseq;flush_valid=1;tick;flush_valid=0;
            end
            read_word(0);
        end
        if(KILLED)emit(addi(4,11),4,11,1);
        else if(CASE_ID==1)repeat(3)tick;
        read_word(4);
        if(!stop_owner||stop_seq!==mseq||start_seq!==mseq||start_gen!==0||stop_gen!==0)$fatal(1,"M window missing actual owner crossing");
        if(FAST)begin if(start_owner||!start_issue||start_killed||stop_killed)$fatal(1,"M fast allocation boundary identity");end
        else if(!start_owner||start_issue||start_killed!==KILLED||stop_killed!==KILLED)$fatal(1,"M live/killed boundary identity");
        sum=0;for(t=0;t<10;t=t+1)sum=sum+stop_values[t]-start_values[t];
        if(sum!=stop_cycle-start_cycle||sum==0)$fatal(1,"M half-open window class sum");
        if(KILLED)begin if(stop_values[6]!=start_values[6]||stop_values[7]!=start_values[7])$fatal(1,"M killed background window counted M");end
        else if(stop_values[OP[2]?7:6]<=start_values[OP[2]?7:6])$fatal(1,"M live window lost waiting edge");
        if(FAST&&stop_values[7]-start_values[7]!=1)$fatal(1,"M fast half-open boundary count");
        // Printing while the owner completes cannot change either bank.
        for(pass_no=0;pass_no<2;pass_no=pass_no+1)begin
            for(t=0;t<4;t=t+1)begin read_word(32'h40+t*4);read_word(32'h80+t*4);end
            for(bank=0;bank<2;bank=bank+1)for(t=0;t<10;t=t+1)begin
                base=bank?(t<6?32'h140+8*t:32'h1c0+8*(t-6)):(t<6?32'h100+8*t:32'h180+8*(t-6));
                read_word(base);read_word(base+4);
            end
        end
        tick;finish;
        if(starts!=1||completions!=1||start_count!=1||stop_count!=1||retired!=expected||wb!=expected||reads!=responses||reads!=98)$fatal(1,"M window final owner/response ledger");
        fd=$fopen($sformatf("build/cpu5_s16_m_stats_window/case%0d_summary.json",CASE_ID),"w");
        $fwrite(fd,"{\"status\":\"PASS\",\"case\":%0d,\"fast\":%0d,\"killed\":%0d,\"op\":%0d,\"cycles\":%0d,\"checks\":%0d,\"reads\":%0d,\"retired\":%0d,\"wb\":%0d,\"owner_starts\":%0d,\"owner_completions\":%0d,\"window\":{\"start\":%0d,\"stop\":%0d,\"cycles\":%0d,\"start_instret\":%0d,\"stop_instret\":%0d,\"start_owner_valid\":%0d,\"start_issue\":%0d,\"start_owner_killed\":%0d,\"stop_owner_valid\":%0d,\"stop_owner_killed\":%0d,\"owner_seq\":\"%016h\",\"owner_generation\":%0d,\"profile_delta\":[",CASE_ID,FAST,KILLED,OP,cycles,checks,reads,retired,wb,starts,completions,start_cycle,stop_cycle,stop_cycle-start_cycle,start_retire,stop_retire,start_owner,start_issue,start_killed,stop_owner,stop_killed,start_seq,start_gen);
        for(t=0;t<10;t=t+1)$fwrite(fd,"%0d%s",stop_values[t]-start_values[t],t==9?"]}}\n":",");
        $fclose(fd);$fclose(trace);done=1;
    end
endmodule
