`timescale 1ns/1ps
module cpu5_m_program_tb;
    wire [15:0] done;reg test_pass=0;genvar n;
    generate for(n=0;n<16;n=n+1)begin:g_cases
        cpu5_m_program_case #(.CASE_ID(n),.ID_MODE(n%2),.PRED((n/2)%2),
            .WAIT((n/4)%2),.FORWARD(n/8)) u(.done(done[n]));
    end endgenerate
    initial begin wait(&done);test_pass=1;
        $display("CPU5 M PROGRAM PASS: 16 real IF cases, all eight M ops, ID/EX, BP, I/D waits, FWD off/on");$stop;end
    initial begin #800000;$fatal(1,"CPU5 M PROGRAM timeout done=%h",done);end
endmodule

module cpu5_m_program_case #(
    parameter CASE_ID=0,ID_MODE=0,PRED=0,WAIT=0,FORWARD=0,
    parameter BASE="build/cpu5_s8_m_program"
)(output reg done=0);
    reg clk=0,rst_n=0;always #10 clk=~clk;
    wire qv,qr,sv,sr,dqv,dqr,dqw,dsv,dsr,rv,we,tf,ifault,tx;
    wire [31:0] qa,dqa,dqd,wpc,wdata;wire [4:0] wrd;wire [1:0] dz;wire [3:0] dst;wire [63:0] cc,ic;
    reg pending=0,dpending=0,quiesce=0;reg [31:0] addr=0,drdata=0,daddr_q=0,dwdata_q=0,dpc_q=0;
    reg [1:0] dsize_q=0;reg [3:0] dstrb_q=0;reg dwrite_q=0;reg [63:0] dseq_q=0;
    integer delay=0,ddelay=0,cycles=0,requests=0,responses=0,drequests=0,dresponses=0;
    integer accepted=0,retired=0,wb=0,drain=0,missues=0,mstarts=0,mcompletions=0;
    integer fd_trace,fd_accept,fd_wb,fd_if,fd_d,fd_m,fd_metrics,fd_gpr,fd_ram,i,j,k,owner;
    reg [31:0] program_words[0:255],terminal_pc[0:0],final_gpr[0:31],final_mask[0:31],ram[0:7],ram_final[0:7];
    reg [31:0] gold_pc[0:255],gold_instr[0:255],gold_rd[0:255],gold_value[0:255],gold_writes[0:255],gold_nextpc[0:255];
    reg [31:0] gold_mem_pc[0:5],gold_mem_addr[0:5],gold_mem_wdata[0:5],gold_mem_wstrb[0:5];
    reg [31:0] gold_mem_size[0:5],gold_mem_write[0:5],gold_mem_rdata[0:5];
    reg [63:0] accept_seq[0:1023],retired_seq[0:255],last_retire_seq=0;
    reg [31:0] accept_pc[0:1023],accept_instr[0:1023];
    reg [31:0] retired_pc[0:255],retired_instr[0:255],retired_rd[0:255],retired_value[0:255],retired_writes[0:255],retired_next[0:255];
    reg held=0,rsp_held=0,dheld=0;reg [31:0] saved_req,saved_rsp;reg [70:0] saved_d;
    reg fire_retire;reg [63:0] before_ic,pre_seq,start_seq;
    reg [31:0] pre_pc,pre_instr,pre_rd,pre_value,pre_writes,pre_next;
    string directory;
    assign qr=rst_n&&!quiesce&&(!pending||(sv&&sr))&&(!WAIT||cycles%7>=2);
    assign sv=pending&&delay==0;
    assign dqr=rst_n&&(!dpending||(dsv&&dsr))&&(!WAIT||cycles%5>=2);
    assign dsv=dpending&&ddelay==0;
    wire [31:0] response_data=program_words[addr>>2];
    cpu5_top #(.PROGRAM_FILE("programs/data_handshake_blank.hex"),.IMEM_WORDS(256),.DMEM_WORDS(8),
        .SKELETON_ONLY(0),.ENABLE_FORWARDING(FORWARD),.ENABLE_CONTROL_FLOW(1),.ENABLE_RAM(1),
        .ENABLE_SYNC_TRAPS(1),.ENABLE_CSR(1),.ENABLE_RV32M(1),.TRAP_VECTOR(32'h100),
        .ENABLE_BRANCH_PRED(PRED),.BRANCH_RESOLVE_IN_ID(ID_MODE)) dut(.irq_software(1'b0),.irq_timer(1'b0),
        .clk(clk),.rst_n(rst_n),.pc_x(),.instr_x(),.valid_x(),.wb_pc(wpc),.wb_rd(wrd),.wb_data(wdata),.wb_we(we),
        .retire_valid(rv),.cycle_count(cc),.instret_count(ic),.uart_tx(tx),.uart_rx(1'b1),
        .gpio_in(8'hff),.gpio_out(),.gpio_oe(),.dmem_req_valid(dqv),.dmem_req_ready(dqr),
        .dmem_req_write(dqw),.dmem_req_addr(dqa),.dmem_req_size(dz),.dmem_req_wdata(dqd),.dmem_req_wstrb(dst),
        .dmem_rsp_valid(dsv),.dmem_rsp_ready(dsr),.dmem_rsp_rdata(drdata),.dmem_rsp_error(1'b0),.dmem_fault(),
        .imem_req_valid(qv),.imem_req_ready(qr),.imem_req_addr(qa),.imem_rsp_valid(sv),.imem_rsp_ready(sr),
        .imem_rsp_rdata(response_data),.imem_rsp_error(1'b0),.imem_fault(ifault),.imem_fault_pc(),
        .trap_valid(tf),.trap_pc(),.trap_cause(),.trap_tval(),.bp_lookup_count(),.bp_hit_count(),.bp_taken_count(),
        .bp_resolved_count(),.bp_mispredict_count(),.bp_direction_error_count(),.bp_target_error_count(),
        .irq_external(1'b1),.perf_cycle_events());
    initial begin
        $readmemh({BASE,"/program.hex"},program_words,0,255);$readmemh({BASE,"/terminal_pc.hex"},terminal_pc,0,0);
        $readmemh({BASE,"/expected_pc.hex"},gold_pc,0,255);$readmemh({BASE,"/expected_instr.hex"},gold_instr,0,255);
        $readmemh({BASE,"/expected_rd.hex"},gold_rd,0,255);$readmemh({BASE,"/expected_value.hex"},gold_value,0,255);
        $readmemh({BASE,"/expected_writes.hex"},gold_writes,0,255);$readmemh({BASE,"/expected_nextpc.hex"},gold_nextpc,0,255);
        $readmemh({BASE,"/expected_mem_pc.hex"},gold_mem_pc,0,5);$readmemh({BASE,"/expected_mem_addr.hex"},gold_mem_addr,0,5);
        $readmemh({BASE,"/expected_mem_wdata.hex"},gold_mem_wdata,0,5);$readmemh({BASE,"/expected_mem_wstrb.hex"},gold_mem_wstrb,0,5);
        $readmemh({BASE,"/expected_mem_size.hex"},gold_mem_size,0,5);$readmemh({BASE,"/expected_mem_is_write.hex"},gold_mem_write,0,5);
        $readmemh({BASE,"/expected_mem_rdata.hex"},gold_mem_rdata,0,5);
        $readmemh({BASE,"/final_gpr.hex"},final_gpr,0,31);$readmemh({BASE,"/final_gpr_mask.hex"},final_mask,0,31);
        $readmemh({BASE,"/ram_initial.hex"},ram,0,7);$readmemh({BASE,"/ram_final.hex"},ram_final,0,7);
        directory=$sformatf("%s/cases/case%0d",BASE,CASE_ID);
        fd_trace=$fopen({directory,"/trace.csv"},"w");fd_accept=$fopen({directory,"/accept.csv"},"w");
        fd_wb=$fopen({directory,"/wb.csv"},"w");fd_if=$fopen({directory,"/if.csv"},"w");
        fd_d=$fopen({directory,"/d.csv"},"w");fd_m=$fopen({directory,"/m.csv"},"w");
        if(!fd_trace||!fd_accept||!fd_wb||!fd_if||!fd_d||!fd_m)$fatal(1,"M program trace open case=%0d",CASE_ID);
        $fwrite(fd_trace,"cycle,index,seq,pc,instr,rd,value,writes,nextpc,instret\n");
        $fwrite(fd_accept,"cycle,seq,pc,instr\n");$fwrite(fd_wb,"cycle,index,seq,pc,instr,rd,value,writes,nextpc\n");
        $fwrite(fd_if,"event,cycle,addr\n");$fwrite(fd_m,"event,cycle,seq,value\n");
        $fwrite(fd_d,"event,cycle,seq,pc,addr,wdata,wstrb,size,is_write,rdata\n");
        repeat(4)@(negedge clk);rst_n=1;
        if(CASE_ID==15)dut.u_if_adapter.next_seq_q=64'h00000000fffffffc;
    end
    always @(posedge clk)if(rst_n&&!done)begin
        cycles=cycles+1;
        if(tf||ifault||tx!==1||dut.g_alu.u_pipeline.trap_fire)$fatal(1,"M program unexpected trap/side effect case=%0d",CASE_ID);
        if(held&&(!qv||qa!==saved_req))$fatal(1,"M held IF request changed case=%0d",CASE_ID);
        held=qv&&!qr;saved_req=qa;
        if(rsp_held&&(!sv||response_data!==saved_rsp))$fatal(1,"M held IF response changed case=%0d",CASE_ID);
        rsp_held=sv&&!sr;saved_rsp=response_data;
        if(sv&&sr)begin
            if(!pending)$fatal(1,"M IF response lacks owner case=%0d",CASE_ID);
            $fwrite(fd_if,"rsp,%0d,%08h\n",cycles,addr);pending<=0;responses=responses+1;
        end
        if(pending&&delay>0)delay<=delay-1;
        if(qv&&qr)begin
            if(qa[1:0]!=0||qa>=1024||(pending&&!(sv&&sr)))$fatal(1,"M IF owner/address case=%0d",CASE_ID);
            $fwrite(fd_if,"req,%0d,%08h\n",cycles,qa);addr<=qa;pending<=1;delay<=WAIT?requests%5:0;requests=requests+1;
        end
        if(dheld&&(!dqv||{dqw,dqa,dz,dqd,dst}!==saved_d))$fatal(1,"M held D descriptor changed case=%0d",CASE_ID);
        dheld=dqv&&!dqr;saved_d={dqw,dqa,dz,dqd,dst};
        if(dsv&&dsr)begin
            if(!dpending)$fatal(1,"M D response lacks owner case=%0d",CASE_ID);
            $fwrite(fd_d,"rsp,%0d,%016h,%08h,%08h,%08h,%01h,%0d,%0d,%08h\n",cycles,dseq_q,dpc_q,daddr_q,dwdata_q,dstrb_q,dsize_q,dwrite_q,drdata);
            dpending<=0;dresponses=dresponses+1;
        end
        if(dpending&&ddelay>0)ddelay<=ddelay-1;
        if(dqv&&dqr)begin
            if(drequests>=6||(dpending&&!(dsv&&dsr)))$fatal(1,"M D request overwrite/extra case=%0d",CASE_ID);
            if(dqa!==gold_mem_addr[drequests]||dqw!==(gold_mem_write[drequests]!=0)||dz!==gold_mem_size[drequests][1:0]||
                dst!==gold_mem_wstrb[drequests][3:0]||dqd!==gold_mem_wdata[drequests]||dut.g_alu.u_pipeline.ram_req_pc!==gold_mem_pc[drequests])
                $fatal(1,"M D descriptor gold case=%0d index=%0d addr=%h data=%h",CASE_ID,drequests,dqa,dqd);
            j=(dqa-32'h10000)>>2;
            if(j<0||j>=8||ram[j]!==gold_mem_rdata[drequests])$fatal(1,"M D endpoint RAM word case=%0d",CASE_ID);
            drdata<=ram[j];daddr_q<=dqa;dwdata_q<=dqd;dstrb_q<=dst;dsize_q<=dz;dwrite_q<=dqw;
            dseq_q<=dut.g_alu.u_pipeline.ram_req_seq;dpc_q<=dut.g_alu.u_pipeline.ram_req_pc;
            $fwrite(fd_d,"req,%0d,%016h,%08h,%08h,%08h,%01h,%0d,%0d,00000000\n",cycles,dut.g_alu.u_pipeline.ram_req_seq,dut.g_alu.u_pipeline.ram_req_pc,dqa,dqd,dst,dz,dqw);
            if(dqw)for(k=0;k<4;k=k+1)if(dst[k])ram[j][k*8+:8]=dqd[k*8+:8];
            dpending<=1;ddelay<=WAIT?drequests%6:0;drequests=drequests+1;
        end
        if(dut.ifid_valid_q&&dut.ifid_ready)begin
            if(accepted>=1024||(accepted>0&&dut.ifid_q.seq<=accept_seq[accepted-1]))$fatal(1,"M accepted age case=%0d",CASE_ID);
            accept_seq[accepted]=dut.ifid_q.seq;accept_pc[accepted]=dut.ifid_q.pc;accept_instr[accepted]=dut.ifid_q.instr;
            $fwrite(fd_accept,"%0d,%016h,%08h,%08h\n",cycles,dut.ifid_q.seq,dut.ifid_q.pc,dut.ifid_q.instr);accepted=accepted+1;
        end
        if(dut.g_alu.u_pipeline.m_issue_fire)begin
            $fwrite(fd_m,"issue,%0d,%016h,00000000\n",cycles,dut.g_alu.u_pipeline.idex_q.seq);missues=missues+1;
        end
        if(dut.g_alu.u_pipeline.m_unit_start)begin
            start_seq=dut.g_alu.u_pipeline.m_issue_fire?dut.g_alu.u_pipeline.idex_q.seq:dut.g_alu.u_pipeline.m_owner_seq;
            $fwrite(fd_m,"start,%0d,%016h,00000000\n",cycles,start_seq);mstarts=mstarts+1;
        end
        if(dut.g_alu.u_pipeline.m_completion_valid&&dut.g_alu.u_pipeline.m_completion_ready)begin
            if(dut.g_alu.u_pipeline.m_completion_killed)$fatal(1,"M program unexpected killed completion case=%0d",CASE_ID);
            $fwrite(fd_m,"complete,%0d,%016h,%08h\n",cycles,dut.g_alu.u_pipeline.m_completion_seq,dut.g_alu.u_pipeline.m_completion_result);mcompletions=mcompletions+1;
        end
        if(dut.g_alu.u_pipeline.m_drain_fire)$fatal(1,"M program unexpected drain case=%0d",CASE_ID);
        fire_retire=dut.g_alu.u_pipeline.retire_fire;before_ic=ic;
        if(dut.g_alu.u_pipeline.wb_fire)begin
            if(wb>=retired||dut.g_alu.u_pipeline.memwb_q.seq!==retired_seq[wb]||wpc!==retired_pc[wb]||
                dut.g_alu.u_pipeline.memwb_q.instr!==retired_instr[wb]||wrd!==retired_rd[wb][4:0]||wdata!==retired_value[wb]||
                we!==(retired_writes[wb]!=0)||dut.g_alu.u_pipeline.memwb_q.actual_next_pc!==retired_next[wb])$fatal(1,"M physical WB ledger case=%0d index=%0d",CASE_ID,wb);
            $fwrite(fd_wb,"%0d,%0d,%016h,%08h,%08h,%0d,%08h,%0d,%08h\n",cycles,wb,retired_seq[wb],wpc,retired_instr[wb],wrd,wdata,we,retired_next[wb]);wb=wb+1;
        end
        if(fire_retire)begin
            if(retired>=256)$fatal(1,"M retirement overflow case=%0d",CASE_ID);
            pre_seq=dut.g_alu.u_pipeline.exmem_q.seq;pre_pc=dut.g_alu.u_pipeline.exmem_q.pc;pre_instr=dut.g_alu.u_pipeline.exmem_q.instr;
            pre_rd=dut.g_alu.u_pipeline.exmem_q.rd;pre_value=dut.g_alu.u_pipeline.mem_result_value;
            pre_writes=dut.g_alu.u_pipeline.exmem_q.writes_rd&&pre_rd!=0;pre_next=dut.g_alu.u_pipeline.mem_actual_next_pc;
            if(pre_pc!==gold_pc[retired]||pre_instr!==gold_instr[retired]||pre_rd!==gold_rd[retired]||pre_value!==gold_value[retired]||
                pre_writes!==gold_writes[retired]||pre_next!==gold_nextpc[retired])
                $fatal(1,"M independent retirement mismatch case=%0d index=%0d pc=%h instr=%h rd=%0d value=%h next=%h",CASE_ID,retired,pre_pc,pre_instr,pre_rd,pre_value,pre_next);
            if(retired>0&&pre_seq<=last_retire_seq)$fatal(1,"M retirement age case=%0d",CASE_ID);
            last_retire_seq=pre_seq;owner=0;
            for(i=0;i<accepted;i=i+1)if(accept_seq[i]==pre_seq&&accept_pc[i]==pre_pc&&accept_instr[i]==pre_instr)owner=owner+1;
            if(owner!=1)$fatal(1,"M accepted retirement owner case=%0d",CASE_ID);
        end
        #1;
        if(rv!==fire_retire||ic!==before_ic+(fire_retire?1:0))$fatal(1,"M registered retirement/count case=%0d",CASE_ID);
        if(fire_retire)begin
            if(dut.g_alu.u_pipeline.arch_next_pc_q!==pre_next||dut.g_alu.u_pipeline.retire_pc!==pre_pc||dut.g_alu.u_pipeline.retire_instr!==pre_instr||
                dut.g_alu.u_pipeline.retire_seq!==pre_seq||dut.g_alu.u_pipeline.retire_rd!==pre_rd[4:0]||
                dut.g_alu.u_pipeline.retire_value!==pre_value||dut.g_alu.u_pipeline.retire_writes_rd!==(pre_writes!=0))$fatal(1,"M registered descriptor case=%0d",CASE_ID);
            retired_seq[retired]=pre_seq;retired_pc[retired]=pre_pc;retired_instr[retired]=pre_instr;retired_rd[retired]=pre_rd;
            retired_value[retired]=pre_value;retired_writes[retired]=pre_writes;retired_next[retired]=pre_next;
            $fwrite(fd_trace,"%0d,%0d,%016h,%08h,%08h,%0d,%08h,%0d,%08h,%0d\n",cycles,retired,pre_seq,pre_pc,pre_instr,pre_rd,pre_value,pre_writes,pre_next,ic);
            retired=retired+1;if(pre_pc==terminal_pc[0])quiesce<=1;
        end
        if(quiesce&&!pending&&!dpending&&!dut.ifid_valid_q&&!dut.g_alu.u_pipeline.idex_valid_q&&!dut.g_alu.u_pipeline.exmem_valid_q&&
            !dut.g_alu.u_pipeline.memwb_valid_q&&!dut.g_alu.u_pipeline.m_owner_valid&&!dut.g_alu.u_pipeline.ram_owner_valid)drain=drain+1;else drain=0;
        if(drain==3)begin
            if(retired!=wb||ic!=retired||requests!=responses||drequests!=6||dresponses!=6||missues!=mstarts||missues!=mcompletions)$fatal(1,"M final ledger closure case=%0d",CASE_ID);
            fd_gpr=$fopen({directory,"/actual_gpr_final.hex"},"w");$fwrite(fd_gpr,"00000000\n");
            for(i=1;i<32;i=i+1)begin
                if(final_mask[i]&&dut.g_alu.u_pipeline.u_regfile.regs[i]!==final_gpr[i])$fatal(1,"M final GPR case=%0d x%0d",CASE_ID,i);
                if(!final_mask[i]&&dut.g_alu.u_pipeline.u_regfile.regs[i]!==32'hxxxxxxxx)$fatal(1,"M untouched GPR changed case=%0d x%0d",CASE_ID,i);
                $fwrite(fd_gpr,"%08h\n",dut.g_alu.u_pipeline.u_regfile.regs[i]);
            end $fclose(fd_gpr);
            fd_ram=$fopen({directory,"/actual_ram_final.hex"},"w");
            for(i=0;i<8;i=i+1)begin if(ram[i]!==ram_final[i])$fatal(1,"M final RAM case=%0d word=%0d",CASE_ID,i);$fwrite(fd_ram,"%08h\n",ram[i]);end $fclose(fd_ram);
            fd_metrics=$fopen({directory,"/metrics.json"},"w");
            $fwrite(fd_metrics,"{\"retired\":%0d,\"wb_packets\":%0d,\"accepted\":%0d,\"m_issues\":%0d,\"m_starts\":%0d,\"m_completions\":%0d,\"d_requests\":%0d,\"d_responses\":%0d,\"requests\":%0d,\"responses\":%0d,\"cycles\":%0d}\n",retired,wb,accepted,missues,mstarts,mcompletions,drequests,dresponses,requests,responses,cycles);
            $fclose(fd_metrics);$fclose(fd_trace);$fclose(fd_accept);$fclose(fd_wb);$fclose(fd_if);$fclose(fd_d);$fclose(fd_m);done=1;
            $display("CPU5 M PROGRAM CASE PASS case=%0d ID=%0d BP=%0d WAIT=%0d FWD=%0d retired=%0d M=%0d D=%0d",CASE_ID,ID_MODE,PRED,WAIT,FORWARD,retired,missues,drequests);
        end
    end
endmodule
