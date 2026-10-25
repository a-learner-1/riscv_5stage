`timescale 1ns/1ps
// Directed public-handshake experiments. Expected categories are selected by
// the scenario, never by the DUT's perf candidate wires.
module cpu5_cycle_profile_tb;
    wire [3:0] done;reg test_pass=0;genvar n;
    generate for(n=0;n<4;n=n+1)begin:g
        cpu5_cycle_profile_case #(.CASE_ID(n),.FWD(n%2),.MODE(n/2)) u(done[n]);
    end endgenerate
    initial begin wait(&done);test_pass=1;$display("CPU5 CYCLE PROFILE TEST PASS");$stop;end
    initial begin #2000000;$fatal(1,"CPU5 cycle profile timeout done=%h",done);end
endmodule

module cpu5_cycle_profile_case #(parameter CASE_ID=0,FWD=0,MODE=0)(output reg done=0);
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,in_valid=0,id_enable=1,ex_enable=1,mem_enable=1,wb_ready=1,flush_valid=0;
    reg [63:0] in_seq=64'h100000000,flush_cut_seq=0;reg [31:0] in_pc=0,in_instr=0,in_pred_next_pc=4;
    wire in_ready;wire [9:0] events;wire [63:0] cycles,instret;
    wire qv,qr,qw,sv,sr,err;wire [31:0] qa,qd,rd;wire [1:0] qs;wire [3:0] qt;
    wire rv,wfire,rfire;wire [31:0] rpc,rins,rvalue,wpc,wdata;wire [63:0] rseq;wire [4:0] rrd,wrd;wire we,redirect;
    cpu5_alu_pipeline #(.ENABLE_FORWARDING(FWD),.ENABLE_CONTROL_FLOW(1),.BRANCH_RESOLVE_IN_ID(MODE),
        .ENABLE_RAM(1),.DMEM_WORDS(16),.ENABLE_MMIO(1),.ENABLE_FENCE(1),.ENABLE_SYNC_TRAPS(1),
        .ENABLE_CSR(1),.ENABLE_RV32M(1),.TRAP_VECTOR(32'h100)) dut(
        .clk(clk),.rst_n(rst_n),.irq_external(1'b0),.irq_software(1'b0),.irq_timer(1'b0),
        .in_valid(in_valid),.in_ready(in_ready),.in_pc(in_pc),.in_instr(in_instr),.in_pred_next_pc(in_pred_next_pc),
        .in_pred_taken(1'b0),.in_pred_hit(1'b0),.in_fetch_error(1'b0),.in_fetch_tval(32'd0),.in_seq(in_seq),.in_epoch(8'd0),
        .id_enable(id_enable),.ex_enable(ex_enable),.mem_enable(mem_enable),.wb_ready(wb_ready),
        .flush_valid(flush_valid),.flush_cut_seq(flush_cut_seq),.ex_valid(),.ex_pc(),.ex_instr(),
        .wb_pc(wpc),.wb_rd(wrd),.wb_data(wdata),.wb_we(we),.retire_valid(rv),.retire_pc(rpc),.retire_instr(rins),
        .retire_seq(rseq),.retire_rd(rrd),.retire_value(rvalue),.retire_writes_rd(),.perf_cycle_events(events),
        .cycle_count(cycles),.instret_count(instret),.arch_next_pc_q(),.halted(),.halt_pc(),.halt_instr(),.halt_seq(),.halt_fetch_error(),
        .id_raw_wait(),.retire_fire(rfire),.wb_fire(wfire),.redirect_valid(redirect),.redirect_kill_ifid(),.redirect_pc(),.redirect_seq(),
        .bp_commit_valid(),.bp_commit_seq(),.bp_commit_pc(),.bp_commit_target(),.bp_commit_taken(),.bp_commit_is_branch(),.bp_commit_is_jal(),
        .bp_resolved_count(),.bp_mispredict_count(),.bp_direction_error_count(),.bp_target_error_count(),.halt_cause(),.halt_tval(),
        .flush_ready(),.flush_fire(),.dmem_req_valid(qv),.dmem_req_ready(qr),.dmem_req_write(qw),.dmem_req_addr(qa),.dmem_req_size(qs),
        .dmem_req_wdata(qd),.dmem_req_wstrb(qt),.dmem_rsp_valid(sv),.dmem_rsp_ready(sr),.dmem_rsp_rdata(rd),.dmem_rsp_error(err),.dmem_fault(),
        .trap_fire(),.trap_valid(),.trap_pc(),.trap_cause(),.trap_tval(),.trap_seq());
    reg pending=0,hold_req=0,hold_rsp=0;integer delay=0,latency=12;
    reg [31:0] response=0,memory[0:15];integer aq=0,ar=0,writes=0;
    assign qr=rst_n&&!pending&&!hold_req;assign sv=rst_n&&pending&&delay==0&&!hold_rsp;
    assign rd=response;assign err=0;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin pending<=0;delay<=0;response<=0;end
        else begin
            if(sv&&sr)begin pending<=0;ar=ar+1;end
            if(pending&&delay>0)delay<=delay-1;
            if(qv&&qr)begin
                if(pending)$fatal(1,"profile endpoint owner overwrite");
                pending<=1;delay<=latency;aq=aq+1;response<=0;
                if(qa>=32'h10000&&qa<32'h10040)begin
                    if(qw)begin
                        if(qs!=2||qt!=15)$fatal(1,"profile fixture store shape");
                        memory[(qa-32'h10000)>>2]<=qd;writes=writes+1;
                    end else response<=memory[(qa-32'h10000)>>2];
                end else if(qa[31:8]==24'h200000)response<=qw?0:32'habcdef00;
                else $fatal(1,"profile fixture unknown request");
            end
        end
    end
    function [31:0] addi(input [4:0] d,a,input integer v);addi={v[11:0],a,3'b000,d,7'h13};endfunction
    function [31:0] load(input [4:0] d,a);load={12'd0,a,3'b010,d,7'h03};endfunction
    function [31:0] store(input [4:0] a,d);store={7'd0,d,a,3'b010,5'd0,7'h23};endfunction
    function [31:0] mop(input [2:0] f,input [4:0] d,a,b);mop={7'd1,b,a,f,d,7'h33};endfunction
    function [31:0] csr(input [2:0] f,input [4:0] d,input [11:0] a,input [4:0] z);csr={a,z,f,d,7'h73};endfunction
    function [31:0] branch(input [4:0] a);branch={7'd0,5'd0,a,3'b000,5'd4,7'h63};endfunction
    reg [63:0] expected_seq[0:255];reg [31:0] expected_pc[0:255],expected_ins[0:255],expected_value[0:255];reg [4:0] expected_rd[0:255];
    integer expected=0,retired=0,wb=0,checks=0,redirects=0,total_edges=0,phase=0;
    integer counts[0:9];reg [9:0] seen=0;integer i,index,sum,fd,trace;
    reg [63:0] pre_cycles;reg [31:0] pc_next=0;reg [63:0] seq_next=64'h100000000,last_seq;
    integer manual=-1,load_dep_checks=0,id_dep_checks=0,bg_m_checks=0,bg_d_checks=0,fence_checks=0,blocked_m_checks=0,fast_checks=0;
    always @(posedge clk)if(rst_n&&!done)begin
        pre_cycles=cycles;manual=-1;
        if(redirect)redirects=redirects+1;
        if(rfire)begin
            if(retired>=expected||dut.exmem_q.seq!==expected_seq[retired]||dut.exmem_q.pc!==expected_pc[retired]||
                dut.exmem_q.instr!==expected_ins[retired]||dut.exmem_q.rd!==expected_rd[retired]||dut.mem_result_value!==expected_value[retired])
                $fatal(1,"profile directed independent retire ledger case=%0d ordinal=%0d pc=%h expected=%h",CASE_ID,retired,dut.exmem_q.pc,expected_pc[retired]);
            retired=retired+1;
        end
        if(wfire)begin
            if(wb>=retired||wpc!==expected_pc[wb]||wrd!==expected_rd[wb]||wdata!==expected_value[wb]||we!==(expected_rd[wb]!=0))
                $fatal(1,"profile directed physical WB ledger");
            wb=wb+1;
        end
        if(phase==1&&in_valid&&dut.idex_valid_q&&dut.idex_q.is_load&&!dut.exmem_valid_q&&(!FWD||MODE))begin manual=8;load_dep_checks=load_dep_checks+1;end
        if(phase==2&&in_valid&&dut.csr_serial_wait&&dut.ex_can_load&&!dut.mem_fault)begin manual=9;id_dep_checks=id_dep_checks+1;end
        if(phase==3&&dut.m_owner_valid&&dut.m_owner_killed&&!dut.idex_q.is_m)begin
            if(events[6]||events[7])begin end // The post-edge sample below belongs to this edge.
            bg_m_checks=bg_m_checks+1;
            if(in_valid&&in_ready)manual=0;
        end
        if(phase==4&&dut.ram_owner_valid&&dut.ram_owner_killed&&!dut.exmem_valid_q&&!dut.idex_q.is_load)begin
            bg_d_checks=bg_d_checks+1;if(in_valid&&in_ready)manual=0;
        end
        if(phase==5&&dut.exmem_valid_q&&dut.exmem_q.fence_op&&dut.ram_owner_valid)begin manual=2;fence_checks=fence_checks+1;end
        if(phase==6&&dut.m_owner_valid&&dut.m_owner_killed&&dut.idex_valid_q&&dut.idex_q.is_m)begin manual=6;blocked_m_checks=blocked_m_checks+1;end
        if(phase==7&&dut.m_unit_start)begin manual=7;fast_checks=fast_checks+1;end
        #1;
        if(cycles!==pre_cycles+1)$fatal(1,"profile edge/cycle alignment");
        if(events==0||(events&(events-1))!=0)$fatal(1,"profile onehot event missing/multiple");
        index=0;for(i=0;i<10;i=i+1)if(events[i])index=i;
        counts[index]=counts[index]+1;seen=seen|events;total_edges=total_edges+1;
        sum=0;for(i=0;i<10;i=i+1)sum=sum+counts[i];
        if(sum!=cycles)$fatal(1,"profile ten class sum differs from cycles");
        if(manual>=0&&events!==(10'b1<<manual))$fatal(1,"profile scenario category case=%0d phase=%0d expected=%0d actual=%h",CASE_ID,phase,manual,events);
        if(phase==3&&dut.m_owner_valid&&dut.m_owner_killed&&!dut.idex_q.is_m&&(events[6]||events[7]))$fatal(1,"profile background M drain misattributed");
        $fwrite(trace,"%0d,%0d,%03h,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",total_edges,cycles,events,phase,dut.idex_valid_q,dut.exmem_valid_q,dut.memwb_valid_q,pending,delay,dut.m_owner_valid,dut.m_owner_killed,dut.ram_owner_killed);
    end
    task tick;begin @(posedge clk);#2;end endtask
    task emit(input [31:0] ins,input [4:0] dest,input [31:0] value,input keep);
        integer timeout;
        begin
            @(negedge clk);in_instr=ins;in_pc=pc_next;in_pred_next_pc=pc_next+4;in_seq=seq_next;in_valid=1;
            last_seq=seq_next;
            if(keep)begin expected_seq[expected]=seq_next;expected_pc[expected]=pc_next;expected_ins[expected]=ins;
                expected_rd[expected]=dest;expected_value[expected]=value;expected=expected+1;end
            timeout=0;@(posedge clk);while(!in_ready)begin timeout=timeout+1;if(timeout>1200)$fatal(1,"profile admission timeout");@(posedge clk);end
            #2;in_valid=0;seq_next=seq_next+1;pc_next=pc_next+4;
        end
    endtask
    task finish;
        integer timeout;
        begin timeout=0;while(retired!=expected||wb!=expected||dut.idex_valid_q||dut.exmem_valid_q||dut.memwb_valid_q||dut.ram_owner_valid||dut.m_owner_valid)begin
            tick;timeout=timeout+1;if(timeout>1200)$fatal(1,"profile finish timeout case=%0d expected=%0d retired=%0d wb=%0d",CASE_ID,expected,retired,wb);end
            checks=checks+1;
        end
    endtask
    task category(input integer wanted);
        begin @(posedge clk);#2;if(events!==(10'b1<<wanted))$fatal(1,"profile directed category case=%0d expected=%0d actual=%h",CASE_ID,wanted,events);checks=checks+1;end
    endtask
    task mem_wait;
        integer timeout;
        begin timeout=0;while(!(dut.exmem_valid_q&&pending&&delay>2))begin tick;timeout=timeout+1;if(timeout>1200)$fatal(1,"profile mem wait fixture");end end
    endtask
    task flush_last;
        begin @(negedge clk);flush_cut_seq=last_seq;flush_valid=1;@(posedge clk);if(!dut.flush_ready)$fatal(1,"profile pure operation flush rejected");#2;
            @(negedge clk);flush_valid=0;end
    endtask
    integer before_div,before_redirect,t;
    initial begin
        for(t=0;t<16;t=t+1)memory[t]=0;for(t=0;t<10;t=t+1)counts[t]=0;
        trace=$fopen($sformatf("build/cpu5_s16_cycle_profile/case%0d.csv",CASE_ID),"w");
        $fwrite(trace,"edge,cycles,event,phase,ex,mem,wb,pending,delay,m_owner,m_killed,d_killed\n");
        repeat(3)@(negedge clk);rst_n=1;category(1);
        @(negedge clk);id_enable=0;category(0);@(negedge clk);id_enable=1;
        emit(32'h000100b7,1,32'h10000,1);emit(addi(2,0,85),2,85,1);
        emit(32'h200001b7,3,32'h20000000,1);emit(addi(4,0,7),4,7,1);emit(addi(5,0,3),5,3,1);finish;
        emit(store(1,2),0,0,1);mem_wait;category(3);finish;
        emit(load(7,1),7,85,1);mem_wait;category(2);
        @(negedge clk);mem_enable=0;category(0);@(negedge clk);mem_enable=1;finish;
        emit(load(8,3),8,32'habcdef00,1);mem_wait;category(4);finish;
        phase=1;emit(load(8,1),8,85,1);
        if(MODE)emit(branch(8),0,0,1);else emit(addi(9,8,1),9,86,1);
        finish;phase=0;
        phase=2;emit(csr(1,0,12'h340,4),0,0,1);emit(csr(2,11,12'h340,0),11,7,1);finish;phase=0;
        emit(mop(0,12,4,5),12,21,1);while(!dut.m_owner_valid)tick;category(6);finish;
        emit(mop(4,13,4,5),13,2,1);
        @(negedge clk);ex_enable=0;category(0);@(negedge clk);ex_enable=1;
        while(!dut.m_owner_valid)tick;category(7);finish;
        before_div=counts[7];phase=7;emit(mop(4,14,4,0),14,32'hffffffff,1);finish;phase=0;
        if(counts[7]-before_div!=1)$fatal(1,"profile DIV fast path start/result accounting");checks=checks+1;
        latency=50;@(negedge clk);wb_ready=0;emit(addi(15,0,15),15,15,1);
        while(!dut.memwb_valid_q)tick;
        emit(load(16,1),16,85,1);mem_wait;category(0);
        @(negedge clk);wb_ready=1;category(2);finish;latency=20;
        emit(mop(4,17,4,5),17,2,0);while(!dut.m_unit_busy)tick;flush_last;
        phase=3;emit(addi(20,0,20),20,20,1);repeat(2)tick;
        phase=6;emit(mop(0,21,4,5),21,21,1);finish;phase=0;
        emit(load(22,1),22,85,0);mem_wait;flush_last;
        phase=4;emit(addi(22,0,22),22,22,1);repeat(2)tick;
        phase=5;emit(32'h0ff0000f,0,0,1);finish;phase=0;
        before_redirect=redirects;emit(32'h0080006f,0,pc_next+4,1);pc_next=pc_next+4;
        while(redirects==before_redirect)tick;
        while(!in_ready)tick;category(5);
        emit(addi(23,0,23),23,23,1);finish;category(1);
        if(aq!=ar||retired!=expected||wb!=expected||writes!=1||memory[0]!==85)$fatal(1,"profile final endpoint/retire closure");
        if(load_dep_checks==0&&(!FWD||MODE))$fatal(1,"profile missing load-use experiment");
        if(id_dep_checks==0||bg_m_checks==0||bg_d_checks==0||blocked_m_checks==0||fence_checks==0||fast_checks!=1)$fatal(1,"profile missing directed experiment");
        if((seen&10'h0ff)!=10'h0ff||((!FWD||MODE)&&!seen[8])||!seen[9])$fatal(1,"profile class coverage");
        fd=$fopen($sformatf("build/cpu5_s16_cycle_profile/case%0d_summary.json",CASE_ID),"w");
        $fwrite(fd,"{\"status\":\"PASS\",\"case\":%0d,\"forwarding\":%0d,\"id_mode\":%0d,\"cycles\":%0d,\"checks\":%0d,\"retired\":%0d,\"wb\":%0d,\"requests\":%0d,\"responses\":%0d,\"load_dep_checks\":%0d,\"id_dep_checks\":%0d,\"background_m_checks\":%0d,\"background_d_checks\":%0d,\"blocked_m_checks\":%0d,\"fence_checks\":%0d,\"fast_checks\":%0d,\"class_counts\":[",CASE_ID,FWD,MODE,cycles,checks,retired,wb,aq,ar,load_dep_checks,id_dep_checks,bg_m_checks,bg_d_checks,blocked_m_checks,fence_checks,fast_checks);
        for(t=0;t<10;t=t+1)$fwrite(fd,"%0d%s",counts[t],t==9?"]}\n":",");$fclose(fd);$fclose(trace);
        @(negedge clk);rst_n=0;#2;if(events!==0||cycles!==0)$fatal(1,"profile asynchronous reset did not zero event/count");
        done=1;
    end
endmodule
