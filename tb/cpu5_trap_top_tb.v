`timescale 1ns/1ps
module cpu5_trap_top_tb;
    wire [103:0] done;
    reg test_pass=0;
    genvar n;
    wire [103:0] start_case;
    generate for(n=0;n<104;n=n+1)begin:g_cases
        if(n<8)begin:g_first assign start_case[n]=1'b1;end
        else begin:g_later assign start_case[n]=done[n-8];end
        cpu5_trap_top_case #(.CASE_ID(n),.ID_MODE(n%2),.PRED((n/2)%2),
            .WAIT((n/4)%2),.KIND(n/8)) u(.start(start_case[n]),.done(done[n]));
    end endgenerate
    initial begin wait(&done);test_pass=1;
        $display("CPU5 TRAP TOP PASS: 104 cases, 13 synchronous faults, ID/EX, BP, variable I/D waits");$stop;end
    initial begin #200000;$fatal(1,"CPU5 TRAP TOP timeout done=%h",done);end
endmodule
module cpu5_trap_top_case #(
    parameter CASE_ID=0,ID_MODE=0,PRED=0,WAIT=0,KIND=0,
    parameter BASE="build/cpu5_s6_trap"
)(input wire start,output reg done=0);
    reg clk=0,rst_n=0;always #10 clk=~clk;
    wire qv,qr,sv,sr,dqv,dqr,dqw,dsv,dsr,df,rv,we,tf,ifault,tx;
    wire [31:0] qa,dqa,dqd,wpc,wdata,tpc,tc,tv,ifpc;
    wire [1:0] dz;wire [3:0] dst;wire [4:0] wrd;
    wire [63:0] cc,ic;wire [9:0] perf;wire [7:0] gout,goe;
    wire [31:0] resolved,mispredict,direction_error,target_error;
    reg pending=0,dpending=0,quiesce=0;
    reg [31:0] addr=0,response_data,drdata=0,daddr_q=0,dwdata_q=0,dpc_q=0;
    reg derror_q=0,dwrite_q=0;reg [3:0] dstrb_q=0;reg [1:0] dsize_q=0;reg [63:0] dseq_q=0;
    integer delay=0,ddelay=0,cycles=0,endpoint_cycle=0,requests=0,responses=0;
    integer drequests=0,dresponses=0,accepted=0,retired=0,wb_packets=0,traps=0,redirects=0,bp_commits=0;
    integer stale_if_errors=0,held_fault_cycles=0,young_id_redirects=0,raw_waits=0;
    integer want_resolved=0,want_mispredict=0,want_direrr=0,want_tgterr=0;
    integer fd_trace,fd_accept,fd_events,fd_d,fd_i,fd_trap,fd_desc,fd_metrics,fd_ram,fd_gpr;
    integer g,i,j,k,owner,owners,mem_count,drain_cycles=0;
    reg [31:0] program_words[0:255],expected_pc[0:63],expected_instr[0:63],expected_rd[0:63];
    reg [31:0] expected_value[0:63],expected_writes[0:63],expected_nextpc[0:63];
    reg [31:0] ram_words[0:7],ram_final[0:7],final_gpr[0:31],final_gpr_mask[0:31];
    reg [31:0] gold_pc[0:3],gold_addr[0:3],gold_wdata[0:3],gold_wstrb[0:3];
    reg [31:0] gold_size[0:3],gold_write[0:3],gold_rdata[0:3],gold_error[0:3];
    reg [31:0] gold_trap_pc[0:0],gold_trap_instr[0:0],gold_cause[0:0],gold_tval[0:0],gold_target[0:0];
    reg [63:0] accept_seq[0:127],retired_seq[0:63],last_retire_seq=0,fault_seq;
    reg [31:0] accept_pc[0:127],accept_instr[0:127],accept_pred_next[0:127];
    reg accept_pred_taken[0:127],accept_pred_hit[0:127],accept_retired[0:127];
    reg req_held=0,rsp_held=0,dheld=0;reg [31:0] saved_request;reg [32:0] saved_response;reg [70:0] dsaved;
    reg fire_retire,fire_trap;reg [63:0] before_instret,pre_seq,pre_trap_seq;
    reg [31:0] pre_pc,pre_instr,pre_rd,pre_value,pre_next,pre_trap_pc,pre_trap_instr,pre_cause,pre_tval;
    reg pre_writes,calc_branch,calc_jal,calc_jalr,calc_taken;reg [31:0] calc_target;
    string fixture_name,case_dir,prefix;
    always @* begin response_data=32'h0000006f;
        if(addr[1:0]==0 && addr[31:2]<256)response_data=program_words[addr[31:2]];end
    wire response_error=((KIND==0)&&(addr==12||addr==16))||((KIND==1)&&(addr==16));
    assign qr=rst_n&&!quiesce&&(!pending||(sv&&sr))&&(!WAIT||endpoint_cycle%7>=2)&&
        (!(KIND==1&&qa==16)||traps>0);
    assign sv=pending&&delay==0;
    assign dsv=dpending&&ddelay==0;
    assign dqr=rst_n&&(!dpending||(dsv&&dsr))&&(!WAIT||endpoint_cycle%5>=2);
    always @(posedge clk)if(rst_n)endpoint_cycle<=endpoint_cycle+1;
    cpu5_top #(.PROGRAM_FILE("programs/data_handshake_blank.hex"),.IMEM_WORDS(256),.DMEM_WORDS(8),
        .SKELETON_ONLY(0),.ENABLE_FORWARDING(1),.ENABLE_CONTROL_FLOW(1),.ENABLE_RAM(1),
        .ENABLE_SYNC_TRAPS(1),.TRAP_VECTOR(32'h100),.ENABLE_BRANCH_PRED(PRED),.BRANCH_RESOLVE_IN_ID(ID_MODE)) dut(.irq_software(1'b0),.irq_timer(1'b0),
        .clk(clk),.rst_n(rst_n),.pc_x(),.instr_x(),.valid_x(),.wb_pc(wpc),.wb_rd(wrd),.wb_data(wdata),.wb_we(we),
        .retire_valid(rv),.cycle_count(cc),.instret_count(ic),.uart_tx(tx),.uart_rx(1'b1),
        .gpio_in(8'hff),.gpio_out(gout),.gpio_oe(goe),.dmem_req_valid(dqv),.dmem_req_ready(dqr),
        .dmem_req_write(dqw),.dmem_req_addr(dqa),.dmem_req_size(dz),.dmem_req_wdata(dqd),.dmem_req_wstrb(dst),
        .dmem_rsp_valid(dsv),.dmem_rsp_ready(dsr),.dmem_rsp_rdata(drdata),.dmem_rsp_error(derror_q),.dmem_fault(df),
        .imem_req_valid(qv),.imem_req_ready(qr),.imem_req_addr(qa),.imem_rsp_valid(sv),.imem_rsp_ready(sr),
        .imem_rsp_rdata(response_data),.imem_rsp_error(response_error),.imem_fault(ifault),.imem_fault_pc(ifpc),
        .trap_valid(tf),.trap_pc(tpc),.trap_cause(tc),.trap_tval(tv),.bp_lookup_count(),.bp_hit_count(),.bp_taken_count(),
        .bp_resolved_count(resolved),.bp_mispredict_count(mispredict),.bp_direction_error_count(direction_error),
        .bp_target_error_count(target_error),.irq_external(1'b1),.perf_cycle_events(perf));
    initial begin
        wait(start);
        fixture_name=$sformatf("kind%0d",KIND);prefix={BASE,"/",fixture_name,"/"};
        mem_count=(KIND==10||KIND==11||KIND==12)?4:3;
        $readmemh({prefix,"program.hex"},program_words,0,255);
        $readmemh({prefix,"expected_pc.hex"},expected_pc,0,63);$readmemh({prefix,"expected_instr.hex"},expected_instr,0,63);
        $readmemh({prefix,"expected_rd.hex"},expected_rd,0,63);$readmemh({prefix,"expected_value.hex"},expected_value,0,63);
        $readmemh({prefix,"expected_writes.hex"},expected_writes,0,63);$readmemh({prefix,"expected_nextpc.hex"},expected_nextpc,0,63);
        $readmemh({prefix,"expected_trap_pc.hex"},gold_trap_pc,0,0);$readmemh({prefix,"expected_trap_instr.hex"},gold_trap_instr,0,0);
        $readmemh({prefix,"expected_trap_cause.hex"},gold_cause,0,0);$readmemh({prefix,"expected_trap_tval.hex"},gold_tval,0,0);
        $readmemh({prefix,"expected_trap_target.hex"},gold_target,0,0);
        $readmemh({prefix,"ram_initial.hex"},ram_words,0,7);$readmemh({prefix,"ram_final.hex"},ram_final,0,7);
        $readmemh({prefix,"final_gpr.hex"},final_gpr,0,31);$readmemh({prefix,"final_gpr_mask.hex"},final_gpr_mask,0,31);
        $readmemh({prefix,"expected_mem_pc.hex"},gold_pc,0,mem_count-1);$readmemh({prefix,"expected_mem_addr.hex"},gold_addr,0,mem_count-1);
        $readmemh({prefix,"expected_mem_wdata.hex"},gold_wdata,0,mem_count-1);$readmemh({prefix,"expected_mem_wstrb.hex"},gold_wstrb,0,mem_count-1);
        $readmemh({prefix,"expected_mem_size.hex"},gold_size,0,mem_count-1);$readmemh({prefix,"expected_mem_is_write.hex"},gold_write,0,mem_count-1);
        $readmemh({prefix,"expected_mem_rdata.hex"},gold_rdata,0,mem_count-1);$readmemh({prefix,"expected_mem_error.hex"},gold_error,0,mem_count-1);
        case_dir=$sformatf("%s/cases/case%0d",BASE,CASE_ID);
        fd_trace=$fopen({case_dir,"/trace.csv"},"w");fd_accept=$fopen({case_dir,"/accept.csv"},"w");
        fd_events=$fopen({case_dir,"/events.csv"},"w");fd_d=$fopen({case_dir,"/d.csv"},"w");fd_i=$fopen({case_dir,"/if.csv"},"w");
        fd_trap=$fopen({case_dir,"/traps.csv"},"w");fd_desc=$fopen({case_dir,"/descriptor.json"},"w");
        if(!fd_trace||!fd_accept||!fd_events||!fd_d||!fd_i||!fd_trap||!fd_desc)$fatal(1,"Trace file open case=%0d",CASE_ID);
        $fwrite(fd_trace,"kind,cycle,index,seq,pc,instr,rd,value,writes,instret,nextpc\n");
        $fwrite(fd_accept,"cycle,seq,pc,instr\n");
        $fwrite(fd_events,"cycle,event,seq,pc,nextpc,target,taken,pred_next,pred_taken,is_branch,is_jal,is_jalr\n");
        $fwrite(fd_d,"event,cycle,seq,pc,addr,wdata,wstrb,size,is_write,rdata,error\n");
        $fwrite(fd_i,"event,cycle,addr,error\n");$fwrite(fd_trap,"cycle,seq,pc,instr,cause,tval,target\n");
        $fwrite(fd_desc,"{\"case\":%0d,\"kind\":%0d,\"id_mode\":%0d,\"predict\":%0d,\"wait\":%0d,\"fixture_name\":\"%s\"}\n",CASE_ID,KIND,ID_MODE,PRED,WAIT,fixture_name);$fclose(fd_desc);
        repeat(4)@(negedge clk);rst_n=1;
        if(CASE_ID==103)dut.u_if_adapter.next_seq_q=64'h00000000fffffffc;
    end
    always @(posedge clk)if(rst_n&&!done)begin
        cycles=cycles+1;
        if({gout,goe,perf}!==0||tx!==1)$fatal(1,"Unsupported side effect case=%0d",CASE_ID);
        if(KIND!=0&&ifault)$fatal(1,"Stale/unexpected IF error became architectural case=%0d pc=%h",CASE_ID,ifpc);
        if(req_held&&(!qv||qa!==saved_request))$fatal(1,"I held request changed case=%0d",CASE_ID);
        req_held=qv&&!qr;saved_request=qa;
        if(KIND==1&&qv&&qa==16&&!qr&&traps==0)held_fault_cycles=held_fault_cycles+1;
        if(rsp_held&&(!sv||{response_error,response_data}!==saved_response))$fatal(1,"I held response changed case=%0d",CASE_ID);
        rsp_held=sv&&!sr;saved_response={response_error,response_data};
        if(sv&&sr)begin
            if(!pending)$fatal(1,"I response lacks owner case=%0d",CASE_ID);
            $fwrite(fd_i,"rsp,%0d,%08h,%0d\n",cycles,addr,response_error);
            if(response_error&&traps>0)stale_if_errors=stale_if_errors+1;
            pending<=0;responses=responses+1;
        end
        if(pending&&delay>0)delay<=delay-1;
        if(qv&&qr)begin
            if(qa[1:0]!=0||qa[31:2]>=256||(pending&&!(sv&&sr)))$fatal(1,"I owner/address case=%0d",CASE_ID);
            $fwrite(fd_i,"req,%0d,%08h,0\n",cycles,qa);
            addr<=qa;pending<=1;delay<=WAIT?(requests%4):0;requests=requests+1;
        end
        if(dheld&&(!dqv||{dqw,dqa,dz,dqd,dst}!==dsaved))$fatal(1,"D held request changed case=%0d",CASE_ID);
        dheld=dqv&&!dqr;dsaved={dqw,dqa,dz,dqd,dst};
        if(dsv&&dsr)begin
            if(!dpending||dut.g_alu.u_pipeline.ram_rsp_seq!==dseq_q||dut.g_alu.u_pipeline.ram_rsp_pc!==dpc_q)
                $fatal(1,"D response owner changed case=%0d",CASE_ID);
            $fwrite(fd_d,"rsp,%0d,%016h,%08h,%08h,%08h,%01h,%0d,%0d,%08h,%0d\n",cycles,dseq_q,dpc_q,daddr_q,dwdata_q,dstrb_q,dsize_q,dwrite_q,drdata,derror_q);
            dpending<=0;dresponses=dresponses+1;
        end
        if(dpending&&ddelay>0)ddelay<=ddelay-1;
        if(dqv&&dqr)begin
            if(drequests>=mem_count||(dpending&&!(dsv&&dsr)))$fatal(1,"Unexpected D request/overwrite case=%0d pc=%h",CASE_ID,dut.g_alu.u_pipeline.ram_req_pc);
            if(dqa!==gold_addr[drequests]||dqw!==(gold_write[drequests]!=0)||dz!==gold_size[drequests][1:0]||dst!==gold_wstrb[drequests][3:0]||dqd!==gold_wdata[drequests])
                $fatal(1,"D descriptor case=%0d index=%0d addr=%h wdata=%h",CASE_ID,drequests,dqa,dqd);
            if(dut.g_alu.u_pipeline.ram_req_pc!==gold_pc[drequests]||dut.g_alu.u_pipeline.ram_req_instr!==program_words[gold_pc[drequests]>>2])
                $fatal(1,"D instruction owner case=%0d",CASE_ID);
            j=(dqa-32'h10000)>>2;
            if(j<0||j>=8||ram_words[j]!==gold_rdata[drequests])$fatal(1,"D response fixture word case=%0d index=%0d",CASE_ID,drequests);
            drdata<=ram_words[j];derror_q<=gold_error[drequests]!=0;daddr_q<=dqa;dwdata_q<=dqd;dstrb_q<=dst;dsize_q<=dz;dwrite_q<=dqw;
            dseq_q<=dut.g_alu.u_pipeline.ram_req_seq;dpc_q<=dut.g_alu.u_pipeline.ram_req_pc;
            $fwrite(fd_d,"req,%0d,%016h,%08h,%08h,%08h,%01h,%0d,%0d,00000000,0\n",cycles,dut.g_alu.u_pipeline.ram_req_seq,dut.g_alu.u_pipeline.ram_req_pc,dqa,dqd,dst,dz,dqw);
            if(dqw&&!gold_error[drequests])for(k=0;k<4;k=k+1)if(dst[k])ram_words[j][k*8+:8]=dqd[k*8+:8];
            dpending<=1;ddelay<=(KIND==12&&gold_pc[drequests]==12)?16:(WAIT?(drequests%6):0);drequests=drequests+1;
        end
        if(dut.g_alu.u_pipeline.id_raw_wait)raw_waits=raw_waits+1;
        if(dut.ifid_valid_q&&dut.ifid_ready)begin
            if(accepted>=128||(accepted>0&&dut.ifid_q.seq<=accept_seq[accepted-1]))$fatal(1,"Accepted sequence order/overflow case=%0d",CASE_ID);
            accept_seq[accepted]=dut.ifid_q.seq;accept_pc[accepted]=dut.ifid_q.pc;accept_instr[accepted]=dut.ifid_q.instr;
            accept_pred_next[accepted]=dut.ifid_q.pred_next_pc;accept_pred_taken[accepted]=dut.ifid_q.pred_taken;accept_pred_hit[accepted]=dut.ifid_q.pred_hit;accept_retired[accepted]=0;
            $fwrite(fd_accept,"%0d,%016h,%08h,%08h\n",cycles,dut.ifid_q.seq,dut.ifid_q.pc,dut.ifid_q.instr);accepted=accepted+1;
        end
        fire_trap=dut.g_alu.u_pipeline.trap_fire;fire_retire=dut.g_alu.u_pipeline.retire_fire;before_instret=ic;
        if(dut.unused_bp_update!==(PRED&&fire_retire))$fatal(1,"BP qualifier case=%0d",CASE_ID);
        if(fire_trap)begin
            if(traps!=0||fire_retire||dut.unused_bp_update||dut.g_alu.u_pipeline.id_move||dut.g_alu.u_pipeline.ex_move||dut.g_alu.u_pipeline.ram_issue_fire)
                $fatal(1,"Trap precise edge case=%0d",CASE_ID);
            pre_trap_seq=dut.g_alu.u_pipeline.exmem_q.seq;pre_trap_pc=dut.g_alu.u_pipeline.exmem_q.pc;pre_trap_instr=dut.g_alu.u_pipeline.exmem_q.instr;
            pre_cause=dut.g_alu.u_pipeline.halt_cause;pre_tval=dut.g_alu.u_pipeline.halt_tval;
            if(pre_trap_pc!==gold_trap_pc[0]||pre_trap_instr!==gold_trap_instr[0]||pre_cause!==gold_cause[0]||pre_tval!==gold_tval[0]||retired!=3)
                $fatal(1,"Trap descriptor/old retirement case=%0d pc=%h instr=%h cause=%h tval=%h retired=%0d",CASE_ID,pre_trap_pc,pre_trap_instr,pre_cause,pre_tval,retired);
            owners=0;for(i=0;i<accepted;i=i+1)if(accept_seq[i]==pre_trap_seq&&accept_pc[i]==pre_trap_pc&&accept_instr[i]==pre_trap_instr)owners=owners+1;
            if(owners!=1||!dut.alu_redirect||!dut.alu_redirect_kill||dut.alu_redirect_pc!==32'h100||dut.alu_redirect_seq!==pre_trap_seq)
                $fatal(1,"Trap age/vector redirect case=%0d",CASE_ID);
            fault_seq=pre_trap_seq;traps=traps+1;
            $fwrite(fd_trap,"%0d,%016h,%08h,%08h,%08h,%08h,00000100\n",cycles,pre_trap_seq,pre_trap_pc,pre_trap_instr,pre_cause,pre_tval);
        end
        if(dut.alu_redirect&&!fire_trap)begin
            if(!dut.unused_redirect_ready||dut.alu_redirect_kill!==!ID_MODE)$fatal(1,"Normal redirect handshake case=%0d",CASE_ID);
            if(ID_MODE)begin
                if(!dut.g_alu.u_pipeline.id_move||dut.alu_redirect_seq!==dut.ifid_q.seq)$fatal(1,"ID redirect owner case=%0d",CASE_ID);
                if(dut.ifid_q.pc==12)$fatal(1,"Faulting branch redirected case=%0d",CASE_ID);
                if(dut.ifid_q.pc==16&&KIND==12)young_id_redirects=young_id_redirects+1;
                $fwrite(fd_events,"%0d,redirect,%016h,%08h,%08h,%08h,%0d,%08h,%0d,%0d,%0d,%0d\n",cycles,dut.alu_redirect_seq,dut.ifid_q.pc,dut.alu_redirect_pc,dut.g_alu.u_pipeline.id_target,dut.g_alu.u_pipeline.id_taken,dut.ifid_q.pred_next_pc,dut.ifid_q.pred_taken,dut.g_alu.u_pipeline.cf_branch,dut.g_alu.u_pipeline.cf_jal,dut.g_alu.u_pipeline.cf_jalr);
            end else begin
                if(!dut.g_alu.u_pipeline.ex_move||dut.ifid_ready||dut.alu_redirect_seq!==dut.g_alu.u_pipeline.idex_q.seq)$fatal(1,"EX redirect owner case=%0d",CASE_ID);
                if(dut.g_alu.u_pipeline.idex_q.pc==12)$fatal(1,"Faulting EX branch redirected case=%0d",CASE_ID);
                $fwrite(fd_events,"%0d,redirect,%016h,%08h,%08h,%08h,%0d,%08h,%0d,%0d,%0d,%0d\n",cycles,dut.alu_redirect_seq,dut.g_alu.u_pipeline.idex_q.pc,dut.alu_redirect_pc,dut.g_alu.u_pipeline.ex_branch_target,dut.g_alu.u_pipeline.ex_branch_taken,dut.g_alu.u_pipeline.idex_q.pred_next_pc,dut.g_alu.u_pipeline.idex_q.pred_taken,dut.g_alu.u_pipeline.idex_q.is_branch,dut.g_alu.u_pipeline.idex_q.is_jal,dut.g_alu.u_pipeline.idex_q.is_jalr);
            end
            redirects=redirects+1;
        end
        if(dut.g_alu.u_pipeline.wb_fire)begin
            if(wb_packets>=retired||dut.g_alu.u_pipeline.memwb_q.seq!==retired_seq[wb_packets]||wpc!==expected_pc[wb_packets]||dut.g_alu.u_pipeline.memwb_q.instr!==expected_instr[wb_packets]||wrd!==expected_rd[wb_packets][4:0]||wdata!==expected_value[wb_packets]||we!==(expected_writes[wb_packets]!=0))$fatal(1,"WB identity/value case=%0d index=%0d",CASE_ID,wb_packets);
            $fwrite(fd_trace,"wb,%0d,%0d,%016h,%08h,%08h,%0d,%08h,%0d,%0d,%08h\n",cycles,wb_packets,dut.g_alu.u_pipeline.memwb_q.seq,wpc,dut.g_alu.u_pipeline.memwb_q.instr,wrd,wdata,we,ic,dut.g_alu.u_pipeline.arch_next_pc_q);wb_packets=wb_packets+1;
        end
        if(fire_retire)begin
            if(retired>=64)$fatal(1,"Retirement overflow case=%0d",CASE_ID);
            pre_seq=dut.g_alu.u_pipeline.exmem_q.seq;pre_pc=dut.g_alu.u_pipeline.exmem_q.pc;pre_instr=dut.g_alu.u_pipeline.exmem_q.instr;
            pre_rd=dut.g_alu.u_pipeline.exmem_q.rd;pre_value=dut.g_alu.u_pipeline.mem_result_value;pre_writes=dut.g_alu.u_pipeline.exmem_q.writes_rd&&pre_rd!=0;pre_next=dut.g_alu.u_pipeline.exmem_q.actual_next_pc;
            if(pre_pc!==expected_pc[retired]||pre_instr!==expected_instr[retired]||pre_rd!==expected_rd[retired]||pre_value!==expected_value[retired]||pre_writes!==(expected_writes[retired]!=0)||pre_next!==expected_nextpc[retired])$fatal(1,"MEM gold case=%0d index=%0d pc=%h instr=%h value=%h next=%h",CASE_ID,retired,pre_pc,pre_instr,pre_value,pre_next);
            if(retired>0&&pre_seq<=last_retire_seq)$fatal(1,"Retirement age case=%0d",CASE_ID);
            owners=0;owner=-1;for(i=0;i<accepted;i=i+1)if(accept_seq[i]==pre_seq)begin owners=owners+1;owner=i;end
            if(owners!=1||accept_retired[owner]||accept_pc[owner]!==pre_pc||accept_instr[owner]!==pre_instr)$fatal(1,"Retire accepted identity case=%0d",CASE_ID);
            if(dut.g_alu.u_pipeline.exmem_q.pred_next_pc!==accept_pred_next[owner]||dut.g_alu.u_pipeline.exmem_q.pred_taken!==accept_pred_taken[owner]||dut.g_alu.u_pipeline.exmem_q.pred_hit!==accept_pred_hit[owner])$fatal(1,"Prediction descriptor owner case=%0d",CASE_ID);
            accept_retired[owner]=1;last_retire_seq=pre_seq;
            calc_branch=pre_instr[6:0]==7'h63;calc_jal=pre_instr[6:0]==7'h6f;calc_jalr=pre_instr[6:0]==7'h67;
            calc_taken=calc_branch||calc_jal||calc_jalr;calc_target=calc_jal?32'h114:pre_pc+4;
            if(PRED)begin
                if(calc_branch||calc_jal||calc_jalr)want_resolved=want_resolved+1;
                if(accept_pred_next[owner]!=pre_next)want_mispredict=want_mispredict+1;
                if((calc_branch||calc_jal||calc_jalr)&&accept_pred_taken[owner]!=calc_taken)want_direrr=want_direrr+1;
                if((calc_branch||calc_jal||calc_jalr)&&calc_taken&&accept_pred_taken[owner]&&accept_pred_next[owner]!=pre_next)want_tgterr=want_tgterr+1;
                if(dut.alu_bp_pc!==pre_pc||dut.alu_bp_seq!==pre_seq||dut.alu_bp_target!==calc_target||dut.alu_bp_taken!==calc_taken||dut.alu_bp_branch!==calc_branch||dut.alu_bp_jal!==calc_jal)$fatal(1,"BP successful owner descriptor case=%0d",CASE_ID);
                $fwrite(fd_events,"%0d,bp,%016h,%08h,%08h,%08h,%0d,%08h,%0d,%0d,%0d,%0d\n",cycles,pre_seq,pre_pc,pre_next,calc_target,calc_taken,accept_pred_next[owner],accept_pred_taken[owner],calc_branch,calc_jal,calc_jalr);bp_commits=bp_commits+1;
            end
        end
        #1;
        if(rv!==fire_retire||tf!==fire_trap||ic!==before_instret+(fire_retire?1:0))$fatal(1,"Registered retirement/trap/count alignment case=%0d",CASE_ID);
        if(fire_trap)begin
            if(tpc!==pre_trap_pc||tc!==pre_cause||tv!==pre_tval||dut.g_alu.u_pipeline.trap_seq!==pre_trap_seq||dut.g_alu.u_pipeline.arch_next_pc_q!==32'h100)$fatal(1,"Registered trap descriptor case=%0d",CASE_ID);
            if(dut.g_alu.u_pipeline.idex_valid_q||dut.g_alu.u_pipeline.exmem_valid_q)$fatal(1,"Younger pipeline not flushed case=%0d",CASE_ID);
        end
        if(traps&&{tpc,tc,tv}!={gold_trap_pc[0],gold_cause[0],gold_tval[0]})$fatal(1,"Persistent trap descriptor case=%0d",CASE_ID);
        if(resolved!==want_resolved||mispredict!==want_mispredict||direction_error!==want_direrr||target_error!==want_tgterr)$fatal(1,"BP counters case=%0d actual=%0d/%0d/%0d/%0d want=%0d/%0d/%0d/%0d retire=%0d pc=%h",CASE_ID,resolved,mispredict,direction_error,target_error,want_resolved,want_mispredict,want_direrr,want_tgterr,retired,pre_pc);
        if(rv)begin
            if(dut.g_alu.u_pipeline.retire_pc!==pre_pc||dut.g_alu.u_pipeline.retire_instr!==pre_instr||dut.g_alu.u_pipeline.retire_seq!==pre_seq||dut.g_alu.u_pipeline.retire_rd!==pre_rd[4:0]||dut.g_alu.u_pipeline.retire_value!==pre_value||dut.g_alu.u_pipeline.retire_writes_rd!==pre_writes||dut.g_alu.u_pipeline.arch_next_pc_q!==pre_next)$fatal(1,"Registered retirement descriptor case=%0d",CASE_ID);
            retired_seq[retired]=pre_seq;$fwrite(fd_trace,"retire,%0d,%0d,%016h,%08h,%08h,%0d,%08h,%0d,%0d,%08h\n",cycles,retired,pre_seq,pre_pc,pre_instr,pre_rd,pre_value,pre_writes,ic,pre_next);retired=retired+1;
        end
        if(wb_packets>=9&&traps==1&&drequests==mem_count&&dresponses==mem_count&&!dpending&&!dut.g_alu.u_pipeline.ram_owner_valid)quiesce<=1;
        if(quiesce&&!pending&&!dut.ifid_valid_q&&!dut.g_alu.u_pipeline.idex_valid_q&&!dut.g_alu.u_pipeline.exmem_valid_q&&!dut.g_alu.u_pipeline.memwb_valid_q)drain_cycles=drain_cycles+1;else drain_cycles=0;
        if(drain_cycles==3)begin
            if(retired!=wb_packets||ic!=retired||traps!=1||requests!=responses||drequests!=mem_count||dresponses!=mem_count||bp_commits!=(PRED?retired:0))$fatal(1,"Final closure case=%0d retire=%0d WB=%0d I=%0d/%0d D=%0d/%0d",CASE_ID,retired,wb_packets,requests,responses,drequests,dresponses);
            if(KIND==1&&(held_fault_cycles==0||stale_if_errors==0))$fatal(1,"Missing held stale IF scenario case=%0d",CASE_ID);
            if(KIND==12&&ID_MODE&&young_id_redirects==0)$fatal(1,"Missing younger ID redirect before older LOAD error case=%0d",CASE_ID);
            fd_ram=$fopen({case_dir,"/actual_ram_final.hex"},"w");for(g=0;g<8;g=g+1)begin if(ram_words[g]!==ram_final[g])$fatal(1,"Final RAM case=%0d word=%0d",CASE_ID,g);$fwrite(fd_ram,"%08h\n",ram_words[g]);end $fclose(fd_ram);
            fd_gpr=$fopen({case_dir,"/actual_gpr_final.hex"},"w");$fwrite(fd_gpr,"00000000\n");for(g=1;g<32;g=g+1)begin if(final_gpr_mask[g]&&dut.g_alu.u_pipeline.u_regfile.regs[g]!==final_gpr[g])$fatal(1,"Final GPR case=%0d x%0d",CASE_ID,g);$fwrite(fd_gpr,"%08h\n",dut.g_alu.u_pipeline.u_regfile.regs[g]);end $fclose(fd_gpr);
            fd_metrics=$fopen({case_dir,"/metrics.json"},"w");
            $fwrite(fd_metrics,"{\"retired\":%0d,\"wb_packets\":%0d,\"accepted\":%0d,\"redirects\":%0d,\"bp_commits\":%0d,\"cycles\":%0d,\"requests\":%0d,\"responses\":%0d,\"raw_wait_cycles\":%0d,\"resolved\":%0d,\"mispredict\":%0d,\"direction_error\":%0d,\"target_error\":%0d,\"d_requests\":%0d,\"d_responses\":%0d,\"traps\":%0d,\"fault_seq\":\"%016h\",\"stale_if_errors\":%0d,\"held_fault_cycles\":%0d,\"young_id_redirects\":%0d,\"unaccepted_i_held\":%0d}\n",retired,wb_packets,accepted,redirects,bp_commits,cycles,requests,responses,raw_waits,resolved,mispredict,direction_error,target_error,drequests,dresponses,traps,fault_seq,stale_if_errors,held_fault_cycles,young_id_redirects,qv&&!qr);$fclose(fd_metrics);
            $fclose(fd_trace);$fclose(fd_accept);$fclose(fd_events);$fclose(fd_d);$fclose(fd_i);$fclose(fd_trap);done=1;
            $display("CPU5 TRAP CASE PASS case=%0d kind=%0d ID=%0d BP=%0d WAIT=%0d retire=%0d D=%0d trap=1",CASE_ID,KIND,ID_MODE,PRED,WAIT,retired,drequests);
        end
    end
endmodule
