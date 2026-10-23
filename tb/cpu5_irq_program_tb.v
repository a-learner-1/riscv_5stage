`timescale 1ns/1ps
module cpu5_irq_program_tb;
    wire [15:0] done;reg test_pass=0;genvar n;
    generate for(n=0;n<16;n=n+1)begin:g_cases
        cpu5_irq_program_case #(.CASE_ID(n),.ID_MODE(n%2),.PRED((n/2)%2),
            .WAIT((n/4)%2),.FORWARD(n/8)) u(.done(done[n]));
    end endgenerate
    initial begin wait(&done);test_pass=1;
        $display("CPU5 IRQ PROGRAM PASS: 16 real IF cases, three prioritized IRQs, running DIV kill, ISR MUL, MRET");$stop;end
    initial begin #800000;$fatal(1,"CPU5 IRQ PROGRAM timeout done=%h",done);end
endmodule

module cpu5_irq_program_case #(
    parameter CASE_ID=0,ID_MODE=0,PRED=0,WAIT=0,FORWARD=0,
    parameter BASE="build/cpu5_s9_irq_program"
)(output reg done=0);
    reg clk=0,rst_n=0;always #10 clk=~clk;
    wire qv,qr,sv,sr,dqv,dqr,dqw,dsv,dsr,rv,we,tf,ifault,tx;
    wire [31:0] qa,dqa,dqd,wpc,wdata,tpc,tc,tv;wire [4:0] wrd;wire [1:0] dz;wire [3:0] dst;wire [63:0] cc,ic;
    reg raw_ext=0,raw_sw=0,raw_timer=0,div_started=0;
    reg pending=0,dpending=0,quiesce=0,ier_q=0,error_issued=0;
    reg [31:0] addr=0,drdata=0,daddr_q=0,dwdata_q=0,dpc_q=0;
    reg [1:0] dsize_q=0;reg [3:0] dstrb_q=0;reg dwrite_q=0;reg [63:0] dseq_q=0;
    integer delay=0,ddelay=0,cycles=0,requests=0,responses=0,drequests=0,dresponses=0;
    integer accepted=0,events=0,retired=0,wb=0,irqs=0,drain=0,missues=0,mstarts=0,mcompletions=0,mdrains=0;
    integer held_if_cycles=0,stale_if_errors=0;
    integer fd_event,fd_accept,fd_wb,fd_if,fd_d,fd_m,fd_cycle,fd_metrics,fd_gpr,fd_ram,i,j,k,owner;
    reg [31:0] program_words[0:255],terminal_pc[0:0],final_gpr[0:31],final_mask[0:31],ram[0:15],ram_final[0:15];
    reg [31:0] gold_kind[0:255],gold_pc[0:255],gold_instr[0:255],gold_rd[0:255],gold_value[0:255],gold_writes[0:255],gold_nextpc[0:255];
    reg [31:0] gold_cause[0:255],gold_tval[0:255],gold_status[0:255],gold_mtvec[0:255],gold_scratch[0:255];
    reg [31:0] gold_mepc[0:255],gold_mcause[0:255],gold_mtval[0:255],gold_mie[0:255];
    reg [31:0] gold_mem_pc[0:13],gold_mem_addr[0:13],gold_mem_wdata[0:13],gold_mem_wstrb[0:13];
    reg [31:0] gold_mem_size[0:13],gold_mem_write[0:13],gold_mem_rdata[0:13];
    reg [63:0] accept_seq[0:1023],retired_seq[0:255],last_retire_seq=0;
    reg [31:0] accept_pc[0:1023],accept_instr[0:1023];
    reg [31:0] retired_pc[0:255],retired_instr[0:255],retired_rd[0:255],retired_value[0:255],retired_writes[0:255],retired_next[0:255];
    reg held=0,rsp_held=0,dheld=0;reg [31:0] saved_req;reg [32:0] saved_rsp;reg [70:0] saved_d;
    reg fire_retire,fire_irq;reg [63:0] before_ic,pre_seq,start_seq;
    reg [31:0] pre_pc,pre_instr,pre_rd,pre_value,pre_writes,pre_next,pre_cause;
    string directory;
    assign qr=rst_n&&!quiesce&&(!pending||(sv&&sr))&&(!WAIT||cycles%7>=2)&&
        (qa!=32'h34||irqs>0);
    assign sv=pending&&delay==0;
    assign dqr=rst_n&&(!dpending||(dsv&&dsr))&&(!WAIT||cycles%5>=2);
    assign dsv=dpending&&ddelay==0;
    wire [31:0] response_data=program_words[addr>>2];
    wire [31:0] status=dut.g_alu.u_pipeline.g_csr.u_csr.csr_mstatus;
    wire [31:0] mtvec=dut.g_alu.u_pipeline.g_csr.u_csr.csr_mtvec;
    wire [31:0] scratch=dut.g_alu.u_pipeline.g_csr.u_csr.csr_mscratch;
    wire [31:0] mepc=dut.g_alu.u_pipeline.g_csr.u_csr.csr_mepc;
    wire [31:0] mcause=dut.g_alu.u_pipeline.g_csr.u_csr.csr_mcause;
    wire [31:0] mtval=dut.g_alu.u_pipeline.g_csr.u_csr.csr_mtval;
    wire [31:0] mie=dut.g_alu.u_pipeline.g_csr.u_csr.csr_mie;
    cpu5_top #(.PROGRAM_FILE("programs/data_handshake_blank.hex"),.IMEM_WORDS(256),.DMEM_WORDS(16),
        .SKELETON_ONLY(0),.ENABLE_FORWARDING(FORWARD),.ENABLE_CONTROL_FLOW(1),.ENABLE_RAM(1),
        .ENABLE_SYNC_TRAPS(1),.ENABLE_CSR(1),.ENABLE_RV32M(1),.TRAP_VECTOR(32'h100),
        .ENABLE_EXTERNAL_IRQ(1),.ENABLE_SOFTWARE_IRQ(1),.ENABLE_TIMER_IRQ(1),
        .ENABLE_BRANCH_PRED(PRED),.BRANCH_RESOLVE_IN_ID(ID_MODE)) dut(
        .clk(clk),.rst_n(rst_n),.pc_x(),.instr_x(),.valid_x(),.wb_pc(wpc),.wb_rd(wrd),.wb_data(wdata),.wb_we(we),
        .retire_valid(rv),.cycle_count(cc),.instret_count(ic),.uart_tx(tx),.uart_rx(1'b1),
        .gpio_in(8'hff),.gpio_out(),.gpio_oe(),.dmem_req_valid(dqv),.dmem_req_ready(dqr),
        .dmem_req_write(dqw),.dmem_req_addr(dqa),.dmem_req_size(dz),.dmem_req_wdata(dqd),.dmem_req_wstrb(dst),
        .dmem_rsp_valid(dsv),.dmem_rsp_ready(dsr),.dmem_rsp_rdata(drdata),.dmem_rsp_error(1'b0),.dmem_fault(),
        .imem_req_valid(qv),.imem_req_ready(qr),.imem_req_addr(qa),.imem_rsp_valid(sv),.imem_rsp_ready(sr),
        .imem_rsp_rdata(response_data),.imem_rsp_error(ier_q),.imem_fault(ifault),.imem_fault_pc(),
        .trap_valid(tf),.trap_pc(tpc),.trap_cause(tc),.trap_tval(tv),.bp_lookup_count(),.bp_hit_count(),.bp_taken_count(),
        .bp_resolved_count(),.bp_mispredict_count(),.bp_direction_error_count(),.bp_target_error_count(),
        .irq_external(raw_ext),.irq_software(raw_sw),.irq_timer(raw_timer),.perf_cycle_events());
    initial begin
        $readmemh({BASE,"/program.hex"},program_words,0,255);$readmemh({BASE,"/terminal_pc.hex"},terminal_pc,0,0);
        $readmemh({BASE,"/expected_kind.hex"},gold_kind,0,255);$readmemh({BASE,"/expected_pc.hex"},gold_pc,0,255);
        $readmemh({BASE,"/expected_instr.hex"},gold_instr,0,255);$readmemh({BASE,"/expected_rd.hex"},gold_rd,0,255);
        $readmemh({BASE,"/expected_value.hex"},gold_value,0,255);$readmemh({BASE,"/expected_writes.hex"},gold_writes,0,255);
        $readmemh({BASE,"/expected_nextpc.hex"},gold_nextpc,0,255);$readmemh({BASE,"/expected_cause.hex"},gold_cause,0,255);
        $readmemh({BASE,"/expected_tval.hex"},gold_tval,0,255);$readmemh({BASE,"/expected_mstatus.hex"},gold_status,0,255);
        $readmemh({BASE,"/expected_mtvec.hex"},gold_mtvec,0,255);$readmemh({BASE,"/expected_mscratch.hex"},gold_scratch,0,255);
        $readmemh({BASE,"/expected_mepc.hex"},gold_mepc,0,255);$readmemh({BASE,"/expected_mcause.hex"},gold_mcause,0,255);
        $readmemh({BASE,"/expected_mtval.hex"},gold_mtval,0,255);$readmemh({BASE,"/expected_mie.hex"},gold_mie,0,255);
        $readmemh({BASE,"/expected_mem_pc.hex"},gold_mem_pc,0,13);$readmemh({BASE,"/expected_mem_addr.hex"},gold_mem_addr,0,13);
        $readmemh({BASE,"/expected_mem_wdata.hex"},gold_mem_wdata,0,13);$readmemh({BASE,"/expected_mem_wstrb.hex"},gold_mem_wstrb,0,13);
        $readmemh({BASE,"/expected_mem_size.hex"},gold_mem_size,0,13);$readmemh({BASE,"/expected_mem_is_write.hex"},gold_mem_write,0,13);
        $readmemh({BASE,"/expected_mem_rdata.hex"},gold_mem_rdata,0,13);
        $readmemh({BASE,"/final_gpr.hex"},final_gpr,0,31);$readmemh({BASE,"/final_gpr_mask.hex"},final_mask,0,31);
        $readmemh({BASE,"/ram_initial.hex"},ram,0,15);$readmemh({BASE,"/ram_final.hex"},ram_final,0,15);
        directory=$sformatf("%s/cases/case%0d",BASE,CASE_ID);
        fd_event=$fopen({directory,"/events.csv"},"w");fd_accept=$fopen({directory,"/accept.csv"},"w");
        fd_wb=$fopen({directory,"/wb.csv"},"w");fd_if=$fopen({directory,"/if.csv"},"w");
        fd_d=$fopen({directory,"/d.csv"},"w");fd_m=$fopen({directory,"/m.csv"},"w");fd_cycle=$fopen({directory,"/cycles.csv"},"w");
        if(!fd_event||!fd_accept||!fd_wb||!fd_if||!fd_d||!fd_m||!fd_cycle)$fatal(1,"IRQ program trace open case=%0d",CASE_ID);
        $fwrite(fd_event,"kind,cycle,index,seq,pc,instr,rd,value,writes,nextpc,cause,tval,mstatus,mtvec,mscratch,mepc,mcause,mtval,mie,instret\n");
        $fwrite(fd_accept,"cycle,seq,pc,instr\n");$fwrite(fd_wb,"cycle,index,seq,pc,instr,rd,value,writes,nextpc\n");
        $fwrite(fd_if,"event,cycle,addr,error\n");$fwrite(fd_m,"event,cycle,seq,pc,value\n");
        $fwrite(fd_d,"event,cycle,seq,pc,addr,wdata,wstrb,size,is_write,rdata\n");
        $fwrite(fd_cycle,"cycle,raw_ext,raw_sw,raw_timer,pending,arm,eligible,take,mstatus,mie\n");
        repeat(4)@(negedge clk);rst_n=1;
        if(CASE_ID==15)dut.u_if_adapter.next_seq_q=64'h00000000fffffffc;
    end
    always @(posedge clk)if(rst_n&&!done)begin
        cycles=cycles+1;
        if(ifault||tx!==1||dut.g_alu.u_pipeline.trap_fire)$fatal(1,"IRQ program stale IF became synchronous fault case=%0d",CASE_ID);
        $fwrite(fd_cycle,"%0d,%0d,%0d,%0d,%08h,%0d,%0d,%0d,%08h,%08h\n",cycles,raw_ext,raw_sw,raw_timer,
            dut.g_alu.u_pipeline.irq_pending_sync,dut.g_alu.u_pipeline.irq_arm_q,dut.g_alu.u_pipeline.irq_eligible_now,
            dut.g_alu.u_pipeline.irq_take,status,mie);
        if(held&&(!qv||qa!==saved_req))$fatal(1,"IRQ held IF request changed case=%0d",CASE_ID);
        held=qv&&!qr;saved_req=qa;if(qv&&!qr&&qa==32'h34&&irqs==0)held_if_cycles=held_if_cycles+1;
        if(rsp_held&&(!sv||{ier_q,response_data}!==saved_rsp))$fatal(1,"IRQ held IF response changed case=%0d",CASE_ID);
        rsp_held=sv&&!sr;saved_rsp={ier_q,response_data};
        if(sv&&sr)begin
            if(!pending)$fatal(1,"IRQ IF response lacks owner case=%0d",CASE_ID);
            $fwrite(fd_if,"rsp,%0d,%08h,%0d\n",cycles,addr,ier_q);pending<=0;responses=responses+1;
            if(ier_q)begin if(irqs==0)$fatal(1,"IRQ IF error delivered before redirect case=%0d",CASE_ID);stale_if_errors=stale_if_errors+1;end
        end
        if(pending&&delay>0)delay<=delay-1;
        if(qv&&qr)begin
            if(qa[1:0]!=0||qa>=1024||(pending&&!(sv&&sr)))$fatal(1,"IRQ IF owner/address case=%0d",CASE_ID);
            $fwrite(fd_if,"req,%0d,%08h,0\n",cycles,qa);addr<=qa;pending<=1;delay<=WAIT?requests%5:0;requests=requests+1;
            ier_q<=qa==32'h34&&!error_issued;if(qa==32'h34&&!error_issued)error_issued=1;
        end
        if(dheld&&(!dqv||{dqw,dqa,dz,dqd,dst}!==saved_d))$fatal(1,"IRQ held D descriptor changed case=%0d",CASE_ID);
        dheld=dqv&&!dqr;saved_d={dqw,dqa,dz,dqd,dst};
        if(dsv&&dsr)begin
            if(!dpending)$fatal(1,"IRQ D response lacks owner case=%0d",CASE_ID);
            $fwrite(fd_d,"rsp,%0d,%016h,%08h,%08h,%08h,%01h,%0d,%0d,%08h\n",cycles,dseq_q,dpc_q,daddr_q,dwdata_q,dstrb_q,dsize_q,dwrite_q,drdata);
            dpending<=0;dresponses=dresponses+1;
        end
        if(dpending&&ddelay>0)ddelay<=ddelay-1;
        if(dqv&&dqr)begin
            if(drequests>=14||(dpending&&!(dsv&&dsr)))$fatal(1,"IRQ D request overwrite/extra case=%0d",CASE_ID);
            if(dqa!==gold_mem_addr[drequests]||dqw!==(gold_mem_write[drequests]!=0)||dz!==gold_mem_size[drequests][1:0]||
                dst!==gold_mem_wstrb[drequests][3:0]||dqd!==gold_mem_wdata[drequests]||dut.g_alu.u_pipeline.ram_req_pc!==gold_mem_pc[drequests])
                $fatal(1,"IRQ D descriptor gold case=%0d index=%0d addr=%h data=%h",CASE_ID,drequests,dqa,dqd);
            j=(dqa-32'h10000)>>2;
            if(j<0||j>=16||ram[j]!==gold_mem_rdata[drequests])$fatal(1,"IRQ D endpoint RAM word case=%0d",CASE_ID);
            drdata<=ram[j];daddr_q<=dqa;dwdata_q<=dqd;dstrb_q<=dst;dsize_q<=dz;dwrite_q<=dqw;
            dseq_q<=dut.g_alu.u_pipeline.ram_req_seq;dpc_q<=dut.g_alu.u_pipeline.ram_req_pc;
            $fwrite(fd_d,"req,%0d,%016h,%08h,%08h,%08h,%01h,%0d,%0d,00000000\n",cycles,dut.g_alu.u_pipeline.ram_req_seq,dut.g_alu.u_pipeline.ram_req_pc,dqa,dqd,dst,dz,dqw);
            if(dqw)for(k=0;k<4;k=k+1)if(dst[k])ram[j][k*8+:8]=dqd[k*8+:8];
            dpending<=1;ddelay<=WAIT?drequests%6:0;drequests=drequests+1;
        end
        if(dut.ifid_valid_q&&dut.ifid_ready)begin
            if(accepted>=1024||(accepted>0&&dut.ifid_q.seq<=accept_seq[accepted-1]))$fatal(1,"IRQ accepted age case=%0d",CASE_ID);
            accept_seq[accepted]=dut.ifid_q.seq;accept_pc[accepted]=dut.ifid_q.pc;accept_instr[accepted]=dut.ifid_q.instr;
            $fwrite(fd_accept,"%0d,%016h,%08h,%08h\n",cycles,dut.ifid_q.seq,dut.ifid_q.pc,dut.ifid_q.instr);accepted=accepted+1;
        end
        if(dut.g_alu.u_pipeline.m_issue_fire)begin
            $fwrite(fd_m,"issue,%0d,%016h,%08h,00000000\n",cycles,dut.g_alu.u_pipeline.idex_q.seq,dut.g_alu.u_pipeline.idex_q.pc);missues=missues+1;
        end
        if(dut.g_alu.u_pipeline.m_unit_start)begin
            start_seq=dut.g_alu.u_pipeline.idex_q.seq;
            $fwrite(fd_m,"start,%0d,%016h,%08h,00000000\n",cycles,start_seq,dut.g_alu.u_pipeline.idex_q.pc);mstarts=mstarts+1;
            if(dut.g_alu.u_pipeline.idex_q.pc==32'h30&&!div_started)begin
                // NBA updates prevent a race with the controller's raw capture.
                raw_ext<=1;raw_sw<=1;raw_timer<=1;div_started=1;
            end
        end
        if(dut.g_alu.u_pipeline.m_completion_valid&&dut.g_alu.u_pipeline.m_completion_ready)begin
            if(dut.g_alu.u_pipeline.m_completion_killed)$fatal(1,"IRQ killed M acknowledged live case=%0d",CASE_ID);
            $fwrite(fd_m,"complete,%0d,%016h,%08h,%08h\n",cycles,dut.g_alu.u_pipeline.m_completion_seq,dut.g_alu.u_pipeline.m_completion_pc,dut.g_alu.u_pipeline.m_completion_result);mcompletions=mcompletions+1;
        end
        if(dut.g_alu.u_pipeline.m_drain_fire)begin
            $fwrite(fd_m,"drain,%0d,%016h,%08h,%08h\n",cycles,dut.g_alu.u_pipeline.m_completion_seq,dut.g_alu.u_pipeline.m_completion_pc,dut.g_alu.u_pipeline.m_completion_result);mdrains=mdrains+1;
        end
        fire_retire=dut.g_alu.u_pipeline.retire_fire;fire_irq=dut.g_alu.u_pipeline.irq_take;before_ic=ic;
        if(fire_irq&&fire_retire)$fatal(1,"IRQ and retirement overlap case=%0d",CASE_ID);
        if(fire_irq)begin
            if(dut.g_alu.u_pipeline.irq_cause==32'h8000000b)raw_ext<=0;
            else if(dut.g_alu.u_pipeline.irq_cause==32'h80000003)raw_sw<=0;
            else if(dut.g_alu.u_pipeline.irq_cause==32'h80000007)raw_timer<=0;
            else $fatal(1,"IRQ unexpected source cause case=%0d",CASE_ID);
        end
        if(dut.g_alu.u_pipeline.wb_fire)begin
            if(wb>=retired||dut.g_alu.u_pipeline.memwb_q.seq!==retired_seq[wb]||wpc!==retired_pc[wb]||
                dut.g_alu.u_pipeline.memwb_q.instr!==retired_instr[wb]||wrd!==retired_rd[wb][4:0]||wdata!==retired_value[wb]||
                we!==(retired_writes[wb]!=0)||dut.g_alu.u_pipeline.memwb_q.actual_next_pc!==retired_next[wb])$fatal(1,"IRQ physical WB ledger case=%0d index=%0d",CASE_ID,wb);
            $fwrite(fd_wb,"%0d,%0d,%016h,%08h,%08h,%0d,%08h,%0d,%08h\n",cycles,wb,retired_seq[wb],wpc,retired_instr[wb],wrd,wdata,we,retired_next[wb]);wb=wb+1;
        end
        if(fire_retire||fire_irq)begin
            if(events>=256)$fatal(1,"IRQ event overflow case=%0d",CASE_ID);
            pre_seq=fire_irq?dut.g_alu.u_pipeline.irq_seq:dut.g_alu.u_pipeline.exmem_q.seq;
            pre_pc=fire_irq?32'h30:dut.g_alu.u_pipeline.exmem_q.pc;pre_instr=fire_irq?0:dut.g_alu.u_pipeline.exmem_q.instr;
            pre_rd=fire_irq?0:dut.g_alu.u_pipeline.exmem_q.rd;pre_value=fire_irq?0:dut.g_alu.u_pipeline.mem_result_value;
            pre_writes=fire_irq?0:(dut.g_alu.u_pipeline.exmem_q.writes_rd&&pre_rd!=0);
            pre_next=fire_irq?dut.alu_redirect_pc:dut.g_alu.u_pipeline.mem_actual_next_pc;pre_cause=fire_irq?dut.g_alu.u_pipeline.irq_cause:0;
            if(gold_kind[events]!==(fire_irq?1:0)||pre_pc!==gold_pc[events]||pre_instr!==gold_instr[events]||pre_rd!==gold_rd[events]||
                pre_value!==gold_value[events]||pre_writes!==gold_writes[events]||pre_next!==gold_nextpc[events]||pre_cause!==gold_cause[events])
                $fatal(1,"IRQ independent event mismatch case=%0d event=%0d irq=%0d pc=%h instr=%h value=%h next=%h cause=%h",CASE_ID,events,fire_irq,pre_pc,pre_instr,pre_value,pre_next,pre_cause);
            if(!fire_irq)begin
                if(retired>0&&pre_seq<=last_retire_seq)$fatal(1,"IRQ retirement age case=%0d",CASE_ID);last_retire_seq=pre_seq;owner=0;
                for(i=0;i<accepted;i=i+1)if(accept_seq[i]==pre_seq&&accept_pc[i]==pre_pc&&accept_instr[i]==pre_instr)owner=owner+1;
                if(owner!=1)$fatal(1,"IRQ accepted retirement owner case=%0d",CASE_ID);
            end else if(dut.g_alu.u_pipeline.arch_next_pc_q!==32'h30)$fatal(1,"IRQ mepc independent boundary case=%0d",CASE_ID);
        end
        #1;
        if(rv!==fire_retire||tf!==fire_irq||ic!==before_ic+(fire_retire?1:0))$fatal(1,"IRQ registered event/count case=%0d",CASE_ID);
        if(fire_retire||fire_irq)begin
            if({status,mtvec,scratch,mepc,mcause,mtval,mie}!=={gold_status[events],gold_mtvec[events],gold_scratch[events],gold_mepc[events],gold_mcause[events],gold_mtval[events],gold_mie[events]}||
                dut.g_alu.u_pipeline.arch_next_pc_q!==pre_next)$fatal(1,"IRQ independent CSR/PC state case=%0d event=%0d",CASE_ID,events);
            if(fire_retire)begin
                retired_seq[retired]=pre_seq;retired_pc[retired]=pre_pc;retired_instr[retired]=pre_instr;retired_rd[retired]=pre_rd;
                retired_value[retired]=pre_value;retired_writes[retired]=pre_writes;retired_next[retired]=pre_next;retired=retired+1;
                if(pre_pc==terminal_pc[0])quiesce<=1;
            end else begin
                if({tpc,tc,tv}!=={32'h30,pre_cause,32'd0}||dut.g_alu.u_pipeline.trap_seq!==pre_seq)$fatal(1,"IRQ registered trap descriptor case=%0d",CASE_ID);
                if(irqs==0&&(!dut.g_alu.u_pipeline.m_owner_valid||!dut.g_alu.u_pipeline.m_owner_killed))$fatal(1,"IRQ failed to kill running DIV case=%0d",CASE_ID);
                irqs=irqs+1;
            end
            if(fire_irq)$fwrite(fd_event,"irq,");else $fwrite(fd_event,"retire,");
            $fwrite(fd_event,"%0d,%0d,%016h,%08h,%08h,%0d,%08h,%0d,%08h,%08h,00000000,%08h,%08h,%08h,%08h,%08h,%08h,%08h,%0d\n",
                cycles,events,pre_seq,pre_pc,pre_instr,pre_rd,pre_value,pre_writes,pre_next,pre_cause,status,mtvec,scratch,mepc,mcause,mtval,mie,ic);events=events+1;
        end
        if(quiesce&&!pending&&!dpending&&!dut.ifid_valid_q&&!dut.g_alu.u_pipeline.idex_valid_q&&!dut.g_alu.u_pipeline.exmem_valid_q&&
            !dut.g_alu.u_pipeline.memwb_valid_q&&!dut.g_alu.u_pipeline.m_owner_valid&&!dut.g_alu.u_pipeline.ram_owner_valid)drain=drain+1;else drain=0;
        if(drain==3)begin
            if(retired!=wb||ic!=retired||requests!=responses||drequests!=14||dresponses!=14||irqs!=3||missues!=5||mstarts!=5||mcompletions!=4||mdrains!=1||
                stale_if_errors!=1||held_if_cycles==0)$fatal(1,"IRQ final ledger closure case=%0d",CASE_ID);
            fd_gpr=$fopen({directory,"/actual_gpr_final.hex"},"w");$fwrite(fd_gpr,"00000000\n");
            for(i=1;i<32;i=i+1)begin
                if(final_mask[i]&&dut.g_alu.u_pipeline.u_regfile.regs[i]!==final_gpr[i])$fatal(1,"IRQ final GPR case=%0d x%0d",CASE_ID,i);
                if(!final_mask[i]&&dut.g_alu.u_pipeline.u_regfile.regs[i]!==32'hxxxxxxxx)$fatal(1,"IRQ untouched GPR changed case=%0d x%0d",CASE_ID,i);
                $fwrite(fd_gpr,"%08h\n",dut.g_alu.u_pipeline.u_regfile.regs[i]);
            end $fclose(fd_gpr);
            fd_ram=$fopen({directory,"/actual_ram_final.hex"},"w");
            for(i=0;i<16;i=i+1)begin if(ram[i]!==ram_final[i])$fatal(1,"IRQ final RAM case=%0d word=%0d",CASE_ID,i);$fwrite(fd_ram,"%08h\n",ram[i]);end $fclose(fd_ram);
            fd_metrics=$fopen({directory,"/metrics.json"},"w");
            $fwrite(fd_metrics,"{\"events\":%0d,\"retired\":%0d,\"wb_packets\":%0d,\"irqs\":%0d,\"accepted\":%0d,\"m_issues\":%0d,\"m_starts\":%0d,\"m_completions\":%0d,\"m_drains\":%0d,\"d_requests\":%0d,\"d_responses\":%0d,\"requests\":%0d,\"responses\":%0d,\"cycles\":%0d,\"stale_if_errors\":%0d,\"held_if_cycles\":%0d}\n",
                events,retired,wb,irqs,accepted,missues,mstarts,mcompletions,mdrains,drequests,dresponses,requests,responses,cycles,stale_if_errors,held_if_cycles);
            $fclose(fd_metrics);$fclose(fd_event);$fclose(fd_accept);$fclose(fd_wb);$fclose(fd_if);$fclose(fd_d);$fclose(fd_m);$fclose(fd_cycle);done=1;
            $display("CPU5 IRQ PROGRAM CASE PASS case=%0d ID=%0d BP=%0d WAIT=%0d FWD=%0d retired=%0d IRQ=%0d Mdrain=%0d",CASE_ID,ID_MODE,PRED,WAIT,FORWARD,retired,irqs,mdrains);
        end
    end
endmodule
