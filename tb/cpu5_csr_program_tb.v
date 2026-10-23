`timescale 1ns/1ps
// Real IF requests execute hand-encoded programs. Golden rows are produced by
// the independent machine-word model, never by a DUT trace or internal result.
module cpu5_csr_program_tb;
    wire [15:0] done;
    reg test_pass=0;
    genvar n;
    generate for(n=0;n<16;n=n+1)begin:g_cases
        cpu5_csr_program_case #(.CASE_ID(n),.ID_MODE(n%2),.PRED((n/2)%2),
            .WAIT((n/4)%2),.FORWARD(n/8)) u(.done(done[n]));
    end endgenerate
    initial begin wait(&done);test_pass=1;
        $display("CPU5 CSR PROGRAM PASS: 16 real IF cases, ID/EX, BP, I waits, forwarding off/on");$stop;end
    initial begin #500000;$fatal(1,"CPU5 CSR PROGRAM timeout done=%h",done);end
endmodule

module cpu5_csr_program_case #(
    parameter CASE_ID=0,ID_MODE=0,PRED=0,WAIT=0,FORWARD=0,
    parameter BASE="build/cpu5_s7_csr_program"
)(output reg done=0);
    reg clk=0,rst_n=0;always #10 clk=~clk;
    wire qv,qr,sv,sr,rv,we,tf,dqv,tx,ifault;
    wire [31:0] qa,wpc,wdata,tpc,tc,tv;
    wire [4:0] wrd;wire [63:0] cc,ic;
    reg pending=0,quiesce=0;reg [31:0] addr=0;integer delay=0;
    integer cycles=0,requests=0,responses=0,accepted=0,events=0,retired=0,wb=0,traps=0,drain=0;
    integer fd_event,fd_accept,fd_wb,fd_if,fd_metrics,fd_gpr,i,owner;
    reg [31:0] program_words[0:511],terminal_pc[0:0],final_gpr[0:31],final_mask[0:31];
    reg [31:0] gold_kind[0:511],gold_pc[0:511],gold_instr[0:511],gold_rd[0:511],gold_value[0:511];
    reg [31:0] gold_writes[0:511],gold_nextpc[0:511],gold_cause[0:511],gold_tval[0:511];
    reg [31:0] gold_mstatus[0:511],gold_mtvec[0:511],gold_mscratch[0:511],gold_mepc[0:511],gold_mcause[0:511],gold_mtval[0:511];
    reg [63:0] accept_seq[0:1023],retired_seq[0:511],last_event_seq=0;
    reg [31:0] accept_pc[0:1023],accept_instr[0:1023];
    reg [31:0] retired_pc[0:511],retired_instr[0:511],retired_rd[0:511],retired_value[0:511],retired_writes[0:511],retired_next[0:511];
    reg held=0,rsp_held=0;reg [31:0] saved_req,saved_rsp;
    reg fire_retire,fire_trap,fire_csr,fire_mret;reg [63:0] before_ic,pre_seq;
    reg [31:0] pre_pc,pre_instr,pre_rd,pre_value,pre_writes,pre_next,pre_cause,pre_tval;
    reg [191:0] previous_csrs;
    reg [95:0] last_descriptor=0;
    string directory;
    assign qr=rst_n&&!quiesce&&(!pending||(sv&&sr))&&(!WAIT||cycles%7>=2);
    assign sv=pending&&delay==0;
    wire [31:0] response_data=program_words[addr>>2];
    wire [31:0] csr_mstatus=dut.g_alu.u_pipeline.g_csr.u_csr.csr_mstatus;
    wire [31:0] csr_mtvec=dut.g_alu.u_pipeline.g_csr.u_csr.csr_mtvec;
    wire [31:0] csr_mscratch=dut.g_alu.u_pipeline.g_csr.u_csr.csr_mscratch;
    wire [31:0] csr_mepc=dut.g_alu.u_pipeline.g_csr.u_csr.csr_mepc;
    wire [31:0] csr_mcause=dut.g_alu.u_pipeline.g_csr.u_csr.csr_mcause;
    wire [31:0] csr_mtval=dut.g_alu.u_pipeline.g_csr.u_csr.csr_mtval;
    wire [191:0] current_csrs={csr_mstatus,csr_mtvec,csr_mscratch,csr_mepc,csr_mcause,csr_mtval};
    cpu5_top #(.PROGRAM_FILE("programs/data_handshake_blank.hex"),.IMEM_WORDS(512),.DMEM_WORDS(8),
        .SKELETON_ONLY(0),.ENABLE_FORWARDING(FORWARD),.ENABLE_CONTROL_FLOW(1),.ENABLE_RAM(1),
        .ENABLE_SYNC_TRAPS(1),.ENABLE_CSR(1),.TRAP_VECTOR(32'h100),.ENABLE_BRANCH_PRED(PRED),
        .BRANCH_RESOLVE_IN_ID(ID_MODE)) dut(
        .clk(clk),.rst_n(rst_n),.pc_x(),.instr_x(),.valid_x(),.wb_pc(wpc),.wb_rd(wrd),.wb_data(wdata),.wb_we(we),
        .retire_valid(rv),.cycle_count(cc),.instret_count(ic),.uart_tx(tx),.uart_rx(1'b1),
        .gpio_in(8'hff),.gpio_out(),.gpio_oe(),.dmem_req_valid(dqv),.dmem_req_ready(1'b1),
        .dmem_req_write(),.dmem_req_addr(),.dmem_req_size(),.dmem_req_wdata(),.dmem_req_wstrb(),
        .dmem_rsp_valid(1'b0),.dmem_rsp_ready(),.dmem_rsp_rdata(32'd0),.dmem_rsp_error(1'b0),.dmem_fault(),
        .imem_req_valid(qv),.imem_req_ready(qr),.imem_req_addr(qa),.imem_rsp_valid(sv),.imem_rsp_ready(sr),
        .imem_rsp_rdata(response_data),.imem_rsp_error(1'b0),.imem_fault(ifault),.imem_fault_pc(),
        .trap_valid(tf),.trap_pc(tpc),.trap_cause(tc),.trap_tval(tv),.bp_lookup_count(),.bp_hit_count(),.bp_taken_count(),
        .bp_resolved_count(),.bp_mispredict_count(),.bp_direction_error_count(),.bp_target_error_count(),
        .irq_external(1'b1),.perf_cycle_events());
    initial begin
        $readmemh({BASE,"/program.hex"},program_words,0,511);
        $readmemh({BASE,"/terminal_pc.hex"},terminal_pc,0,0);
        $readmemh({BASE,"/expected_kind.hex"},gold_kind,0,511);
        $readmemh({BASE,"/expected_pc.hex"},gold_pc,0,511);$readmemh({BASE,"/expected_instr.hex"},gold_instr,0,511);
        $readmemh({BASE,"/expected_rd.hex"},gold_rd,0,511);$readmemh({BASE,"/expected_value.hex"},gold_value,0,511);
        $readmemh({BASE,"/expected_writes.hex"},gold_writes,0,511);$readmemh({BASE,"/expected_nextpc.hex"},gold_nextpc,0,511);
        $readmemh({BASE,"/expected_cause.hex"},gold_cause,0,511);$readmemh({BASE,"/expected_tval.hex"},gold_tval,0,511);
        $readmemh({BASE,"/expected_mstatus.hex"},gold_mstatus,0,511);$readmemh({BASE,"/expected_mtvec.hex"},gold_mtvec,0,511);
        $readmemh({BASE,"/expected_mscratch.hex"},gold_mscratch,0,511);$readmemh({BASE,"/expected_mepc.hex"},gold_mepc,0,511);
        $readmemh({BASE,"/expected_mcause.hex"},gold_mcause,0,511);$readmemh({BASE,"/expected_mtval.hex"},gold_mtval,0,511);
        $readmemh({BASE,"/final_gpr.hex"},final_gpr,0,31);$readmemh({BASE,"/final_gpr_mask.hex"},final_mask,0,31);
        directory=$sformatf("%s/cases/case%0d",BASE,CASE_ID);
        fd_event=$fopen({directory,"/events.csv"},"w");fd_accept=$fopen({directory,"/accept.csv"},"w");
        fd_wb=$fopen({directory,"/wb.csv"},"w");fd_if=$fopen({directory,"/if.csv"},"w");
        if(!fd_event||!fd_accept||!fd_wb||!fd_if)$fatal(1,"CSR program trace open case=%0d",CASE_ID);
        $fwrite(fd_event,"kind,cycle,index,seq,pc,instr,rd,value,writes,nextpc,cause,tval,mstatus,mtvec,mscratch,mepc,mcause,mtval,instret\n");
        $fwrite(fd_accept,"cycle,seq,pc,instr\n");$fwrite(fd_wb,"cycle,index,seq,pc,instr,rd,value,writes,nextpc\n");
        $fwrite(fd_if,"event,cycle,addr\n");
        repeat(4)@(negedge clk);rst_n=1;
        if(CASE_ID==15)dut.u_if_adapter.next_seq_q=64'h00000000fffffffc;
    end
    always @(posedge clk)if(rst_n&&!done)begin
        cycles=cycles+1;
        if(dqv||ifault||tx!==1)$fatal(1,"CSR program unexpected side effect case=%0d",CASE_ID);
        if(held&&(!qv||qa!==saved_req))$fatal(1,"CSR held IF request changed case=%0d",CASE_ID);
        held=qv&&!qr;saved_req=qa;
        if(rsp_held&&(!sv||response_data!==saved_rsp))$fatal(1,"CSR held IF response changed case=%0d",CASE_ID);
        rsp_held=sv&&!sr;saved_rsp=response_data;
        if(sv&&sr)begin
            if(!pending)$fatal(1,"CSR IF response lacks owner case=%0d",CASE_ID);
            $fwrite(fd_if,"rsp,%0d,%08h\n",cycles,addr);pending<=0;responses=responses+1;
        end
        if(pending&&delay>0)delay<=delay-1;
        if(qv&&qr)begin
            if(qa[1:0]!=0||qa>=2048||(pending&&!(sv&&sr)))$fatal(1,"CSR IF owner/address case=%0d",CASE_ID);
            $fwrite(fd_if,"req,%0d,%08h\n",cycles,qa);addr<=qa;pending<=1;delay<=WAIT?requests%5:0;requests=requests+1;
        end
        if(dut.ifid_valid_q&&dut.ifid_ready)begin
            if(accepted>=1024||(accepted>0&&dut.ifid_q.seq<=accept_seq[accepted-1]))$fatal(1,"CSR accepted age case=%0d",CASE_ID);
            accept_seq[accepted]=dut.ifid_q.seq;accept_pc[accepted]=dut.ifid_q.pc;accept_instr[accepted]=dut.ifid_q.instr;
            $fwrite(fd_accept,"%0d,%016h,%08h,%08h\n",cycles,dut.ifid_q.seq,dut.ifid_q.pc,dut.ifid_q.instr);accepted=accepted+1;
        end
        fire_retire=dut.g_alu.u_pipeline.retire_fire;fire_trap=dut.g_alu.u_pipeline.trap_fire;
        fire_csr=dut.g_alu.u_pipeline.csr_commit_fire;fire_mret=dut.g_alu.u_pipeline.mret_fire;
        previous_csrs=current_csrs;before_ic=ic;
        if(fire_retire&&fire_trap)$fatal(1,"CSR trap/retire overlap case=%0d",CASE_ID);
        if(fire_csr&&(!fire_retire||!dut.g_alu.u_pipeline.exmem_q.is_csr))$fatal(1,"CSR commit outside retirement case=%0d",CASE_ID);
        if(fire_mret&&(!fire_retire||!dut.g_alu.u_pipeline.exmem_q.is_mret))$fatal(1,"MRET outside retirement case=%0d",CASE_ID);
        if((fire_csr||fire_mret||fire_trap)&&dut.unused_bp_update)$fatal(1,"CSR/MRET/trap trained predictor case=%0d",CASE_ID);
        if(dut.g_alu.u_pipeline.wb_fire)begin
            if(wb>=retired||dut.g_alu.u_pipeline.memwb_q.seq!==retired_seq[wb]||wpc!==retired_pc[wb]||
                dut.g_alu.u_pipeline.memwb_q.instr!==retired_instr[wb]||wrd!==retired_rd[wb][4:0]||wdata!==retired_value[wb]||
                we!==(retired_writes[wb]!=0)||dut.g_alu.u_pipeline.memwb_q.actual_next_pc!==retired_next[wb])
                $fatal(1,"CSR physical WB ledger case=%0d index=%0d",CASE_ID,wb);
            $fwrite(fd_wb,"%0d,%0d,%016h,%08h,%08h,%0d,%08h,%0d,%08h\n",cycles,wb,retired_seq[wb],wpc,retired_instr[wb],wrd,wdata,we,retired_next[wb]);wb=wb+1;
        end
        if(fire_retire||fire_trap)begin
            if(events>=512)$fatal(1,"CSR event overflow case=%0d",CASE_ID);
            pre_seq=dut.g_alu.u_pipeline.exmem_q.seq;pre_pc=dut.g_alu.u_pipeline.exmem_q.pc;pre_instr=dut.g_alu.u_pipeline.exmem_q.instr;
            pre_rd=fire_trap?0:dut.g_alu.u_pipeline.exmem_q.rd;pre_value=fire_trap?0:dut.g_alu.u_pipeline.mem_result_value;
            pre_writes=fire_trap?0:(dut.g_alu.u_pipeline.exmem_q.writes_rd&&pre_rd!=0);
            pre_next=fire_trap?dut.alu_redirect_pc:dut.g_alu.u_pipeline.mem_actual_next_pc;
            pre_cause=fire_trap?dut.g_alu.u_pipeline.halt_cause:0;pre_tval=fire_trap?dut.g_alu.u_pipeline.halt_tval:0;
            if(gold_kind[events]!==(fire_trap?1:0)||pre_pc!==gold_pc[events]||pre_instr!==gold_instr[events]||pre_rd!==gold_rd[events]||
                pre_value!==gold_value[events]||pre_writes!==gold_writes[events]||pre_next!==gold_nextpc[events]||
                pre_cause!==gold_cause[events]||pre_tval!==gold_tval[events])
                $fatal(1,"CSR independent event mismatch case=%0d event=%0d trap=%0d pc=%h instr=%h rd=%0d value=%h next=%h",CASE_ID,events,fire_trap,pre_pc,pre_instr,pre_rd,pre_value,pre_next);
            if(events>0&&pre_seq<=last_event_seq)$fatal(1,"CSR event age case=%0d",CASE_ID);
            last_event_seq=pre_seq;owner=0;
            for(i=0;i<accepted;i=i+1)if(accept_seq[i]==pre_seq&&accept_pc[i]==pre_pc&&accept_instr[i]==pre_instr)owner=owner+1;
            if(owner!=1)$fatal(1,"CSR event accepted owner case=%0d",CASE_ID);
            if(fire_mret&&(!dut.alu_redirect||!dut.alu_redirect_kill||dut.alu_redirect_seq!==pre_seq))$fatal(1,"MRET precise redirect case=%0d",CASE_ID);
        end
        #1;
        if(rv!==fire_retire||tf!==fire_trap||ic!==before_ic+(fire_retire?1:0))$fatal(1,"CSR registered event/count case=%0d",CASE_ID);
        if(!fire_csr&&!fire_trap&&!fire_mret&&current_csrs!==previous_csrs)$fatal(1,"CSR state changed without commit case=%0d",CASE_ID);
        if(fire_retire||fire_trap)begin
            if(current_csrs!=={gold_mstatus[events],gold_mtvec[events],gold_mscratch[events],gold_mepc[events],gold_mcause[events],gold_mtval[events]}||
                dut.g_alu.u_pipeline.arch_next_pc_q!==pre_next)$fatal(1,"CSR independent state/nextPC case=%0d event=%0d pc=%h status=%h mepc=%h",CASE_ID,events,pre_pc,csr_mstatus,csr_mepc);
            if(fire_retire)begin
                if(dut.g_alu.u_pipeline.retire_pc!==pre_pc||dut.g_alu.u_pipeline.retire_instr!==pre_instr||dut.g_alu.u_pipeline.retire_seq!==pre_seq||
                    dut.g_alu.u_pipeline.retire_rd!==pre_rd[4:0]||dut.g_alu.u_pipeline.retire_value!==pre_value||dut.g_alu.u_pipeline.retire_writes_rd!==(pre_writes!=0))
                    $fatal(1,"CSR registered retirement descriptor case=%0d",CASE_ID);
                retired_seq[retired]=pre_seq;retired_pc[retired]=pre_pc;retired_instr[retired]=pre_instr;retired_rd[retired]=pre_rd;
                retired_value[retired]=pre_value;retired_writes[retired]=pre_writes;retired_next[retired]=pre_next;retired=retired+1;
                if(pre_pc==terminal_pc[0])quiesce<=1;
            end else begin
                if({tpc,tc,tv}!={pre_pc,pre_cause,pre_tval}||dut.g_alu.u_pipeline.trap_seq!==pre_seq)$fatal(1,"CSR diagnostic trap descriptor case=%0d",CASE_ID);
                last_descriptor={tpc,tc,tv};traps=traps+1;
            end
            if(fire_trap)$fwrite(fd_event,"trap,");else $fwrite(fd_event,"retire,");
            $fwrite(fd_event,"%0d,%0d,%016h,%08h,%08h,%0d,%08h,%0d,%08h,%08h,%08h,%08h,%08h,%08h,%08h,%08h,%08h,%0d\n",
                cycles,events,pre_seq,pre_pc,pre_instr,pre_rd,pre_value,pre_writes,pre_next,pre_cause,pre_tval,
                csr_mstatus,csr_mtvec,csr_mscratch,csr_mepc,csr_mcause,csr_mtval,ic);events=events+1;
        end
        if(traps&&!fire_trap&&{tpc,tc,tv}!==last_descriptor)$fatal(1,"CSR software write changed diagnostic descriptor case=%0d",CASE_ID);
        if(quiesce&&!pending&&!dut.ifid_valid_q&&!dut.g_alu.u_pipeline.idex_valid_q&&!dut.g_alu.u_pipeline.exmem_valid_q&&!dut.g_alu.u_pipeline.memwb_valid_q)drain=drain+1;else drain=0;
        if(drain==3)begin
            if(retired!=wb||ic!=retired||requests!=responses||traps==0)$fatal(1,"CSR final ledger closure case=%0d",CASE_ID);
            fd_gpr=$fopen({directory,"/actual_gpr_final.hex"},"w");$fwrite(fd_gpr,"00000000\n");
            for(i=1;i<32;i=i+1)begin
                if(final_mask[i]&&dut.g_alu.u_pipeline.u_regfile.regs[i]!==final_gpr[i])$fatal(1,"CSR final GPR case=%0d x%0d",CASE_ID,i);
                if(!final_mask[i]&&dut.g_alu.u_pipeline.u_regfile.regs[i]!==32'hxxxxxxxx)$fatal(1,"CSR uninitialized GPR changed case=%0d x%0d",CASE_ID,i);
                $fwrite(fd_gpr,"%08h\n",dut.g_alu.u_pipeline.u_regfile.regs[i]);
            end $fclose(fd_gpr);
            fd_metrics=$fopen({directory,"/metrics.json"},"w");
            $fwrite(fd_metrics,"{\"retired\":%0d,\"wb_packets\":%0d,\"traps\":%0d,\"events\":%0d,\"accepted\":%0d,\"requests\":%0d,\"responses\":%0d,\"cycles\":%0d}\n",retired,wb,traps,events,accepted,requests,responses,cycles);
            $fclose(fd_metrics);$fclose(fd_event);$fclose(fd_accept);$fclose(fd_wb);$fclose(fd_if);done=1;
            $display("CPU5 CSR PROGRAM CASE PASS case=%0d ID=%0d BP=%0d WAIT=%0d FWD=%0d retired=%0d traps=%0d",CASE_ID,ID_MODE,PRED,WAIT,FORWARD,retired,traps);
        end
    end
endmodule
