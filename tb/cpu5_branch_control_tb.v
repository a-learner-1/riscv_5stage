`timescale 1ns/1ps
// Hand-authored packet streams. Artificial result_ready forcing below models
// an unavailable producer only; it does not claim LOAD execution is present.
module cpu5_branch_control_case #(parameter integer MODE=0)(output reg done=0);
    reg clk=0; always #5 clk=~clk;
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
    wire halted,halt_fetch_error,id_raw_wait,retire_fire,wb_fire;
    wire [31:0] halt_pc,halt_instr,halt_cause,halt_tval;
    wire [63:0] halt_seq;
    wire redirect_valid,redirect_kill_ifid;
    wire [31:0] redirect_pc;
    wire [63:0] redirect_seq;
    wire bp_commit_valid,bp_commit_taken,bp_commit_is_branch,bp_commit_is_jal;
    wire [63:0] bp_commit_seq;
    wire [31:0] bp_commit_pc,bp_commit_target,bp_resolved_count,bp_mispredict_count;
    wire [31:0] bp_direction_error_count,bp_target_error_count;
    cpu5_alu_pipeline #(.ENABLE_FORWARDING(1),.ENABLE_CONTROL_FLOW(1),
        .BRANCH_RESOLVE_IN_ID(MODE),.ENABLE_BRANCH_PRED(1)) dut(.irq_external(1'b0),.irq_software(1'b0),.irq_timer(1'b0),
        .clk(clk),.rst_n(rst_n),.in_valid(in_valid),.in_ready(in_ready),
        .in_pc(in_pc),.in_instr(in_instr),.in_pred_next_pc(in_pred_next_pc),
        .in_pred_taken(in_pred_taken),.in_pred_hit(in_pred_hit),
        .in_fetch_error(in_fetch_error),.in_fetch_tval(in_fetch_tval),
        .in_seq(in_seq),.in_epoch(in_epoch),.id_enable(id_enable),.ex_enable(ex_enable),
        .mem_enable(mem_enable),.wb_ready(wb_ready),.flush_valid(flush_valid),.flush_cut_seq(flush_cut_seq),
        .ex_valid(ex_valid),.ex_pc(ex_pc),.ex_instr(ex_instr),.wb_pc(wb_pc),.wb_data(wb_data),
        .wb_rd(wb_rd),.wb_we(wb_we),.retire_valid(retire_valid),.retire_pc(retire_pc),
        .retire_instr(retire_instr),.retire_value(retire_value),.retire_rd(retire_rd),
        .retire_writes_rd(retire_writes_rd),.retire_seq(retire_seq),.cycle_count(cycle_count),
        .instret_count(instret_count),.arch_next_pc_q(arch_next_pc_q),.halted(halted),
        .halt_pc(halt_pc),.halt_instr(halt_instr),.halt_seq(halt_seq),.halt_fetch_error(halt_fetch_error),
        .id_raw_wait(id_raw_wait),.retire_fire(retire_fire),.wb_fire(wb_fire),
        .redirect_valid(redirect_valid),.redirect_kill_ifid(redirect_kill_ifid),
        .redirect_pc(redirect_pc),.redirect_seq(redirect_seq),
        .bp_commit_valid(bp_commit_valid),.bp_commit_seq(bp_commit_seq),
        .bp_commit_pc(bp_commit_pc),.bp_commit_target(bp_commit_target),.bp_commit_taken(bp_commit_taken),
        .bp_commit_is_branch(bp_commit_is_branch),.bp_commit_is_jal(bp_commit_is_jal),
        .bp_resolved_count(bp_resolved_count),.bp_mispredict_count(bp_mispredict_count),
        .bp_direction_error_count(bp_direction_error_count),.bp_target_error_count(bp_target_error_count),
        .halt_cause(halt_cause),.halt_tval(halt_tval),
        .flush_ready(),.flush_fire(),.dmem_req_valid(),.dmem_req_ready(1'b0),
        .dmem_req_write(),.dmem_req_addr(),.dmem_req_size(),.dmem_req_wdata(),.dmem_req_wstrb(),
        .dmem_rsp_valid(1'b0),.dmem_rsp_ready(),.dmem_rsp_rdata(32'd0),.dmem_rsp_error(1'b0),.dmem_fault(),.trap_fire(),.trap_valid(),.trap_pc(),.trap_cause(),.trap_tval(),.trap_seq());

    reg [63:0] eseq[0:31],rseq[0:15];
    reg [31:0] epc[0:31],eins[0:31],eval[0:31],enext[0:31],etarget[0:31],epred[0:31],rpc[0:15];
    reg [4:0] erd[0:31];
    reg [1:0] ekind[0:31];
    reg etaken[0:31],eptaken[0:31];
    integer expected=0,retired=0,wb_count=0,expected_redirects=0,redirects=0;
    integer case_no=0,passed=0,timeout=0,trace_fd,summary_fd;
    integer total_retired=0,total_wb=0,total_redirects=0,total_writes=0,total_raw=0;
    integer total_held_mem=0,total_held_wb=0,total_halt_edges=0;
    integer ebpresolved=0,ebpmiss=0,ebpdir=0,ebptarget=0;
    integer ri,wi,cycles=0;
    reg pre_retire,pre_wb,pre_we,last_accept=0;
    reg [63:0] last_accept_seq=0;
    reg [31:0] ins;
    function [31:0] addi(input [4:0] d,input [4:0] s,input [11:0] v);
        begin addi={v,s,3'b000,d,7'b0010011};end
    endfunction
    function [31:0] jal(input [4:0] d,input integer delta);
        reg [20:0] n;
        begin n=delta;jal={n[20],n[10:1],n[11],n[19:12],d,7'b1101111};end
    endfunction
    function [31:0] branch(input [4:0] s1,input [4:0] s2,input [2:0] f,input integer delta);
        reg [12:0] n;
        begin n=delta;branch={n[12],n[10:5],s2,s1,f,n[4:1],n[11],7'b1100011};end
    endfunction
    task tick;begin @(posedge clk);#2;end endtask
    task reset_case(input integer n);
        begin
            @(negedge clk);rst_n=0;in_valid=0;in_fetch_error=0;in_pred_taken=0;in_pred_hit=0;
            in_epoch=0;id_enable=1;ex_enable=1;mem_enable=1;wb_ready=1;flush_valid=0;
            case_no=n;expected=0;expected_redirects=0;tick;tick;
            @(negedge clk);rst_n=1;
        end
    endtask
    task expect_packet(input [63:0] seq,input [31:0] pc,input [31:0] word,
                       input [4:0] d,input [31:0] v,input [31:0] nextpc,
                       input [1:0] kind,input taken,input [31:0] target,
                       input [31:0] pred,input predicted_taken);
        begin
            eseq[expected]=seq;epc[expected]=pc;eins[expected]=word;erd[expected]=d;
            eval[expected]=v;enext[expected]=nextpc;ekind[expected]=kind;
            etaken[expected]=taken;etarget[expected]=target;epred[expected]=pred;eptaken[expected]=predicted_taken;
            expected=expected+1;
        end
    endtask
    task expect_alu(input [63:0] seq,input [31:0] pc,input [31:0] word,input [4:0] d,input [31:0] v);
        begin expect_packet(seq,pc,word,d,v,pc+4,0,0,pc+4,pc+4,0);end
    endtask
    task expect_redirect(input [63:0] seq,input [31:0] pc);
        begin rseq[expected_redirects]=seq;rpc[expected_redirects]=pc;expected_redirects=expected_redirects+1;end
    endtask
    task offer(input [63:0] seq,input [31:0] pc,input [31:0] word,input [7:0] epoch,
               input [31:0] predicted,input ptaken);
        begin
            @(negedge clk);in_seq=seq;in_pc=pc;in_instr=word;in_epoch=epoch;
            in_pred_next_pc=predicted;in_pred_taken=ptaken;in_pred_hit=ptaken;
            in_valid=1;in_fetch_error=0;in_fetch_tval=pc;
        end
    endtask
    task wait_accept;
        begin
            timeout=0;tick;
            while(!(last_accept&&last_accept_seq==in_seq))begin
                timeout=timeout+1;if(timeout>50)$fatal(1,"branch control ID timeout mode=%0d case=%0d",MODE,case_no);
                tick;
            end
        end
    endtask
    task send(input [63:0] seq,input [31:0] pc,input [31:0] word,input [7:0] epoch);
        begin offer(seq,pc,word,epoch,pc+4,0);wait_accept;end
    endtask
    task stop_input;begin @(negedge clk);in_valid=0;in_fetch_error=0;end endtask
    task flush_all(input [63:0] cut);
        begin
            @(negedge clk);flush_valid=1;flush_cut_seq=cut;in_valid=0;
            #1;if(redirect_valid)$fatal(1,"flush lost to redirect mode=%0d case=%0d",MODE,case_no);
            tick;@(negedge clk);flush_valid=0;
        end
    endtask
    task drain;
        begin
            timeout=0;
            while(retired!=expected||wb_count!=expected||dut.idex_valid_q||dut.exmem_valid_q||dut.memwb_valid_q)begin
                tick;timeout=timeout+1;
                if(timeout>65)$fatal(1,"drain mode=%0d case=%0d retire=%0d/%0d wb=%0d",MODE,case_no,retired,expected,wb_count);
            end
            repeat(2)tick;
            if(redirects!=expected_redirects)$fatal(1,"missing redirects mode=%0d case=%0d got=%0d/%0d",MODE,case_no,redirects,expected_redirects);
            passed=passed+1;
            $display("CPU5_BRANCH_CONTROL_CASE_PASS mode=%0d case=%0d retired=%0d wb=%0d redirects=%0d",MODE,case_no,retired,wb_count,redirects);
        end
    endtask
    always @(posedge clk)begin
        cycles=cycles+1;
        if(!rst_n)begin
            retired=0;wb_count=0;redirects=0;last_accept=0;
            ebpresolved=0;ebpmiss=0;ebpdir=0;ebptarget=0;
            if(wb_we||retire_fire||redirect_valid||bp_commit_valid)$fatal(1,"reset side effect mode=%0d",MODE);
        end else begin
            last_accept=in_valid&&in_ready;last_accept_seq=in_seq;
            pre_retire=retire_fire;pre_wb=wb_fire;pre_we=wb_we;
            ri=retired;wi=wb_count;
            if(id_raw_wait)total_raw=total_raw+1;
            if(dut.exmem_valid_q&&!mem_enable)total_held_mem=total_held_mem+1;
            if(dut.memwb_valid_q&&!wb_ready)total_held_wb=total_held_wb+1;
            if(halted)total_halt_edges=total_halt_edges+1;
            if(bp_commit_valid!==retire_fire)$fatal(1,"BP authorization mode=%0d case=%0d",MODE,case_no);
            if(redirect_valid)begin
                if(redirects>=expected_redirects||redirect_seq!==rseq[redirects]||
                   redirect_pc!==rpc[redirects]||redirect_kill_ifid!==!MODE)
                    $fatal(1,"unexpected redirect mode=%0d case=%0d seq=%h pc=%h kill=%b index=%0d/%0d",MODE,case_no,redirect_seq,redirect_pc,redirect_kill_ifid,redirects,expected_redirects);
                if(!MODE&&last_accept)$fatal(1,"EX redirect admitted younger ID");
                if(MODE&&!last_accept)$fatal(1,"ID redirect did not transfer its own token");
                $fdisplay(trace_fd,"redirect,%0d,%0d,%h,%h,%b",case_no,cycles,redirect_seq,redirect_pc,redirect_kill_ifid);
                redirects=redirects+1;total_redirects=total_redirects+1;
            end
            if(pre_wb)begin
                if(wi>=retired||dut.memwb_q.seq!==eseq[wi]||wb_pc!==epc[wi]||wb_rd!==erd[wi]||
                   wb_data!==eval[wi]||pre_we!==(erd[wi]!=0))
                    $fatal(1,"WB stream mode=%0d case=%0d index=%0d",MODE,case_no,wi);
                wb_count=wb_count+1;total_wb=total_wb+1;
                if(pre_we)total_writes=total_writes+1;
                $fdisplay(trace_fd,"wb,%0d,%0d,%h,%h,%h",case_no,cycles,eseq[wi],wb_pc,wb_data);
            end
            if(pre_retire)begin
                if(ri>=expected||bp_commit_seq!==eseq[ri]||bp_commit_pc!==epc[ri]||
                   bp_commit_is_branch!==(ekind[ri]==1)||bp_commit_is_jal!==(ekind[ri]==2)||
                   bp_commit_target!==etarget[ri]||bp_commit_taken!==etaken[ri])
                    $fatal(1,"BP retirement payload mode=%0d case=%0d index=%0d seq=%h pc=%h target=%h/%h taken=%b/%b",MODE,case_no,ri,bp_commit_seq,bp_commit_pc,bp_commit_target,etarget[ri],bp_commit_taken,etaken[ri]);
                if(ekind[ri]==1||ekind[ri]==2)ebpresolved=ebpresolved+1;
                if(enext[ri]!=epred[ri])ebpmiss=ebpmiss+1;
                if((ekind[ri]==1||ekind[ri]==2)&&etaken[ri]!=eptaken[ri])ebpdir=ebpdir+1;
                if((ekind[ri]==1||ekind[ri]==2)&&etaken[ri]&&eptaken[ri]&&enext[ri]!=epred[ri])ebptarget=ebptarget+1;
            end
            #1;
            if(retire_valid!==pre_retire)$fatal(1,"registered retire event");
            if(pre_retire)begin
                if(retire_seq!==eseq[ri]||retire_pc!==epc[ri]||retire_instr!==eins[ri]||
                   retire_rd!==erd[ri]||retire_value!==eval[ri]||retire_writes_rd!==(erd[ri]!=0)||
                   arch_next_pc_q!==enext[ri])
                    $fatal(1,"retire stream mode=%0d case=%0d index=%0d seq=%h pc=%h rd=%0d val=%h next=%h/%h",MODE,case_no,ri,retire_seq,retire_pc,retire_rd,retire_value,arch_next_pc_q,enext[ri]);
                retired=retired+1;total_retired=total_retired+1;
                $fdisplay(trace_fd,"retire,%0d,%0d,%h,%h,%h",case_no,cycles,retire_seq,retire_pc,retire_value);
            end
            if(instret_count!==retired||bp_resolved_count!==ebpresolved||bp_mispredict_count!==ebpmiss||
               bp_direction_error_count!==ebpdir||bp_target_error_count!==ebptarget)
                $fatal(1,"counter mismatch mode=%0d case=%0d instret=%0d/%0d BP=%0d/%0d,%0d/%0d,%0d/%0d,%0d/%0d",MODE,case_no,instret_count,retired,bp_resolved_count,ebpresolved,bp_mispredict_count,ebpmiss,bp_direction_error_count,ebpdir,bp_target_error_count,ebptarget);
        end
    end

    initial begin
        trace_fd=$fopen($sformatf("build/cpu5_s4_branch_control/mode%0d_trace.csv",MODE),"w");
        $fdisplay(trace_fd,"event,case,cycle,seq,pc,value_or_kill");
        // A redirect transfers the ID source itself; EX redirect kills the
        // concurrently offered younger ID packet.
        reset_case(1);ins=jal(1,16);
        expect_packet(2,'h100,ins,1,'h104,'h110,2,1,'h110,'h104,0);expect_redirect(2,'h110);
        send(2,'h100,ins,0);
        if(!MODE)begin
            offer(3,'h104,addi(2,0,9),1,'h108,0);#1;
            if(!redirect_valid||in_ready||!redirect_kill_ifid)$fatal(1,"EX redirect admission");
            tick;if(last_accept)$fatal(1,"wrong path admitted");
        end
        stop_input;drain;

        // A stopped MEM token outranks a younger redirect. It can be removed
        // by an explicit age flush; no fabricated trap or retirement occurs.
        reset_case(2);send(10,'h180,32'h00002023,0);stop_input;tick;
        if(!halted||halt_fetch_error)$fatal(1,"unsupported MEM halt missing");
        offer(11,'h184,jal(1,16),1,'h188,0);
        repeat(3)begin #1;if(redirect_valid||retire_fire||bp_commit_valid)$fatal(1,"younger bypassed stopped MEM");tick;end
        flush_all(10);drain;

        // An older known EX fault blocks a younger ID-resolved jump even in
        // the cycle where the older token advances to MEM.
        reset_case(3);ex_enable=0;send(20,'h1c0,32'h00002023,0);
        offer(21,'h1c4,jal(1,16),1,'h1c8,0);#1;
        if(redirect_valid||in_ready)$fatal(1,"known EX fault lost priority");
        ex_enable=1;#1;if(MODE&&(redirect_valid||in_ready))$fatal(1,"moving EX fault lost priority");
        tick;stop_input;tick;if(!halted)$fatal(1,"EX unsupported never halted");flush_all(20);drain;

        reset_case(4);ex_enable=0;send(30,'h200,jal(1,2),0);
        offer(31,'h204,jal(2,16),1,'h208,0);#1;
        if(redirect_valid||in_ready)$fatal(1,"old misaligned target lost priority");
        ex_enable=1;#1;if(MODE&&(redirect_valid||in_ready))$fatal(1,"misalignment priority at EX move");
        tick;stop_input;tick;
        if(!halted||halt_pc!=='h200||halt_seq!==30||halt_cause!==0||halt_tval!=='h202||halt_fetch_error)
            $fatal(1,"target misalignment descriptor mode=%0d",MODE);
        flush_all(30);drain;

        // Flush wins over a redirect while an already retired WB drains.
        reset_case(5);wb_ready=0;expect_alu(40,'h240,addi(5,0,7),5,7);
        send(40,'h240,addi(5,0,7),0);stop_input;tick;tick;
        if(!dut.memwb_valid_q||retired!=1)$fatal(1,"old WB preparation");
        ex_enable=0;
        if(!MODE)send(41,'h244,jal(6,16),1);
        offer(41,'h244,jal(6,16),1,'h248,0);
        flush_valid=1;flush_cut_seq=41;ex_enable=1;wb_ready=1;#1;
        if(redirect_valid||in_ready||!wb_fire||!wb_we)$fatal(1,"flush/WB priority");
        tick;@(negedge clk);in_valid=0;flush_valid=0;drain;

        // Prediction updates and all counters happen exactly at MEM retirement.
        reset_case(6);mem_enable=0;ins=jal(6,16);
        expect_packet(50,'h280,ins,6,'h284,'h290,2,1,'h290,'h284,0);expect_redirect(50,'h290);
        send(50,'h280,ins,0);stop_input;tick;tick;
        repeat(5)begin if(bp_commit_valid||retire_fire||instret_count!=0)$fatal(1,"training during MEM wait");tick;end
        @(negedge clk);mem_enable=1;wb_ready=0;tick;
        repeat(5)begin if(bp_commit_valid||retire_fire||retired!=1)$fatal(1,"duplicate BP retirement");tick;end
        @(negedge clk);wb_ready=1;drain;

        // EX producer forces an ID branch-use wait; the next cycle's MEM
        // forwarding supplies the value despite a different fetch epoch.
        reset_case(7);ex_enable=0;
        expect_alu(60,'h300,addi(1,0,1),1,1);ins=branch(1,0,1,8);
        expect_packet(61,'h304,ins,0,0,'h30c,1,1,'h30c,'h308,0);expect_redirect(61,'h30c);
        send(60,'h300,addi(1,0,1),255);
        offer(61,'h304,ins,0,'h308,0);ex_enable=1;#1;
        if(MODE&&(!id_raw_wait||in_ready))$fatal(1,"ID branch skipped EX producer wait");
        tick;
        if(MODE)begin
            @(negedge clk);#1;
            if(id_raw_wait||!in_ready||dut.id_branch_rs1!==1)$fatal(1,"ID branch did not use MEM value");
            wait_accept;
        end
        stop_input;drain;

        // A newer unready MEM writer must hide an older matching WB result.
        // The unavailable source is retained when WB subsequently drains.
        reset_case(8);wb_ready=0;
        expect_alu(70,'h400,addi(1,0,0),1,0);expect_alu(71,'h404,addi(1,0,1),1,1);
        ins=branch(1,0,1,8);expect_packet(72,'h408,ins,0,0,'h410,1,1,'h410,'h40c,0);expect_redirect(72,'h410);
        send(70,'h400,addi(1,0,0),255);send(71,'h404,addi(1,0,1),0);stop_input;tick;
        if(!dut.memwb_valid_q||!dut.exmem_valid_q||dut.exmem_q.seq!==71)$fatal(1,"unready MEM preparation");
        force dut.exmem_q.result_ready=1'b0;
        offer(72,'h408,ins,17,'h40c,0);
        if(!MODE)wait_accept;
        repeat(3)begin
            #1;if(MODE?(!id_raw_wait||in_ready):(!dut.ex_source_stall||dut.ex_move))$fatal(1,"newest unavailable source fell back to WB");
            if(redirect_valid)$fatal(1,"unavailable branch redirected");tick;
        end
        @(negedge clk);wb_ready=1;if(!MODE)in_valid=0;
        repeat(3)begin #1;if(MODE?(!id_raw_wait||in_ready):(!dut.ex_source_stall||dut.ex_move))$fatal(1,"blocked source lost after WB drain");tick;end
        @(negedge clk);force dut.exmem_q.result_ready=1'b1;
        if(MODE)wait_accept;else tick;
        @(negedge clk);release dut.exmem_q.result_ready;in_valid=0;drain;

        // Full 64-bit age comparison straddles 2^32; epochs do not define age.
        reset_case(9);mem_enable=0;
        expect_alu(64'hffffffff,'h500,addi(3,0,7),3,7);
        send(64'hffffffff,'h500,addi(3,0,7),255);
        send(64'h100000000,'h504,addi(4,0,9),0);
        offer(64'h100000001,'h508,jal(5,16),1,'h50c,0);
        flush_valid=1;flush_cut_seq=64'h100000000;mem_enable=1;#1;
        if(redirect_valid||in_ready||!retire_fire)$fatal(1,"64-bit age flush");
        tick;@(negedge clk);in_valid=0;flush_valid=0;drain;

        // Fetch failure retains its own cause/tval before target calculations.
        reset_case(10);offer(80,'h580,jal(1,2),0,'h584,0);
        in_fetch_error=1;in_fetch_tval=32'hdeadbeef;wait_accept;stop_input;tick;tick;
        if(!halted||!halt_fetch_error||halt_cause!==1||halt_tval!==32'hdeadbeef||halt_seq!==80)
            $fatal(1,"fetch-error descriptor");
        flush_all(80);drain;

        // Correct prediction, predicted-taken/actual-not-taken correction, and
        // JALR's separate BTB classification are checked from hand outcomes.
        reset_case(11);ins=jal(1,16);
        expect_packet(90,'h600,ins,1,'h604,'h610,2,1,'h610,'h610,1);
        offer(90,'h600,ins,0,'h610,1);wait_accept;stop_input;tick;tick;
        ins=branch(0,0,1,8);expect_packet(91,'h610,ins,0,0,'h614,1,0,'h618,'h618,1);expect_redirect(91,'h614);
        offer(91,'h610,ins,1,'h618,1);wait_accept;stop_input;tick;tick;
        ins=32'h00c00067;expect_packet(92,'h614,ins,0,'h618,'hc,3,1,'hc,'hc,1);
        offer(92,'h614,ins,2,'hc,1);wait_accept;stop_input;drain;

        reset_case(12);ins=jal(1,16);
        expect_packet(100,'h700,ins,1,'h704,'h710,2,1,'h710,'h720,1);expect_redirect(100,'h710);
        offer(100,'h700,ins,0,'h720,1);wait_accept;stop_input;drain;

        // An untaken branch may encode a misaligned target without faulting.
        reset_case(13);ins=branch(0,0,1,2);
        expect_packet(110,'h800,ins,0,0,'h804,1,0,'h802,'h804,0);
        send(110,'h800,ins,0);stop_input;drain;
        if(halted)$fatal(1,"untaken target caused halt");

        // A source older than the external flush cut survives. Pausing the
        // transfer on the flush edge preserves its redirect for the next edge.
        reset_case(14);ins=jal(1,16);
        expect_packet(120,'h900,ins,1,'h904,'h910,2,1,'h910,'h904,0);expect_redirect(120,'h910);
        if(MODE)begin
            id_enable=0;offer(120,'h900,ins,255,'h904,0);
        end else begin
            ex_enable=0;send(120,'h900,ins,255);stop_input;
        end
        flush_valid=1;flush_cut_seq=122;id_enable=1;ex_enable=1;#1;
        if(redirect_valid||in_ready||dut.ex_move)$fatal(1,"surviving source consumed on flush edge");
        tick;@(negedge clk);flush_valid=0;
        if(MODE)wait_accept;else tick;
        stop_input;drain;

        // A stale BTB prediction on an ordinary ALU instruction must also be
        // corrected. It retires as an ordinary packet, never a branch/JAL.
        reset_case(15);ins=addi(1,0,7);
        expect_packet(130,0,ins,1,7,4,0,0,4,'h80,1);expect_redirect(130,4);
        offer(130,0,ins,0,'h80,1);wait_accept;stop_input;drain;

        if(passed!=15||total_halt_edges<4||total_held_mem<5||total_held_wb<5||
           (MODE&&total_raw<5))$fatal(1,"branch control coverage incomplete");
        summary_fd=$fopen($sformatf("build/cpu5_s4_branch_control/mode%0d_coverage.json",MODE),"w");
        $fdisplay(summary_fd,"{\"mode\":%0d,\"cases_passed\":%0d,\"retired\":%0d,\"wb\":%0d,\"writes\":%0d,\"redirects\":%0d,\"raw_wait_edges\":%0d,\"held_mem_edges\":%0d,\"held_wb_edges\":%0d,\"halt_edges\":%0d,\"pass\":true}",MODE,passed,total_retired,total_wb,total_writes,total_redirects,total_raw,total_held_mem,total_held_wb,total_halt_edges);
        $fclose(summary_fd);$fclose(trace_fd);done=1;
    end
endmodule

module cpu5_branch_control_tb;
    wire [1:0] done;
    reg test_pass=0;
    cpu5_branch_control_case #(.MODE(0)) ex_case(.done(done[0]));
    cpu5_branch_control_case #(.MODE(1)) id_case(.done(done[1]));
    initial begin wait(&done);test_pass=1;$display("CPU5 BRANCH CONTROL PASS 30 CASES");$stop;end
    initial begin #100000;$fatal(1,"branch control overall timeout");end
endmodule
