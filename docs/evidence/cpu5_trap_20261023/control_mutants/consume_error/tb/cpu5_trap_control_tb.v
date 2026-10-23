`timescale 1ns/1ps
// Independent hand-authored architecture and endpoint ledgers. No internal
// force; synthetic external flush is an explicitly handshaken test stimulus.
module cpu5_trap_control_case #(parameter integer MODE=0)(output reg done=0);
    localparam [31:0] VECTOR=32'h100;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,in_valid=0,in_fetch_error=0,in_pred_taken=0,in_pred_hit=0;
    reg [31:0] in_pc=0,in_instr=0,in_pred_next_pc=0,in_fetch_tval=0;
    reg [63:0] in_seq=0,flush_cut_seq=0;reg [7:0] in_epoch=0;
    reg id_enable=1,ex_enable=1,mem_enable=1,wb_ready=1,flush_valid=0;
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
    reg dmem_req_ready=1,dmem_rsp_valid=0,dmem_rsp_error=0;reg [31:0] dmem_rsp_rdata=0;
    wire [31:0] dmem_req_addr,dmem_req_wdata;wire [1:0] dmem_req_size;wire [3:0] dmem_req_wstrb;
    cpu5_alu_pipeline #(.ENABLE_FORWARDING(1),.ENABLE_CONTROL_FLOW(1),
        .BRANCH_RESOLVE_IN_ID(MODE),.ENABLE_BRANCH_PRED(1),.ENABLE_RAM(1),
        .DMEM_WORDS(8),.ENABLE_SYNC_TRAPS(1),.TRAP_VECTOR(VECTOR)) dut(.*);
    reg [63:0] eseq[0:31],tseq[0:7],qseq[0:15],rseq[0:7];
    reg [31:0] epc[0:31],eins[0:31],eval[0:31],enext[0:31];reg [4:0] erd[0:31];
    reg [31:0] tpc[0:7],tcause[0:7],ttval[0:7],rpc[0:7];
    reg [31:0] qa[0:15],qd[0:15];reg [1:0] qs[0:15];reg [3:0] qst[0:15];reg qw[0:15];
    integer expected=0,retired=0,wb_count=0,traps_expected=0,traps=0;
    integer requests_expected=0,requests=0,responses=0,expected_redirects=0,redirects=0;
    integer case_no=0,passed=0,cycles=0,timeout=0,i,j,stage,ri,wi,ti;
    integer trace_fd,summary_fd,total_retired=0,total_wb=0,total_traps=0,total_requests=0,total_responses=0;
    integer total_writes=0,total_held=0,total_killed_rsp=0,total_wb_trap=0,total_wb_held_trap=0;
    integer total_mem_wait=0,total_handler_drain_retire=0,total_redirects=0;
    reg last_accept=0,last_rsp=0,last_trap=0;reg [63:0] last_accept_seq=0;
    reg pre_trap,pre_retire,pre_wb,pre_we,pre_wb_hold,bus_pending=0,bus_store=0,held=0;
    reg [63:0] pre_wb_seq;reg [31:0] pre_wb_pc,pre_wb_value;reg [4:0] pre_wb_rd;
    reg [63:0] bus_seq=0,saved_trap_seq=0;
    reg [31:0] bus_addr=0,arch_expected=0,saved_trap_pc=0,saved_trap_cause=0,saved_trap_tval=0;
    reg [134:0] held_fields=0;reg [31:0] word;
    function [31:0] addi(input [4:0] d,input [4:0] s,input integer v);
        begin addi={v[11:0],s,3'b000,d,7'h13};end
    endfunction
    function [31:0] load(input [4:0] d,input [4:0] s,input [2:0] f,input integer v);
        begin load={v[11:0],s,f,d,7'h03};end
    endfunction
    function [31:0] store(input [4:0] s2,input [4:0] s1,input [2:0] f,input integer v);
        begin store={v[11:5],s2,s1,f,v[4:0],7'h23};end
    endfunction
    function [31:0] jal(input [4:0] d,input integer v);
        begin jal={v[20],v[10:1],v[11],v[19:12],d,7'h6f};end
    endfunction
    task tick;
        begin @(posedge clk);#2;
            if((last_accept&&last_accept_seq==in_seq)||last_trap)in_valid=0;
        end
    endtask
    task reset_case(input integer n);
        begin @(negedge clk);rst_n=0;in_valid=0;in_fetch_error=0;in_pred_taken=0;in_pred_hit=0;
            in_epoch=0;id_enable=1;ex_enable=1;mem_enable=1;wb_ready=1;flush_valid=0;
            dmem_req_ready=1;dmem_rsp_valid=0;dmem_rsp_error=0;
            case_no=n;expected=0;traps_expected=0;requests_expected=0;expected_redirects=0;
            tick;tick;@(negedge clk);rst_n=1;
        end
    endtask
    task expect_packet(input [63:0] seq,input [31:0] pc,input [31:0] ins,input [4:0] d,input [31:0] v,input [31:0] nextpc);
        begin eseq[expected]=seq;epc[expected]=pc;eins[expected]=ins;erd[expected]=d;
            eval[expected]=v;enext[expected]=nextpc;expected=expected+1;end
    endtask
    task expect_alu(input [63:0] seq,input [31:0] pc,input [31:0] ins,input [4:0] d,input [31:0] v);
        begin expect_packet(seq,pc,ins,d,v,pc+4);end
    endtask
    task expect_trap(input [63:0] seq,input [31:0] pc,input [31:0] cause,input [31:0] tval);
        begin tseq[traps_expected]=seq;tpc[traps_expected]=pc;tcause[traps_expected]=cause;
            ttval[traps_expected]=tval;traps_expected=traps_expected+1;end
    endtask
    task expect_request(input [63:0] seq,input wr,input [31:0] a,input [1:0] s,input [31:0] d,input [3:0] st);
        begin qseq[requests_expected]=seq;qw[requests_expected]=wr;qa[requests_expected]=a;
            qs[requests_expected]=s;qd[requests_expected]=d;qst[requests_expected]=st;requests_expected=requests_expected+1;end
    endtask
    task expect_redirect(input [63:0] seq,input [31:0] pc);
        begin rseq[expected_redirects]=seq;rpc[expected_redirects]=pc;expected_redirects=expected_redirects+1;end
    endtask
    task offer(input [63:0] seq,input [31:0] pc,input [31:0] ins,input [7:0] epoch);
        begin @(negedge clk);in_valid=1;in_seq=seq;in_pc=pc;in_instr=ins;in_epoch=epoch;
            in_pred_next_pc=pc+4;in_pred_taken=0;in_pred_hit=0;end
    endtask
    task send(input [63:0] seq,input [31:0] pc,input [31:0] ins,input [7:0] epoch);
        begin offer(seq,pc,ins,epoch);timeout=0;tick;
            while(!(last_accept&&last_accept_seq==seq))begin tick;timeout=timeout+1;
                if(timeout>80)$fatal(1,"TRAP ID timeout mode=%0d case=%0d seq=%0d",MODE,case_no,seq);end
        end
    endtask
    task wait_traps(input integer n);
        begin timeout=0;while(traps<n)begin tick;timeout=timeout+1;
            if(timeout>80)$fatal(1,"TRAP event timeout mode=%0d case=%0d traps=%0d/%0d",MODE,case_no,traps,n);end end
    endtask
    task wait_requests(input integer n);
        begin timeout=0;while(requests<n)begin tick;timeout=timeout+1;
            if(timeout>80)$fatal(1,"TRAP D request timeout mode=%0d case=%0d req=%0d/%0d",MODE,case_no,requests,n);end end
    endtask
    task wait_present;
        begin timeout=0;while(!dmem_req_valid)begin tick;timeout=timeout+1;
            if(timeout>80)$fatal(1,"TRAP D present timeout");end tick;end
    endtask
    task respond(input [31:0] data,input error);
        begin @(negedge clk);dmem_rsp_valid=1;dmem_rsp_rdata=data;dmem_rsp_error=error;timeout=0;tick;
            while(!last_rsp)begin tick;timeout=timeout+1;if(timeout>80)$fatal(1,"TRAP response timeout");end
            @(negedge clk);dmem_rsp_valid=0;dmem_rsp_error=0;
        end
    endtask
    task flush_load(input [63:0] cut);
        begin @(negedge clk);flush_valid=1;flush_cut_seq=cut;in_valid=0;#1;
            if(!flush_ready||!flush_fire)$fatal(1,"TRAP cancelable LOAD flush rejected");
            tick;@(negedge clk);flush_valid=0;end
    endtask
    task init_base;
        begin expect_alu(1,'h80,32'h000100b7,1,'h10000);send(1,'h80,32'h000100b7,0);repeat(3)tick;end
    endtask
    task handler_alu(input [63:0] seq,input [31:0] v);
        begin expect_alu(seq,VECTOR,addi(7,0,v),7,v);send(seq,VECTOR,addi(7,0,v),8'hff);end
    endtask
    task finish_case;
        begin in_valid=0;timeout=0;
            while(retired!=expected || wb_count!=expected || traps!=traps_expected || dut.idex_valid_q ||
                dut.exmem_valid_q || dut.memwb_valid_q || dut.ram_owner_valid || bus_pending)begin
                tick;timeout=timeout+1;if(timeout>100)$fatal(1,"TRAP drain mode=%0d case=%0d retire=%0d/%0d wb=%0d trap=%0d/%0d req=%0d/%0d",MODE,case_no,retired,expected,wb_count,traps,traps_expected,requests,requests_expected);
            end
            repeat(6)tick;
            if(requests!=requests_expected||responses!=requests||redirects!=expected_redirects)
                $fatal(1,"TRAP ledger not closed mode=%0d case=%0d req=%0d/%0d rsp=%0d redirects=%0d/%0d",MODE,case_no,requests,requests_expected,responses,redirects,expected_redirects);
            passed=passed+1;$display("CPU5_TRAP_CONTROL_CASE_PASS mode=%0d case=%0d retire=%0d traps=%0d req=%0d",MODE,case_no,retired,traps,requests);
        end
    endtask
    always @(posedge clk)begin
        cycles=cycles+1;
        if(!rst_n)begin
            retired=0;wb_count=0;traps=0;requests=0;responses=0;redirects=0;
            bus_pending=0;held=0;last_accept=0;last_rsp=0;last_trap=0;
            arch_expected=0;saved_trap_seq=0;saved_trap_pc=0;saved_trap_cause=0;saved_trap_tval=0;
            if(wb_we||retire_fire||trap_fire||redirect_valid||dmem_req_valid||dmem_rsp_ready)$fatal(1,"TRAP reset side effect");
            #1;if(trap_valid||trap_pc!==0||trap_cause!==0||trap_tval!==0||trap_seq!==0||instret_count!==0||arch_next_pc_q!==0)
                $fatal(1,"TRAP reset descriptor state");
        end else begin
            last_accept=in_valid&&in_ready;last_accept_seq=in_seq;last_rsp=dmem_rsp_valid&&dmem_rsp_ready;
            pre_trap=trap_fire;last_trap=trap_fire;pre_retire=retire_fire;pre_wb=wb_fire;pre_we=wb_we;
            pre_wb_hold=dut.memwb_valid_q&&!wb_ready;pre_wb_seq=dut.memwb_q.seq;
            pre_wb_pc=wb_pc;pre_wb_value=wb_data;pre_wb_rd=wb_rd;
            ri=retired;wi=wb_count;ti=traps;
            if(!mem_enable&&dut.exmem_valid_q)begin total_mem_wait=total_mem_wait+1;
                if(trap_fire||retire_fire)$fatal(1,"TRAP MEM enable ignored");end
            if(held&&(!dmem_req_valid||{dmem_req_write,dmem_req_addr,dmem_req_size,dmem_req_wdata,dmem_req_wstrb,dut.ram_req_seq}!==held_fields))
                $fatal(1,"TRAP changed irrevocable presented D request");
            held=dmem_req_valid&&!dmem_req_ready;
            held_fields={dmem_req_write,dmem_req_addr,dmem_req_size,dmem_req_wdata,dmem_req_wstrb,dut.ram_req_seq};
            if(held)total_held=total_held+1;
            if(dmem_req_valid)begin
                if(requests>=requests_expected||dut.ram_req_seq!==qseq[requests]||dmem_req_write!==qw[requests]||
                    dmem_req_addr!==qa[requests]||dmem_req_size!==qs[requests]||dmem_req_wdata!==qd[requests]||dmem_req_wstrb!==qst[requests])
                    $fatal(1,"TRAP unexpected D request mode=%0d case=%0d seq=%0d addr=%h wr=%b",MODE,case_no,dut.ram_req_seq,dmem_req_addr,dmem_req_write);
                if(pre_trap&&(!dut.ram_owner_valid||dut.ram_req_seq!==dut.ram_owner_seq))
                    $fatal(1,"TRAP newly presented younger D request");
                if(dmem_req_write&&(!dut.exmem_valid_q||dut.exmem_q.seq!==dut.ram_req_seq||!dut.exmem_q.is_store))
                    $fatal(1,"TRAP STORE not oldest MEM");
            end
            if(last_rsp)begin
                if(!bus_pending||dut.ram_rsp_seq!==bus_seq)$fatal(1,"TRAP D response owner mismatch");
                if(dut.ram_owner_killed)begin
                    total_killed_rsp=total_killed_rsp+1;
                    if(pre_trap)$fatal(1,"TRAP killed D error generated event");
                end
                $fdisplay(trace_fd,"response,%0d,%0d,%h,%h,%h,%b",case_no,cycles,bus_seq,bus_addr,dmem_rsp_rdata,dmem_rsp_error);
                bus_pending=0;responses=responses+1;total_responses=total_responses+1;
            end
            if(dmem_req_valid&&dmem_req_ready)begin
                if(bus_pending)$fatal(1,"TRAP multiple D owners");
                bus_pending=1;bus_store=dmem_req_write;bus_seq=dut.ram_req_seq;bus_addr=dmem_req_addr;
                if(bus_store)total_writes=total_writes+1;
                $fdisplay(trace_fd,"request,%0d,%0d,%h,%h,%h,%b",case_no,cycles,bus_seq,bus_addr,dmem_req_wdata,bus_store);
                requests=requests+1;total_requests=total_requests+1;
            end
            if(pre_wb)begin
                if(wi>=retired||dut.memwb_q.seq!==eseq[wi]||wb_pc!==epc[wi]||wb_rd!==erd[wi]||wb_data!==eval[wi]||pre_we!==(erd[wi]!=0))
                    $fatal(1,"TRAP WB stream mode=%0d case=%0d index=%0d seq=%0d data=%h/%h",MODE,case_no,wi,dut.memwb_q.seq,wb_data,eval[wi]);
                wb_count=wb_count+1;total_wb=total_wb+1;
                $fdisplay(trace_fd,"wb,%0d,%0d,%h,%h,%h,%b",case_no,cycles,dut.memwb_q.seq,wb_pc,wb_data,pre_we);
            end
            if(bp_commit_valid!==retire_fire)$fatal(1,"TRAP BP authorization mismatch");
            if(pre_trap)begin
                if(ti>=traps_expected||dut.exmem_q.seq!==tseq[ti]||dut.exmem_q.pc!==tpc[ti]||
                    pre_retire||bp_commit_valid||last_accept||!redirect_valid||!redirect_kill_ifid||
                    redirect_pc!==VECTOR||redirect_seq!==tseq[ti])
                    $fatal(1,"TRAP pre-edge owner/priority mode=%0d case=%0d event=%0d seq=%0d pc=%h redirect=%h",MODE,case_no,ti,dut.exmem_q.seq,dut.exmem_q.pc,redirect_pc);
                if(dut.ram_mem_error&&!dut.ram_completion_ready)$fatal(1,"TRAP fault source completion not acknowledged");
                if(pre_wb&&pre_we)total_wb_trap=total_wb_trap+1;
                if(dut.memwb_valid_q&&!wb_ready)total_wb_held_trap=total_wb_held_trap+1;
                arch_expected=VECTOR;saved_trap_seq=tseq[ti];saved_trap_pc=tpc[ti];
                saved_trap_cause=tcause[ti];saved_trap_tval=ttval[ti];
                traps=traps+1;total_traps=total_traps+1;
                $fdisplay(trace_fd,"trap,%0d,%0d,%h,%h,%h,%h",case_no,cycles,tseq[ti],tpc[ti],tcause[ti],ttval[ti]);
            end else if(redirect_valid)begin
                if(redirects>=expected_redirects||redirect_seq!==rseq[redirects]||redirect_pc!==rpc[redirects])
                    $fatal(1,"TRAP younger redirect escaped mode=%0d case=%0d seq=%0d pc=%h",MODE,case_no,redirect_seq,redirect_pc);
                redirects=redirects+1;total_redirects=total_redirects+1;
            end
            if(pre_retire)begin
                if(ri>=expected||dut.exmem_q.seq!==eseq[ri]||bp_commit_seq!==eseq[ri]||bp_commit_pc!==epc[ri])
                    $fatal(1,"TRAP fault or killed token retired mode=%0d case=%0d index=%0d seq=%0d",MODE,case_no,ri,dut.exmem_q.seq);
                if(dut.ram_owner_valid&&dut.ram_owner_killed)total_handler_drain_retire=total_handler_drain_retire+1;
                arch_expected=enext[ri];
            end
            #1;
            if(trap_valid!==pre_trap||retire_valid!==pre_retire)$fatal(1,"TRAP registered event mismatch");
            if(pre_trap&&pre_wb_hold&&(!dut.memwb_valid_q||dut.memwb_q.seq!==pre_wb_seq||
                wb_pc!==pre_wb_pc||wb_data!==pre_wb_value||wb_rd!==pre_wb_rd))
                $fatal(1,"TRAP destroyed held retired WB token");
            if(trap_seq!==saved_trap_seq||trap_pc!==saved_trap_pc||trap_cause!==saved_trap_cause||trap_tval!==saved_trap_tval)
                $fatal(1,"TRAP registered/persistent descriptor mode=%0d case=%0d seq=%0d pc=%h cause=%0d tval=%h",MODE,case_no,trap_seq,trap_pc,trap_cause,trap_tval);
            if(pre_retire)begin
                if(retire_seq!==eseq[ri]||retire_pc!==epc[ri]||retire_instr!==eins[ri]||retire_rd!==erd[ri]||
                    retire_value!==eval[ri]||retire_writes_rd!==(erd[ri]!=0))
                    $fatal(1,"TRAP normal retirement payload mode=%0d case=%0d index=%0d seq=%0d value=%h/%h",MODE,case_no,ri,retire_seq,retire_value,eval[ri]);
                retired=retired+1;total_retired=total_retired+1;
                $fdisplay(trace_fd,"retire,%0d,%0d,%h,%h,%h,%b",case_no,cycles,retire_seq,retire_pc,retire_value,retire_writes_rd);
            end
            if(instret_count!==retired||arch_next_pc_q!==arch_expected)$fatal(1,"TRAP instret/arch-next-PC mismatch mode=%0d case=%0d",MODE,case_no);
        end
    end
    initial begin
        trace_fd=$fopen($sformatf("build/cpu5_s6_trap_control/mode%0d_trace.csv",MODE),"w");
        $fdisplay(trace_fd,"event,case,cycle,seq,pc_or_addr,value_or_cause,flag_or_tval");
        reset_case(1);expect_trap(1,'h200,11,0);send(1,'h200,32'h00000073,0);
        wait_traps(1);repeat(8)tick;handler_alu(4,7);finish_case;

        reset_case(2);expect_trap(1,'h204,3,'h204);send(1,'h204,32'h00100073,0);wait_traps(1);
        expect_trap(3,VECTOR,3,VECTOR);send(3,VECTOR,32'h00100073,1);wait_traps(2);handler_alu(6,8);finish_case;

        reset_case(3);expect_trap(1,'h208,2,32'hffffffff);send(1,'h208,32'hffffffff,0);wait_traps(1);handler_alu(3,9);finish_case;

        reset_case(4);expect_trap(1,'h20c,1,'hdead0000);in_fetch_error=1;in_fetch_tval='hdead0000;
        send(1,'h20c,load(5,0,2,0),0);@(negedge clk);in_fetch_error=0;
        wait_traps(1);if(dmem_fault||requests!=0)$fatal(1,"TRAP fetch fault became D access");handler_alu(3,10);finish_case;

        reset_case(5);expect_trap(1,'h210,0,'h212);send(1,'h210,jal(5,2),0);wait_traps(1);handler_alu(3,11);finish_case;

        for(stage=0;stage<4;stage=stage+1)begin
            reset_case(6+stage);init_base;
            case(stage)
                0:begin word=load(5,1,1,1);expect_trap(2,'h200,4,'h10001);end
                1:begin word=store(0,1,1,1);expect_trap(2,'h200,6,'h10001);end
                2:begin word=load(5,1,2,32);expect_trap(2,'h200,5,'h10020);end
                3:begin word=store(0,1,2,32);expect_trap(2,'h200,7,'h10020);end
            endcase
            send(2,'h200,word,0);wait_traps(1);handler_alu(5,12+stage);finish_case;
        end

        reset_case(10);init_base;
        expect_trap(2,'h200,5,'h10000);expect_request(2,0,'h10000,2,0,0);
        send(2,'h200,load(5,1,2,0),0);wait_requests(1);
        send(3,'h204,store(0,1,2,4),0);respond('hdeadbeef,1);wait_traps(1);
        expect_alu(6,VECTOR,load(7,1,2,4),7,'h12345678);expect_request(6,0,'h10004,2,0,0);
        send(6,VECTOR,load(7,1,2,4),9);wait_requests(2);respond('h12345678,0);finish_case;

        reset_case(11);init_base;
        expect_alu(2,'h84,addi(2,0,'h55),2,'h55);send(2,'h84,addi(2,0,'h55),0);repeat(3)tick;
        expect_trap(3,'h200,7,'h10000);expect_request(3,1,'h10000,2,'h55,15);
        send(3,'h200,store(2,1,2,0),0);wait_requests(1);respond(0,1);wait_traps(1);
        expect_alu(6,VECTOR,load(7,1,2,0),7,'h55);expect_request(6,0,'h10000,2,0,0);
        send(6,VECTOR,load(7,1,2,0),9);wait_requests(2);respond('h55,0);finish_case;

        reset_case(12);wb_ready=0;
        expect_alu(1,'h80,addi(5,0,7),5,7);send(1,'h80,addi(5,0,7),0);repeat(2)tick;
        expect_trap(2,'h200,11,0);send(2,'h200,32'h00000073,0);wait_traps(1);
        expect_alu(4,VECTOR,addi(7,5,1),7,8);send(4,VECTOR,addi(7,5,1),3);repeat(4)tick;
        if(retired!=1||wb_count!=0||traps!=1)$fatal(1,"TRAP was incorrectly tied to WB space");
        @(negedge clk);wb_ready=1;finish_case;

        reset_case(13);wb_ready=0;
        expect_alu(1,'h80,addi(5,0,7),5,7);send(1,'h80,addi(5,0,7),0);repeat(2)tick;
        mem_enable=0;expect_trap(2,'h200,11,0);send(2,'h200,32'h00000073,0);repeat(3)tick;
        @(negedge clk);mem_enable=1;wb_ready=1;#1;
        if(!trap_fire||!wb_fire||!wb_we||wb_data!=7)$fatal(1,"TRAP old WB simultaneous write absent");
        tick;handler_alu(4,17);finish_case;

        reset_case(14);mem_enable=0;expect_trap(1,'h200,11,0);send(1,'h200,32'h00000073,0);
        if(MODE)offer(2,'h204,addi(5,0,77),0);
        else begin send(2,'h204,addi(5,0,77),0);offer(3,'h208,jal(6,16),1);end
        repeat(5)begin #1;if(trap_fire||retire_fire||redirect_valid||dmem_req_valid)$fatal(1,"TRAP stalled MEM fault lost priority");tick;end
        @(negedge clk);mem_enable=1;#1;if(!trap_fire||in_ready)$fatal(1,"TRAP young ID admission on fault edge");
        tick;handler_alu(5,18);finish_case;

        reset_case(15);init_base;mem_enable=0;expect_trap(2,'h200,11,0);send(2,'h200,32'h00000073,0);
        if(MODE)offer(3,'h204,store(0,1,2,0),0);
        else begin send(3,'h204,store(0,1,2,0),0);offer(4,'h208,jal(6,16),1);end
        @(negedge clk);mem_enable=1;tick;wait_traps(1);handler_alu(6,19);finish_case;

        reset_case(16);expect_alu(1,'h80,addi(5,0,9),5,9);send(1,'h80,addi(5,0,9),0);repeat(3)tick;
        mem_enable=0;expect_trap(2,'h200,11,0);send(2,'h200,32'h00000073,0);
        if(MODE)offer(3,'h204,addi(5,0,77),0);else send(3,'h204,addi(5,0,77),0);
        @(negedge clk);mem_enable=1;tick;wait_traps(1);
        expect_alu(5,VECTOR,addi(6,5,1),6,10);send(5,VECTOR,addi(6,5,1),9);finish_case;

        // Since LOAD allocation is bound to its EX->MEM move, an older MEM
        // fault blocks a fresh young request. First cancel an existing LOAD
        // through the public flush interface, then trap while it still drains.
        for(stage=0;stage<2;stage=stage+1)begin
            reset_case(17+stage);init_base;dmem_req_ready=stage;
            expect_request(2,0,'h10000,2,0,0);send(2,'h84,load(5,1,2,0),0);
            if(stage)wait_requests(1);else wait_present;
            flush_load(2);expect_trap(4,'h200,11,0);send(4,'h200,32'h00000073,1);wait_traps(1);
            handler_alu(6,20+stage);repeat(4)tick;
            if(retired!=2||!dut.ram_owner_valid||!dut.ram_owner_killed)$fatal(1,"TRAP handler ALU could not progress during killed D drain");
            expect_alu(7,VECTOR+4,load(8,1,2,4),8,'h87654321);expect_request(7,0,'h10004,2,0,0);
            send(7,VECTOR+4,load(8,1,2,4),8'hff);repeat(3)tick;
            if(requests>stage||retired!=2)$fatal(1,"TRAP handler LOAD stole old owner");
            @(negedge clk);dmem_req_ready=1;wait_requests(1);respond('hdeadbeef,1);
            wait_requests(2);respond('h87654321,0);finish_case;
        end

        reset_case(19);init_base;expect_trap(2,'h200,5,'h10000);expect_request(2,0,'h10000,2,0,0);
        send(2,'h200,load(5,1,2,0),0);wait_requests(1);
        if(MODE)expect_redirect(3,'h214);
        send(3,'h204,jal(6,16),0);@(negedge clk);in_epoch=8'hff;repeat(3)tick;
        if(dut.ram_owner_killed)$fatal(1,"TRAP fetch epoch killed live older D owner");
        respond(0,1);wait_traps(1);handler_alu(6,23);finish_case;

        reset_case(20);expect_trap(1,'h200,11,0);send(1,'h200,32'h00000073,0);wait_traps(1);finish_case;
        // reset_case checks that a previously nonzero persistent descriptor is
        // cleared, not merely that the event pulse is low.
        reset_case(21);expect_alu(1,VECTOR,addi(7,0,24),7,24);send(1,VECTOR,addi(7,0,24),0);finish_case;

        reset_case(22);expect_trap(1,'h200,2,32'h001000f3);send(1,'h200,32'h001000f3,0);wait_traps(1);handler_alu(3,25);finish_case;

        reset_case(23);init_base;expect_trap(2,'h200,5,'h10000);expect_request(2,0,'h10000,2,0,0);
        send(2,'h200,load(0,1,2,0),0);wait_requests(1);respond('hdeadbeef,1);wait_traps(1);handler_alu(4,26);finish_case;

        reset_case(24);expect_alu(64'hffffffff,'h80,addi(5,0,9),5,9);
        send(64'hffffffff,'h80,addi(5,0,9),0);repeat(3)tick;
        mem_enable=0;expect_trap(64'h100000000,'h200,11,0);send(64'h100000000,'h200,32'h00000073,0);
        if(MODE)offer(64'h100000001,'h204,addi(5,0,77),0);else send(64'h100000001,'h204,addi(5,0,77),0);@(negedge clk);mem_enable=1;tick;wait_traps(1);
        expect_alu(64'h100000004,VECTOR,addi(6,5,1),6,10);send(64'h100000004,VECTOR,addi(6,5,1),9);finish_case;

        // A response can be accepted while architectural MEM delivery is held.
        // The cached LOAD/STORE error must retain its source until Trap takes it.
        for(stage=0;stage<2;stage=stage+1)begin
            reset_case(25+stage);init_base;
            expect_trap(2,'h200,stage?7:5,'h10000);
            expect_request(2,stage,'h10000,2,0,stage?15:0);
            word=stage?store(0,1,2,0):load(5,1,2,0);
            send(2,'h200,word,0);wait_requests(1);
            @(negedge clk);mem_enable=0;respond('hdeadbeef,1);repeat(4)tick;
            if(traps!=0||!dut.ram_owner_valid||dut.ram_owner_killed||
               !dut.ram_completion_valid||!dut.ram_completion_error||dut.ram_completion_ready)
                $fatal(1,"TRAP cached source error lost while MEM disabled");
            @(negedge clk);mem_enable=1;wait_traps(1);
            if(dut.ram_owner_valid)$fatal(1,"TRAP cached source error owner not released");
            handler_alu(4,27+stage);finish_case;
        end

        // The older LOAD response and a younger ID JAL are presented together.
        // No ID admission or young redirect is allowed on this error edge.
        reset_case(27);init_base;
        expect_trap(2,'h200,5,'h10000);expect_request(2,0,'h10000,2,0,0);
        send(2,'h200,load(5,1,2,0),0);wait_requests(1);
        @(negedge clk);in_valid=1;in_seq=3;in_pc='h204;in_instr=jal(6,16);
        in_pred_next_pc='h208;in_epoch=8'hff;dmem_rsp_valid=1;dmem_rsp_rdata=0;dmem_rsp_error=1;
        #1;if(in_ready||!trap_fire||redirect_pc!==VECTOR||redirect_seq!==2)
            $fatal(1,"TRAP same-edge LOAD error lost to young ID redirect");
        tick;@(negedge clk);dmem_rsp_valid=0;dmem_rsp_error=0;
        wait_traps(1);handler_alu(5,29);finish_case;

        if(passed!=27||total_traps!=27||total_held==0||total_killed_rsp!=2||total_wb_trap==0||
            total_wb_held_trap==0||total_mem_wait==0||total_handler_drain_retire<2)
            $fatal(1,"TRAP coverage mode=%0d cases=%0d traps=%0d held=%0d killed=%0d simultaneousWB=%0d heldWB=%0d memwait=%0d handlerdrain=%0d",MODE,passed,total_traps,total_held,total_killed_rsp,total_wb_trap,total_wb_held_trap,total_mem_wait,total_handler_drain_retire);
        summary_fd=$fopen($sformatf("build/cpu5_s6_trap_control/mode%0d_summary.json",MODE),"w");
        $fdisplay(summary_fd,"{\"pass\":true,\"mode\":%0d,\"cases\":%0d,\"traps\":%0d,\"retired\":%0d,\"wb\":%0d,\"requests\":%0d,\"responses\":%0d,\"store_requests\":%0d,\"held_edges\":%0d,\"killed_error_responses\":%0d,\"trap_with_old_wb_write\":%0d,\"trap_with_held_wb\":%0d,\"mem_wait_edges\":%0d,\"handler_retire_during_drain\":%0d,\"young_redirects_before_trap\":%0d}",
            MODE,passed,total_traps,total_retired,total_wb,total_requests,total_responses,total_writes,total_held,total_killed_rsp,total_wb_trap,total_wb_held_trap,total_mem_wait,total_handler_drain_retire,total_redirects);
        $fclose(summary_fd);$fclose(trace_fd);done=1;
    end
endmodule
module cpu5_trap_control_tb;
    wire [1:0] done;reg test_pass=0;
    cpu5_trap_control_case #(.MODE(0)) ex_mode(done[0]);
    cpu5_trap_control_case #(.MODE(1)) id_mode(done[1]);
    initial begin wait(&done);test_pass=1;$display("CPU5 TRAP CONTROL TEST PASS");$stop;end
    initial begin #200000;$fatal(1,"CPU5 Trap control timeout");end
endmodule
