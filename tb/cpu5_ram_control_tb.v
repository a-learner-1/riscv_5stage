`timescale 1ns/1ps
// Hand-authored dynamic streams and expected architecture. The external
// endpoint and bus ledger are independent of the DUT owner. No internal force.
module cpu5_ram_control_case #(parameter integer MODE=0)(output reg done=0);
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,in_valid=0,in_fetch_error=0;
    reg [31:0] in_pc=0,in_instr=0,in_pred_next_pc=0,in_fetch_tval=0;
    reg in_pred_taken=0,in_pred_hit=0;
    reg [63:0] in_seq=0,flush_cut_seq=0;
    reg [7:0] in_epoch=0;
    reg id_enable=1,ex_enable=1,mem_enable=1,wb_ready=1,flush_valid=0;
    wire in_ready,ex_valid,wb_we,retire_valid,retire_writes_rd;
    wire [31:0] ex_pc,ex_instr,wb_pc,wb_data,retire_pc,retire_instr,retire_value,arch_next_pc_q;
    wire [4:0] wb_rd,retire_rd;
    wire [63:0] retire_seq,cycle_count,instret_count;
    wire halted,halt_fetch_error,id_raw_wait,retire_fire,wb_fire,flush_ready,flush_fire;
    wire [31:0] halt_pc,halt_instr,halt_cause,halt_tval;wire [63:0] halt_seq;
    wire redirect_valid,redirect_kill_ifid;wire [31:0] redirect_pc;wire [63:0] redirect_seq;
    wire bp_commit_valid,bp_commit_taken,bp_commit_is_branch,bp_commit_is_jal;
    wire [63:0] bp_commit_seq;wire [31:0] bp_commit_pc,bp_commit_target;
    wire [31:0] bp_resolved_count,bp_mispredict_count,bp_direction_error_count,bp_target_error_count;
    wire dmem_req_valid,dmem_req_write,dmem_rsp_ready,dmem_fault;
    reg dmem_req_ready=1,dmem_rsp_valid=0,dmem_rsp_error=0;
    wire [31:0] dmem_req_addr,dmem_req_wdata;wire [1:0] dmem_req_size;wire [3:0] dmem_req_wstrb;
    reg [31:0] dmem_rsp_rdata=0;
    cpu5_alu_pipeline #(.ENABLE_FORWARDING(1),.ENABLE_CONTROL_FLOW(1),
        .BRANCH_RESOLVE_IN_ID(MODE),.ENABLE_BRANCH_PRED(1),.ENABLE_RAM(1),.DMEM_WORDS(8)) dut(.irq_external(1'b0),.irq_software(1'b0),.irq_timer(1'b0),.trap_fire(),.trap_valid(),.trap_pc(),.trap_cause(),.trap_tval(),.trap_seq(),.*);
    reg [63:0] eseq[0:31],qseq[0:15],rseq[0:7];
    reg [31:0] epc[0:31],eins[0:31],eval[0:31],enext[0:31],rpc[0:7];
    reg [4:0] erd[0:31];
    reg [31:0] qa[0:15],qd[0:15];reg [1:0] qs[0:15];reg [3:0] qst[0:15];reg qw[0:15];
    reg [31:0] ram[0:7];
    integer expected=0,retired=0,wb_count=0,requests_expected=0,requests=0,responses=0;
    integer expected_redirects=0,redirects=0,case_no=0,passed=0,timeout=0;
    integer cycles=0,trace_fd,summary_fd,i,j,stage,ri,wi;
    integer total_retired=0,total_wb=0,total_requests=0,total_responses=0,total_writes=0;
    integer total_held=0,total_raw=0,total_redirects=0,total_turnover=0,total_killed_rsp=0,total_flush_reject=0;
    reg last_accept=0,last_rsp=0,last_flush=0,pre_retire,pre_wb,pre_we;
    reg [63:0] last_accept_seq=0;
    reg bus_pending=0,bus_store=0;
    reg [63:0] bus_seq=0;reg [31:0] bus_addr=0;
    reg held=0;reg [134:0] held_fields=0;
    reg [31:0] word;
    function [31:0] addi(input [4:0] d,input [4:0] s,input integer v);
        begin addi={v[11:0],s,3'b000,d,7'h13};end
    endfunction
    function [31:0] load(input [4:0] d,input [4:0] s,input [2:0] f,input integer v);
        begin load={v[11:0],s,f,d,7'h03};end
    endfunction
    function [31:0] store(input [4:0] s2,input [4:0] s1,input [2:0] f,input integer v);
        begin store={v[11:5],s2,s1,f,v[4:0],7'h23};end
    endfunction
    function [31:0] beq(input [4:0] s1,input [4:0] s2,input integer v);
        begin beq={v[12],v[10:5],s2,s1,3'b000,v[4:1],v[11],7'h63};end
    endfunction
    function [31:0] jal(input [4:0] d,input integer v);
        begin jal={v[20],v[10:1],v[11],v[19:12],d,7'h6f};end
    endfunction
    task tick;
        begin @(posedge clk);#2;if(last_accept && last_accept_seq==in_seq)in_valid=0;end
    endtask
    task reset_case(input integer n);
        begin
            @(negedge clk);rst_n=0;in_valid=0;in_fetch_error=0;in_pred_taken=0;in_pred_hit=0;
            in_epoch=0;id_enable=1;ex_enable=1;mem_enable=1;wb_ready=1;flush_valid=0;
            dmem_req_ready=1;dmem_rsp_valid=0;dmem_rsp_error=0;
            case_no=n;expected=0;requests_expected=0;expected_redirects=0;
            for(i=0;i<8;i=i+1)ram[i]=32'h55550000+i;
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
                if(timeout>80)$fatal(1,"RAM ID timeout mode=%0d case=%0d seq=%0d",MODE,case_no,seq);end
        end
    endtask
    task wait_requests(input integer n);
        begin timeout=0;while(requests<n)begin tick;timeout=timeout+1;
            if(timeout>80)$fatal(1,"RAM request timeout mode=%0d case=%0d requests=%0d/%0d",MODE,case_no,requests,n);end end
    endtask
    task wait_present;
        begin timeout=0;while(!dmem_req_valid)begin tick;timeout=timeout+1;
            if(timeout>80)$fatal(1,"RAM present timeout mode=%0d case=%0d",MODE,case_no);end
            // Observe a complete acceptance edge with READY low: only then
            // has the source captured the held descriptor under test.
            tick;
        end
    endtask
    task respond(input [31:0] data,input error);
        begin @(negedge clk);dmem_rsp_valid=1;dmem_rsp_rdata=data;dmem_rsp_error=error;timeout=0;tick;
            while(!last_rsp)begin tick;timeout=timeout+1;if(timeout>80)$fatal(1,"RAM response timeout");end
            @(negedge clk);dmem_rsp_valid=0;dmem_rsp_error=0;
        end
    endtask
    task flush_load(input [63:0] cut);
        begin @(negedge clk);flush_valid=1;flush_cut_seq=cut;in_valid=0;#1;
            if(!flush_ready||!flush_fire)$fatal(1,"cancelable LOAD flush rejected");
            tick;@(negedge clk);flush_valid=0;end
    endtask
    task init_base;
        begin expect_alu(1,'h100,32'h000100b7,1,'h10000);send(1,'h100,32'h000100b7,0);
            repeat(3)tick;end
    endtask
    task finish_case;
        begin in_valid=0;timeout=0;
            while(retired!=expected || wb_count!=expected || dut.idex_valid_q || dut.exmem_valid_q ||
                dut.memwb_valid_q || dut.ram_owner_valid || bus_pending)begin
                tick;timeout=timeout+1;if(timeout>100)$fatal(1,"RAM drain mode=%0d case=%0d retire=%0d/%0d wb=%0d req=%0d/%0d pending=%b",MODE,case_no,retired,expected,wb_count,requests,requests_expected,bus_pending);
            end
            repeat(2)tick;
            if(requests!=requests_expected||responses!=requests||redirects!=expected_redirects)
                $fatal(1,"RAM ledger not closed mode=%0d case=%0d req=%0d/%0d rsp=%0d redirects=%0d/%0d",MODE,case_no,requests,requests_expected,responses,redirects,expected_redirects);
            passed=passed+1;$display("CPU5_RAM_CONTROL_CASE_PASS mode=%0d case=%0d retired=%0d requests=%0d",MODE,case_no,retired,requests);
        end
    endtask
    task wait_halt(input [63:0] seq,input [31:0] pc,input [31:0] cause,input [31:0] tval);
        begin timeout=0;while(!halted)begin tick;timeout=timeout+1;if(timeout>50)$fatal(1,"RAM halt timeout");end
            if(halt_seq!==seq||halt_pc!==pc||halt_cause!==cause||halt_tval!==tval||halt_fetch_error)
                $fatal(1,"RAM halt descriptor mode=%0d case=%0d seq=%0d pc=%h cause=%0d tval=%h",MODE,case_no,halt_seq,halt_pc,halt_cause,halt_tval);
            repeat(3)begin if(retire_fire||redirect_valid)$fatal(1,"fault allowed younger action");tick;end
        end
    endtask
    always @(posedge clk)begin
        cycles=cycles+1;
        if(!rst_n)begin
            retired=0;wb_count=0;requests=0;responses=0;redirects=0;
            bus_pending=0;held=0;last_accept=0;last_rsp=0;last_flush=0;
            if(wb_we||retire_fire||dmem_req_valid||dmem_rsp_ready||redirect_valid)$fatal(1,"RAM reset side effect");
        end else begin
            last_accept=in_valid&&in_ready;last_accept_seq=in_seq;
            last_rsp=dmem_rsp_valid&&dmem_rsp_ready;last_flush=flush_fire;
            pre_retire=retire_fire;pre_wb=wb_fire;pre_we=wb_we;ri=retired;wi=wb_count;
            if(id_raw_wait||dut.ex_source_stall)total_raw=total_raw+1;
            if(flush_valid&&!flush_ready)total_flush_reject=total_flush_reject+1;
            if(held && (!dmem_req_valid || {dmem_req_write,dmem_req_addr,dmem_req_size,dmem_req_wdata,dmem_req_wstrb,dut.ram_req_seq}!==held_fields))
                $fatal(1,"RAM held request changed mode=%0d case=%0d",MODE,case_no);
            held=dmem_req_valid&&!dmem_req_ready;
            held_fields={dmem_req_write,dmem_req_addr,dmem_req_size,dmem_req_wdata,dmem_req_wstrb,dut.ram_req_seq};
            if(held)total_held=total_held+1;
            if(dmem_req_valid)begin
                if(requests>=requests_expected||dut.ram_req_seq!==qseq[requests]||dmem_req_write!==qw[requests]||
                    dmem_req_addr!==qa[requests]||dmem_req_size!==qs[requests]||dmem_req_wdata!==qd[requests]||dmem_req_wstrb!==qst[requests])
                    $fatal(1,"RAM request payload mode=%0d case=%0d index=%0d seq=%0d addr=%h wr=%b data=%h st=%h",MODE,case_no,requests,dut.ram_req_seq,dmem_req_addr,dmem_req_write,dmem_req_wdata,dmem_req_wstrb);
                if(dmem_req_write && (!dut.exmem_valid_q||!dut.exmem_q.is_store||dut.exmem_q.seq!==dut.ram_req_seq||halted))
                    $fatal(1,"STORE not authorized by oldest MEM");
                if(bus_pending&&bus_store)$fatal(1,"younger request passed unresolved STORE");
            end
            // Old response is checked before new request binds the endpoint.
            if(last_rsp)begin
                if(!bus_pending||dut.ram_rsp_seq!==bus_seq)$fatal(1,"RAM response owner mismatch");
                if(dut.ram_owner_killed)begin
                    total_killed_rsp=total_killed_rsp+1;
                    if(retire_fire||wb_we||bp_commit_valid||halted)$fatal(1,"killed response escaped drain");
                end
                $fdisplay(trace_fd,"response,%0d,%0d,%h,%h,%h,%b",case_no,cycles,bus_seq,bus_addr,dmem_rsp_rdata,dmem_rsp_error);
                bus_pending=0;responses=responses+1;total_responses=total_responses+1;
            end
            if(dmem_req_valid&&dmem_req_ready)begin
                if(bus_pending)$fatal(1,"RAM multiple outstanding endpoint transactions");
                if(last_rsp)begin
                    if(bus_store||dmem_rsp_error||dut.ram_owner_killed||dmem_req_write)$fatal(1,"forbidden RAM turnover");
                    if(dut.ram_rsp_seq==dut.ram_req_seq)$fatal(1,"turnover aliased owners");
                    total_turnover=total_turnover+1;
                end
                bus_pending=1;bus_store=dmem_req_write;bus_seq=dut.ram_req_seq;bus_addr=dmem_req_addr;
                if(dmem_req_write)begin
                    for(j=0;j<4;j=j+1)if(dmem_req_wstrb[j])ram[(dmem_req_addr-'h10000)/4][j*8+:8]=dmem_req_wdata[j*8+:8];
                    total_writes=total_writes+1;
                end
                $fdisplay(trace_fd,"request,%0d,%0d,%h,%h,%h,%b",case_no,cycles,bus_seq,bus_addr,dmem_req_wdata,dmem_req_write);
                requests=requests+1;total_requests=total_requests+1;
            end
            if(redirect_valid)begin
                if(redirects>=expected_redirects||redirect_seq!==rseq[redirects]||redirect_pc!==rpc[redirects])
                    $fatal(1,"RAM unexpected redirect mode=%0d case=%0d seq=%0d pc=%h",MODE,case_no,redirect_seq,redirect_pc);
                redirects=redirects+1;total_redirects=total_redirects+1;
            end
            if(bp_commit_valid!==retire_fire)$fatal(1,"RAM BP retirement authorization");
            if(pre_wb)begin
                if(wi>=retired||dut.memwb_q.seq!==eseq[wi]||wb_pc!==epc[wi]||wb_rd!==erd[wi]||wb_data!==eval[wi]||pre_we!==(erd[wi]!=0))
                    $fatal(1,"RAM WB stream mode=%0d case=%0d index=%0d seq=%0d data=%h/%h",MODE,case_no,wi,dut.memwb_q.seq,wb_data,eval[wi]);
                wb_count=wb_count+1;total_wb=total_wb+1;
            end
            if(pre_retire && (ri>=expected||dut.exmem_q.seq!==eseq[ri]||bp_commit_seq!==eseq[ri]||bp_commit_pc!==epc[ri]))
                $fatal(1,"RAM pre-edge retirement owner mode=%0d case=%0d index=%0d",MODE,case_no,ri);
            #1;
            if(retire_valid!==pre_retire)$fatal(1,"RAM registered retirement event");
            if(pre_retire)begin
                if(retire_seq!==eseq[ri]||retire_pc!==epc[ri]||retire_instr!==eins[ri]||retire_rd!==erd[ri]||
                    retire_value!==eval[ri]||retire_writes_rd!==(erd[ri]!=0)||arch_next_pc_q!==enext[ri])
                    $fatal(1,"RAM retirement stream mode=%0d case=%0d index=%0d seq=%0d rd=%0d val=%h/%h next=%h/%h",MODE,case_no,ri,retire_seq,retire_rd,retire_value,eval[ri],arch_next_pc_q,enext[ri]);
                $fdisplay(trace_fd,"retire,%0d,%0d,%h,%h,%h,%b",case_no,cycles,retire_seq,retire_pc,retire_value,retire_writes_rd);
                retired=retired+1;total_retired=total_retired+1;
            end
            if(instret_count!==retired)$fatal(1,"RAM instret mismatch");
        end
    end
    initial begin
        trace_fd=$fopen($sformatf("build/cpu5_s5_ram_control/mode%0d_trace.csv",MODE),"w");
        $fdisplay(trace_fd,"event,case,cycle,seq,pc_or_addr,value,flag");
        reset_case(1);init_base;
        expect_alu(2,'h104,load(5,1,2,0),5,'h12345678);expect_request(2,0,'h10000,2,0,0);
        send(2,'h104,load(5,1,2,0),0);wait_requests(1);
        expect_alu(3,'h108,addi(6,5,1),6,'h12345679);send(3,'h108,addi(6,5,1),0);
        repeat(4)tick;if(retired!=1||!dut.ex_source_stall)$fatal(1,"real load-use did not wait");
        respond('h12345678,0);finish_case;

        reset_case(2);init_base;
        expect_alu(2,'h104,load(5,1,2,0),5,0);expect_request(2,0,'h10000,2,0,0);
        send(2,'h104,load(5,1,2,0),0);wait_requests(1);
        word=beq(5,0,8);expect_packet(3,'h108,word,0,0,'h110);expect_redirect(3,'h110);
        offer(3,'h108,word,0);repeat(4)tick;
        if(MODE&&(!id_raw_wait||!in_valid))$fatal(1,"real ID branch load-use did not wait");
        respond(0,0);repeat(4)tick;finish_case;

        // MEM authorization and conservative same/different-address SW ordering.
        for(stage=0;stage<2;stage=stage+1)begin
            reset_case(3+stage);init_base;
            expect_alu(2,'h104,addi(2,0,'h55),2,'h55);send(2,'h104,addi(2,0,'h55),0);repeat(3)tick;
            @(negedge clk);mem_enable=0;dmem_req_ready=0;
            expect_alu(3,'h108,store(2,1,2,0),0,0);expect_request(3,1,'h10000,2,'h55,15);
            send(3,'h108,store(2,1,2,0),0);
            expect_alu(4,'h10c,load(5,1,2,stage*4),5,stage?'haabbccdd:'h55);
            expect_request(4,0,'h10000+stage*4,2,0,0);send(4,'h10c,load(5,1,2,stage*4),0);
            repeat(3)begin if(dmem_req_valid)$fatal(1,"STORE presented before MEM authorization");tick;end
            @(negedge clk);mem_enable=1;wait_present;repeat(4)tick;
            @(negedge clk);in_epoch=8'hff;dmem_req_ready=1;wait_requests(1);
            repeat(3)begin if(dmem_req_valid)$fatal(1,"younger LOAD passed STORE");tick;end
            respond(0,0);wait_requests(2);ram[1]='haabbccdd;respond(ram[stage],0);finish_case;
        end

        reset_case(5);init_base;
        expect_alu(2,'h104,addi(2,0,'h80),2,'h80);send(2,'h104,addi(2,0,'h80),0);
        expect_alu(3,'h108,store(2,1,0,3),0,0);expect_request(3,1,'h10003,0,'h80000000,8);
        send(3,'h108,store(2,1,0,3),0);wait_requests(1);respond(0,0);
        expect_alu(4,'h10c,load(5,1,0,3),5,'hffffff80);expect_request(4,0,'h10003,0,0,0);
        send(4,'h10c,load(5,1,0,3),0);wait_requests(2);respond(ram[0],0);finish_case;

        reset_case(6);init_base;
        expect_alu(2,'h104,32'hffff8137,2,'hffff8000);send(2,'h104,32'hffff8137,0);
        expect_alu(3,'h108,store(2,1,1,2),0,0);expect_request(3,1,'h10002,1,'h80000000,12);
        send(3,'h108,store(2,1,1,2),0);wait_requests(1);respond(0,0);
        expect_alu(4,'h10c,load(5,1,1,2),5,'hffff8000);expect_request(4,0,'h10002,1,0,0);
        send(4,'h10c,load(5,1,1,2),0);wait_requests(2);respond(ram[0],0);
        expect_alu(5,'h110,load(6,1,5,2),6,'h8000);expect_request(5,0,'h10002,1,0,0);
        send(5,'h110,load(6,1,5,2),0);wait_requests(3);respond(ram[0],0);finish_case;

        reset_case(7);init_base;
        expect_alu(2,'h104,load(0,1,2,0),0,'h87654321);expect_request(2,0,'h10000,2,0,0);
        send(2,'h104,load(0,1,2,0),0);wait_requests(1);respond('h87654321,0);
        expect_alu(3,'h108,addi(6,0,1),6,1);send(3,'h108,addi(6,0,1),0);finish_case;

        // Cancellation before and after acceptance still sends/drains exactly
        // once. Error responses from killed LOADs produce no architecture.
        for(stage=0;stage<2;stage=stage+1)begin
            reset_case(8+stage);init_base;dmem_req_ready=stage;
            expect_request(2,0,'h10000,2,0,0);send(2,'h104,load(5,1,2,0),0);
            if(stage)wait_requests(1);else wait_present;
            flush_load(2);repeat(2)tick;
            @(negedge clk);dmem_req_ready=1;wait_requests(1);respond('hdeadbeef,1);
            expect_alu(5,'h200,addi(6,0,9),6,9);send(5,'h200,addi(6,0,9),7);finish_case;
        end

        // Invalid f3, alignment and whitelist failures issue no D request and
        // stop at MEM. This is a halt-only subset, never a fabricated trap.
        for(stage=0;stage<5;stage=stage+1)begin
            reset_case(10+stage);init_base;
            case(stage)
                0:word=load(5,1,3,0);
                1:word=load(5,1,1,1);
                2:word=store(0,1,1,1);
                3:word=load(5,1,2,32);
                4:word=store(0,1,2,32);
            endcase
            send(2,'h104,word,0);
            if(stage==0)begin repeat(3)tick;if(!halted||halt_seq!=2||requests!=0)$fatal(1,"invalid width did not halt safely");end
            else wait_halt(2,'h104,stage==1?4:stage==2?6:stage==3?5:7,stage<3?'h10001:'h10020);
            flush_load(2);finish_case;
        end

        reset_case(15);init_base;
        expect_request(2,0,'h10000,2,0,0);send(2,'h104,load(5,1,2,0),0);wait_requests(1);
        offer(3,'h108,jal(6,16),1);dmem_rsp_valid=1;dmem_rsp_error=1;dmem_rsp_rdata=0;#1;
        if(redirect_valid||retire_fire)$fatal(1,"older LOAD error lost same-edge priority");
        tick;@(negedge clk);in_valid=0;dmem_rsp_valid=0;dmem_rsp_error=0;
        wait_halt(2,'h104,5,'h10000);flush_load(2);finish_case;

        for(stage=0;stage<2;stage=stage+1)begin
            reset_case(16+stage);init_base;
            expect_request(2,0,'h10000,2,0,0);
            if(!stage)expect_alu(2,'h104,load(5,1,2,0),5,'h13579bdf);
            send(2,'h104,load(5,1,2,0),0);wait_requests(1);
            if(!stage)begin expect_packet(3,'h108,jal(6,16),6,'h10c,'h118);expect_redirect(3,'h118);end
            else if(MODE)expect_redirect(3,'h118);
            send(3,'h108,jal(6,16),0);@(negedge clk);in_epoch=8'hff;repeat(3)tick;
            if(dut.ram_owner_killed)$fatal(1,"fetch epoch killed older LOAD owner");
            if(MODE&&redirects!=1)$fatal(1,"ID redirect not exercised while LOAD outstanding");
            respond('h13579bdf,stage);
            if(stage)begin wait_halt(2,'h104,5,'h10000);flush_load(2);end
            finish_case;
        end

        reset_case(18);init_base;
        expect_alu(2,'h104,load(5,1,2,0),5,'h11223344);expect_request(2,0,'h10000,2,0,0);
        send(2,'h104,load(5,1,2,0),0);wait_requests(1);
        expect_alu(3,'h108,load(6,1,2,4),6,'ha1b2c3d4);expect_request(3,0,'h10004,2,0,0);
        send(3,'h108,load(6,1,2,4),0);repeat(2)tick;
        @(negedge clk);dmem_rsp_valid=1;dmem_rsp_rdata='h11223344;dmem_rsp_error=0;#1;
        if(!dmem_req_valid||!dmem_req_ready||!dmem_rsp_ready||dut.ram_req_seq!=3||dut.ram_rsp_seq!=2)
            $fatal(1,"successful LOAD-to-LOAD same-edge handoff absent mode=%0d",MODE);
        tick;@(negedge clk);dmem_rsp_valid=0;respond('ha1b2c3d4,0);finish_case;

        reset_case(19);init_base;wb_ready=0;
        expect_alu(2,'h104,addi(5,0,9),5,9);send(2,'h104,addi(5,0,9),0);repeat(2)tick;
        expect_alu(3,'h108,load(5,1,2,0),5,41);expect_request(3,0,'h10000,2,0,0);
        send(3,'h108,load(5,1,2,0),0);wait_requests(1);
        expect_alu(4,'h10c,addi(6,5,1),6,42);send(4,'h10c,addi(6,5,1),0);repeat(3)tick;
        if(!dut.ex_source_stall)$fatal(1,"unready newest LOAD fell back to old WB");
        respond(41,0);repeat(3)tick;if(retired!=2)$fatal(1,"WB backpressure ignored");
        @(negedge clk);wb_ready=1;finish_case;

        // A flush that covers irrevocable STORE is retained by its caller.
        // Test starting the flush in PRESENTED, ACCEPTED and COMPLETE states.
        for(stage=0;stage<3;stage=stage+1)begin
            reset_case(20+stage);init_base;
            expect_alu(2,'h104,addi(2,0,'h66),2,'h66);send(2,'h104,addi(2,0,'h66),0);repeat(3)tick;
            dmem_req_ready=stage!=0;
            expect_alu(3,'h108,store(2,1,2,0),0,0);expect_request(3,1,'h10000,2,'h66,15);
            send(3,'h108,store(2,1,2,0),0);
            if(stage==0)wait_present;else wait_requests(1);
            if(stage==2)begin @(negedge clk);mem_enable=0;respond(0,0);end
            @(negedge clk);flush_valid=1;flush_cut_seq=3;
            repeat(3)begin #1;if(flush_ready||flush_fire)$fatal(1,"irrevocable STORE flush accepted early stage=%0d",stage);tick;end
            if(stage==0)begin @(negedge clk);dmem_req_ready=1;wait_requests(1);end
            if(stage!=2)begin @(negedge clk);mem_enable=0;respond(0,0);end
            repeat(3)begin #1;if(flush_ready||flush_fire||retire_fire)$fatal(1,"STORE COMPLETE lock lost");tick;end
            @(negedge clk);mem_enable=1;tick;
            if(retired!=3)$fatal(1,"irrevocable STORE did not retire before flush");
            tick;if(!last_flush)$fatal(1,"retained STORE flush not accepted after retirement");
            @(negedge clk);flush_valid=0;finish_case;
        end
        // An old unsupported MEM packet must block either kind of younger
        // memory request. No trap is claimed for the EBREAK sentinel.
        for(stage=0;stage<2;stage=stage+1)begin
            reset_case(23+stage);init_base;
            send(2,'h104,32'h00100073,0);
            offer(3,'h108,stage?store(0,1,2,0):load(5,1,2,0),0);
            repeat(6)begin
                if(dmem_req_valid||retire_fire||redirect_valid)$fatal(1,"old MEM fault allowed younger memory action");
                tick;
            end
            if(!halted||halt_seq!=2||requests!=0)$fatal(1,"old MEM fault lost ownership");
            flush_load(2);finish_case;
        end
        // A fetch-error packet whose returned bits resemble LOAD must retain
        // its I classification. Its address calculation never authorizes D.
        reset_case(25);init_base;
        @(negedge clk);in_fetch_error=1;in_fetch_tval='h104;
        send(2,'h104,load(5,1,2,0),0);
        @(negedge clk);in_fetch_error=0;repeat(4)tick;
        if(!halted||!halt_fetch_error||halt_cause!=1||halt_tval!='h104||dmem_fault||requests!=0)
            $fatal(1,"fetch error misclassified as D fault");
        flush_load(2);finish_case;
        if(passed!=25||total_held==0||total_raw==0||total_turnover==0||total_killed_rsp!=2||total_flush_reject==0)
            $fatal(1,"RAM control coverage mode=%0d passed=%0d held=%0d raw=%0d turnover=%0d killed=%0d flush=%0d",MODE,passed,total_held,total_raw,total_turnover,total_killed_rsp,total_flush_reject);
        summary_fd=$fopen($sformatf("build/cpu5_s5_ram_control/mode%0d_summary.json",MODE),"w");
        $fdisplay(summary_fd,"{\"pass\":true,\"mode\":%0d,\"cases\":%0d,\"retired\":%0d,\"wb\":%0d,\"requests\":%0d,\"responses\":%0d,\"writes\":%0d,\"held_edges\":%0d,\"raw_edges\":%0d,\"redirects\":%0d,\"load_turnovers\":%0d,\"killed_error_responses\":%0d,\"flush_rejected_edges\":%0d}",
            MODE,passed,total_retired,total_wb,total_requests,total_responses,total_writes,total_held,total_raw,total_redirects,total_turnover,total_killed_rsp,total_flush_reject);
        $fclose(summary_fd);$fclose(trace_fd);done=1;
    end
endmodule
module cpu5_ram_control_tb;
    wire [1:0] done;reg test_pass=0;
    cpu5_ram_control_case #(.MODE(0)) ex_mode(done[0]);
    cpu5_ram_control_case #(.MODE(1)) id_mode(done[1]);
    initial begin wait(&done);test_pass=1;$display("CPU5 RAM CONTROL TEST PASS");$stop;end
    initial begin #200000;$fatal(1,"CPU5 RAM control timeout");end
endmodule
