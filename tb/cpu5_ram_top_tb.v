`timescale 1ns/1ps

// End-to-end use of the unchanged IF, its age adapter and the opt-in CPU5.
// Golden files describe retirement, never speculative fetch sequence numbers.
module cpu5_ram_top_tb;
    wire [15:0] done;
    reg test_pass=0;
    genvar n;
    generate for(n=0;n<16;n=n+1)begin:g_cases
        cpu5_ram_top_case #(.CASE_ID(n),.ID_MODE(n%2),
            .PRED((n/2)%2),.WAIT((n/4)%2),.SEED(n/8)) u(done[n]);
    end endgenerate
    initial begin
        wait(&done);test_pass=1;
        $display("CPU5 RAM TOP PASS: 16 C cases, ID/EX, prediction and variable I/D waits");
        $stop;
    end
    initial begin #3000000;$fatal(1,"CPU5 RAM TOP timeout done=%h",done);end
endmodule

module cpu5_ram_top_case #(
    parameter CASE_ID=0,ID_MODE=0,PRED=0,WAIT=0,SEED=0,
    parameter BASE="build/cpu5_s5_ram"
)(output reg done=0);
    reg clk=0,rst_n=0,pending=0;
    always #10 clk=~clk;
    wire qv,qr,sv,sr,rv,we,dqv,dqw,dsr,df,tf,ifault,tx;
    wire [31:0] qa,wpc,wdata,dqa,dqd,tpc,tc,tv,ifpc;
    wire [31:0] resolved,mispredict,direction_error,target_error;
    wire [4:0] wrd;
    wire [1:0] dz;
    wire [3:0] dst;
    wire [63:0] cc,ic;
    wire [9:0] perf;
    wire [7:0] gout,goe;
    reg [31:0] addr=0,response_data;
    integer delay=0,cycles=0,endpoint_cycle=0,requests=0,responses=0,retired=0,wb_packets=0;
    integer accepted=0,redirects=0,bp_commits=0,raw_waits=0,halt_cycles=0;
    integer want_resolved=0,want_mispredict=0,want_direrr=0,want_tgterr=0;
    integer fd_trace,fd_accept,fd_events,fd_desc,fd_metrics,g,i,owner,owner_count;
    integer expected_count,program_count;
    string fixture_name,case_dir,prefix;
    reg [31:0] stop_pc,stop_instr,stop_tval,stop_cause;
    reg stop_fetch;
    reg [31:0] program_words[0:8191];
    reg [31:0] expected_pc[0:1599],expected_instr[0:1599];
    reg [31:0] expected_rd[0:1599],expected_value[0:1599];
    reg [31:0] expected_writes[0:1599],expected_nextpc[0:1599];
    reg [31:0] final_gpr[0:31],shadow_gpr[0:31];
    reg [31:0] written_mask=0;
    reg [63:0] accept_seq[0:8191],retired_seq[0:1599];
    reg [31:0] accept_pc[0:8191],accept_instr[0:8191],accept_pred_next[0:8191];
    reg accept_pred_taken[0:8191],accept_pred_hit[0:8191],accept_retired[0:8191];
    reg req_held=0,rsp_held=0;
    reg [31:0] saved_request;
    reg [32:0] saved_response;
    reg fire_retire;
    reg [63:0] before_instret,pre_seq,last_retire_seq=0;
    reg [31:0] pre_pc,pre_instr,pre_rd,pre_value,pre_next;
    reg pre_writes;
    reg [31:0] ram_words[0:4095],ram_final[0:4095];
    reg [31:0] gold_addr[0:399],gold_wdata[0:399],gold_wstrb[0:399],gold_size[0:399],gold_write[0:399],gold_rdata[0:399],gold_index[0:399];
    reg dpending=0,dheld=0;
    reg [70:0] dsaved;
    reg [31:0] drdata=0,daddr_q=0,dwdata_q=0,dpc_q=0;
    reg [63:0] dseq_q=0;
    reg [3:0] dstrb_q=0;reg [1:0] dsize_q=0;reg dwrite_q=0;
    integer ddelay=0,drequests=0,dresponses=0,mem_count,fd_d,fd_ram,j,k,turnovers=0;
    wire dsv=dpending && ddelay==0;
    wire dqr=rst_n && (!dpending || (dsv&&dsr)) && (!WAIT || endpoint_cycle%5>=2);
    reg calc_branch,calc_jal,calc_jalr,calc_taken;
    reg [31:0] calc_target,calc_imm,calc_next;
    // Explicit array sensitivity prevents a function retaining pre-readmemh X
    // when the first accepted ROM address remains zero.
    always @* begin
        response_data=32'h00002023;
        if(addr[1:0]==0 && addr[31:2]<8192)response_data=program_words[addr[31:2]];
    end
    wire response_error=stop_fetch && addr==stop_pc;
    // Only NBA state drives ready so the monitor and DUT sample the same value.
    always @(posedge clk)if(rst_n)endpoint_cycle<=endpoint_cycle+1;
    assign qr=rst_n && (!pending || (sv&&sr)) && (!WAIT || endpoint_cycle%7>=2);
    assign sv=pending && delay==0;
    cpu5_top #(.PROGRAM_FILE("programs/data_handshake_blank.hex"),.IMEM_WORDS(8192),
        .SKELETON_ONLY(0),.ENABLE_FORWARDING(1),.ENABLE_CONTROL_FLOW(1),.ENABLE_RAM(1),
        .ENABLE_BRANCH_PRED(PRED),.BRANCH_RESOLVE_IN_ID(ID_MODE)) dut(.irq_software(1'b0),.irq_timer(1'b0),
        .clk(clk),.rst_n(rst_n),.pc_x(),.instr_x(),.valid_x(),
        .wb_pc(wpc),.wb_rd(wrd),.wb_data(wdata),.wb_we(we),.retire_valid(rv),
        .cycle_count(cc),.instret_count(ic),.uart_tx(tx),.uart_rx(1'b1),
        .gpio_in(8'hff),.gpio_out(gout),.gpio_oe(goe),
        .dmem_req_valid(dqv),.dmem_req_ready(dqr),.dmem_req_write(dqw),.dmem_req_addr(dqa),
        .dmem_req_size(dz),.dmem_req_wdata(dqd),.dmem_req_wstrb(dst),
        .dmem_rsp_valid(dsv),.dmem_rsp_ready(dsr),.dmem_rsp_rdata(drdata),
        .dmem_rsp_error(1'b0),.dmem_fault(df),
        .imem_req_valid(qv),.imem_req_ready(qr),.imem_req_addr(qa),
        .imem_rsp_valid(sv),.imem_rsp_ready(sr),.imem_rsp_rdata(response_data),
        .imem_rsp_error(response_error),.imem_fault(ifault),.imem_fault_pc(ifpc),
        .trap_valid(tf),.trap_pc(tpc),.trap_cause(tc),.trap_tval(tv),
        .bp_lookup_count(),.bp_hit_count(),.bp_taken_count(),.bp_resolved_count(resolved),
        .bp_mispredict_count(mispredict),.bp_direction_error_count(direction_error),
        .bp_target_error_count(target_error),.irq_external(1'b1),.perf_cycle_events(perf));
    initial begin
        fixture_name=$sformatf("seed%0d",SEED);expected_count=SEED?1472:1468;program_count=8192;
        stop_pc=32'h88;stop_instr=32'h00100073;stop_tval=0;stop_cause=0;stop_fetch=0;
        prefix={BASE,"/",fixture_name,"/"};
        mem_count=SEED?360:358;
        for(g=0;g<8192;g=g+1)program_words[g]=32'h00100073;
        for(g=0;g<32;g=g+1)shadow_gpr[g]=32'hxxxxxxxx;
        shadow_gpr[0]=0;
        $readmemh({prefix,"program.hex"},program_words,0,program_count-1);
        $readmemh({prefix,"expected_pc.hex"},expected_pc,0,expected_count-1);
        $readmemh({prefix,"expected_instr.hex"},expected_instr,0,expected_count-1);
        $readmemh({prefix,"expected_rd.hex"},expected_rd,0,expected_count-1);
        $readmemh({prefix,"expected_value.hex"},expected_value,0,expected_count-1);
        $readmemh({prefix,"expected_writes.hex"},expected_writes,0,expected_count-1);
        $readmemh({prefix,"expected_nextpc.hex"},expected_nextpc,0,expected_count-1);
        $readmemh({prefix,"final_gpr.hex"},final_gpr,0,31);
        $readmemh({prefix,"ram_initial.hex"},ram_words,0,4095);
        $readmemh({prefix,"ram_final.hex"},ram_final,0,4095);
        $readmemh({prefix,"expected_mem_addr.hex"},gold_addr,0,mem_count-1);
        $readmemh({prefix,"expected_mem_wdata.hex"},gold_wdata,0,mem_count-1);
        $readmemh({prefix,"expected_mem_wstrb.hex"},gold_wstrb,0,mem_count-1);
        $readmemh({prefix,"expected_mem_size.hex"},gold_size,0,mem_count-1);
        $readmemh({prefix,"expected_mem_is_write.hex"},gold_write,0,mem_count-1);
        $readmemh({prefix,"expected_mem_rdata.hex"},gold_rdata,0,mem_count-1);
        $readmemh({prefix,"expected_mem_index.hex"},gold_index,0,mem_count-1);
        case_dir=$sformatf("%s/cases/case%0d",BASE,CASE_ID);
        fd_d=$fopen({case_dir,"/d.csv"},"w");
        if(fd_d==0)$fatal(1,"Cannot open D ledger");
        $fwrite(fd_d,"event,cycle,seq,pc,addr,wdata,wstrb,size,is_write,rdata,error\n");
        fd_trace=$fopen({case_dir,"/trace.csv"},"w");
        fd_accept=$fopen({case_dir,"/accept.csv"},"w");
        fd_events=$fopen({case_dir,"/events.csv"},"w");
        fd_desc=$fopen({case_dir,"/descriptor.json"},"w");
        if(fd_trace==0 || fd_accept==0 || fd_events==0 || fd_desc==0)$fatal(1,"Cannot open case files case=%0d",CASE_ID);
        $fwrite(fd_trace,"kind,cycle,index,seq,pc,instr,rd,value,writes,instret,nextpc\n");
        $fwrite(fd_accept,"cycle,seq,pc,instr\n");
        $fwrite(fd_events,"cycle,event,seq,pc,nextpc,target,taken,pred_next,pred_taken,is_branch,is_jal,is_jalr\n");
        $fwrite(fd_desc,"{\"case\":%0d,\"id_mode\":%0d,\"predict\":%0d,\"wait\":%0d,\"fixture_name\":\"%s\"}\n",CASE_ID,ID_MODE,PRED,WAIT,fixture_name);
        $fclose(fd_desc);
        repeat(4)@(negedge clk);rst_n=1;
        if(CASE_ID==7)dut.u_if_adapter.next_seq_q=64'h00000000fffffffc;
    end
    always @(posedge clk)if(rst_n&&!done)begin
        cycles=cycles+1;
        if({df,tf,tpc,tc,tv,gout,goe,perf}!==0 || tx!==1)
            $fatal(1,"Unsupported architectural side effect case=%0d",CASE_ID);
        if(!stop_fetch && ifault)$fatal(1,"Unexpected raw IF fault case=%0d pc=%h",CASE_ID,ifpc);
        if(req_held && (!qv || qa!==saved_request))$fatal(1,"I request changed under stall case=%0d",CASE_ID);
        req_held=qv&&!qr;saved_request=qa;
        if(rsp_held && (!sv || {response_error,response_data}!==saved_response))
            $fatal(1,"I response changed under stall case=%0d",CASE_ID);
        rsp_held=sv&&!sr;saved_response={response_error,response_data};
        if(sv&&sr)begin
            if(!pending)$fatal(1,"I response without owner case=%0d",CASE_ID);
            pending<=0;responses=responses+1;
        end
        if(pending && delay>0)delay<=delay-1;
        if(qv&&qr)begin
            if(qa[1:0]!=0 || qa[31:2]>=8192)$fatal(1,"I address outside fixture ROM case=%0d pc=%h",CASE_ID,qa);
            if(pending && !(sv&&sr))$fatal(1,"I new request overwrote owner case=%0d",CASE_ID);
            addr<=qa;pending<=1;delay<=WAIT?(requests%4):0;requests=requests+1;
        end
        if(dheld && (!dqv || {dqw,dqa,dz,dqd,dst}!==dsaved))$fatal(1,"D request changed under stall case=%0d",CASE_ID);
        dheld=dqv&&!dqr;dsaved={dqw,dqa,dz,dqd,dst};
        if(dsv&&dsr)begin
            if(!dpending || dut.g_alu.u_pipeline.ram_rsp_seq!==dseq_q || dut.g_alu.u_pipeline.ram_rsp_pc!==dpc_q)
                $fatal(1,"D response owner changed case=%0d",CASE_ID);
            $fwrite(fd_d,"rsp,%0d,%016h,%08h,%08h,%08h,%01h,%0d,%0d,%08h,0\n",cycles,dseq_q,dpc_q,daddr_q,dwdata_q,dstrb_q,dsize_q,dwrite_q,drdata);
            dpending<=0;dresponses=dresponses+1;
            if(dqv&&dqr)turnovers=turnovers+1;
        end
        if(dpending && ddelay>0)ddelay<=ddelay-1;
        if(dqv&&dqr)begin
            if(drequests>=mem_count || dqa<32'h10000 || dqa>=32'h14000)$fatal(1,"D request outside golden RAM case=%0d",CASE_ID);
            if(dpending && !(dsv&&dsr))$fatal(1,"D owner overwrite case=%0d",CASE_ID);
            if(dqa!==gold_addr[drequests] || dqw!==(gold_write[drequests]!=0) || dz!==gold_size[drequests][1:0] || dst!==gold_wstrb[drequests][3:0])
                $fatal(1,"D request descriptor case=%0d index=%0d addr=%h expected=%h",CASE_ID,drequests,dqa,gold_addr[drequests]);
            for(k=0;k<4;k=k+1)if(dst[k] && dqd[k*8+:8]!==gold_wdata[drequests][k*8+:8])$fatal(1,"D store byte mismatch case=%0d index=%0d",CASE_ID,drequests);
            if(dut.g_alu.u_pipeline.ram_req_pc!==expected_pc[gold_index[drequests]] || dut.g_alu.u_pipeline.ram_req_instr!==expected_instr[gold_index[drequests]])
                $fatal(1,"D request not owned by golden memory instruction case=%0d",CASE_ID);
            j=(dqa-32'h10000)>>2;
            if(!dqw && ram_words[j]!==gold_rdata[drequests])$fatal(1,"D read word mismatch case=%0d index=%0d",CASE_ID,drequests);
            drdata<=ram_words[j];daddr_q<=dqa;dwdata_q<=dqd;dstrb_q<=dst;dsize_q<=dz;dwrite_q<=dqw;
            dseq_q<=dut.g_alu.u_pipeline.ram_req_seq;dpc_q<=dut.g_alu.u_pipeline.ram_req_pc;
            $fwrite(fd_d,"req,%0d,%016h,%08h,%08h,%08h,%01h,%0d,%0d,00000000,0\n",cycles,dut.g_alu.u_pipeline.ram_req_seq,dut.g_alu.u_pipeline.ram_req_pc,dqa,dqd,dst,dz,dqw);
            if(dqw)for(k=0;k<4;k=k+1)if(dst[k])ram_words[j][k*8+:8]=dqd[k*8+:8];
            dpending<=1;ddelay<=WAIT?(drequests%6):0;drequests=drequests+1;
        end
        if(dut.g_alu.u_pipeline.id_raw_wait)raw_waits=raw_waits+1;
        if(dut.ifid_valid_q && dut.ifid_ready)begin
            if(accepted>=8192)$fatal(1,"Accept ledger overflow");
            if(accepted>0 && dut.ifid_q.seq<=accept_seq[accepted-1])$fatal(1,"Nonmonotonic accept age case=%0d",CASE_ID);
            accept_seq[accepted]=dut.ifid_q.seq;accept_pc[accepted]=dut.ifid_q.pc;accept_instr[accepted]=dut.ifid_q.instr;
            accept_pred_next[accepted]=dut.ifid_q.pred_next_pc;accept_pred_taken[accepted]=dut.ifid_q.pred_taken;
            accept_pred_hit[accepted]=dut.ifid_q.pred_hit;accept_retired[accepted]=0;
            $fwrite(fd_accept,"%0d,%016h,%08h,%08h\n",cycles,dut.ifid_q.seq,dut.ifid_q.pc,dut.ifid_q.instr);
            accepted=accepted+1;
            if(dut.g_alu.u_pipeline.uses_rs1 && dut.g_alu.u_pipeline.rs1==0 && dut.g_alu.u_pipeline.rf1!==0)$fatal(1,"x0 rs1 case=%0d",CASE_ID);
            if(dut.g_alu.u_pipeline.uses_rs2 && dut.g_alu.u_pipeline.rs2==0 && dut.g_alu.u_pipeline.rf2!==0)$fatal(1,"x0 rs2 case=%0d",CASE_ID);
        end
        if(dut.alu_redirect)begin
            if(!dut.unused_redirect_ready || dut.alu_redirect_kill!==!ID_MODE)$fatal(1,"Redirect handshake case=%0d",CASE_ID);
            if(ID_MODE)begin
                if(!dut.g_alu.u_pipeline.id_move || dut.alu_redirect_seq!==dut.ifid_q.seq)$fatal(1,"ID redirect owner case=%0d",CASE_ID);
                if(dut.ifid_q.pc==stop_pc)$fatal(1,"Faulting ID source redirected case=%0d",CASE_ID);
                $fwrite(fd_events,"%0d,redirect,%016h,%08h,%08h,%08h,%0d,%08h,%0d,%0d,%0d,%0d\n",cycles,
                    dut.alu_redirect_seq,dut.ifid_q.pc,dut.alu_redirect_pc,dut.g_alu.u_pipeline.id_target,dut.g_alu.u_pipeline.id_taken,
                    dut.ifid_q.pred_next_pc,dut.ifid_q.pred_taken,dut.g_alu.u_pipeline.cf_branch,dut.g_alu.u_pipeline.cf_jal,dut.g_alu.u_pipeline.cf_jalr);
            end else begin
                if(!dut.g_alu.u_pipeline.ex_move || dut.alu_redirect_seq!==dut.g_alu.u_pipeline.idex_q.seq || dut.ifid_ready)
                    $fatal(1,"EX redirect owner/young admission case=%0d",CASE_ID);
                if(dut.g_alu.u_pipeline.idex_q.pc==stop_pc)$fatal(1,"Faulting EX source redirected case=%0d",CASE_ID);
                $fwrite(fd_events,"%0d,redirect,%016h,%08h,%08h,%08h,%0d,%08h,%0d,%0d,%0d,%0d\n",cycles,
                    dut.alu_redirect_seq,dut.g_alu.u_pipeline.idex_q.pc,dut.alu_redirect_pc,dut.g_alu.u_pipeline.ex_branch_target,
                    dut.g_alu.u_pipeline.ex_branch_taken,dut.g_alu.u_pipeline.idex_q.pred_next_pc,dut.g_alu.u_pipeline.idex_q.pred_taken,
                    dut.g_alu.u_pipeline.idex_q.is_branch,dut.g_alu.u_pipeline.idex_q.is_jal,dut.g_alu.u_pipeline.idex_q.is_jalr);
            end
            redirects=redirects+1;
        end
        // The old WB consumes a previously retired packet, before this edge's
        // newly registered retirement is observed. Held MEM must not replay it.
        if(dut.g_alu.u_pipeline.wb_fire)begin
            if(wb_packets>=retired || dut.g_alu.u_pipeline.memwb_q.seq!==retired_seq[wb_packets] ||
               wpc!==expected_pc[wb_packets] || dut.g_alu.u_pipeline.memwb_q.instr!==expected_instr[wb_packets] ||
               wrd!==expected_rd[wb_packets][4:0] || wdata!==expected_value[wb_packets] || we!==(expected_writes[wb_packets]!=0))
                $fatal(1,"WB identity/value case=%0d index=%0d pc=%h data=%h",CASE_ID,wb_packets,wpc,wdata);
            $fwrite(fd_trace,"wb,%0d,%0d,%016h,%08h,%08h,%0d,%08h,%0d,%0d,%08h\n",cycles,wb_packets,
                dut.g_alu.u_pipeline.memwb_q.seq,wpc,dut.g_alu.u_pipeline.memwb_q.instr,wrd,wdata,we,ic,dut.g_alu.u_pipeline.arch_next_pc_q);
            wb_packets=wb_packets+1;
        end
        fire_retire=dut.g_alu.u_pipeline.retire_fire;before_instret=ic;
        if(dut.unused_bp_update!==(PRED && fire_retire))$fatal(1,"BP update not identical to qualified MEM retirement case=%0d",CASE_ID);
        if(fire_retire)begin
            if(retired>=expected_count)$fatal(1,"Extra retirement case=%0d",CASE_ID);
            pre_seq=dut.g_alu.u_pipeline.exmem_q.seq;pre_pc=dut.g_alu.u_pipeline.exmem_q.pc;pre_instr=dut.g_alu.u_pipeline.exmem_q.instr;
            pre_rd=dut.g_alu.u_pipeline.exmem_q.rd;pre_value=dut.g_alu.u_pipeline.mem_result_value;
            pre_writes=dut.g_alu.u_pipeline.exmem_q.writes_rd && dut.g_alu.u_pipeline.exmem_q.rd!=0;pre_next=dut.g_alu.u_pipeline.exmem_q.actual_next_pc;
            if(pre_pc!==expected_pc[retired] || pre_instr!==expected_instr[retired] || pre_rd!==expected_rd[retired] ||
               pre_value!==expected_value[retired] || pre_writes!==(expected_writes[retired]!=0) || pre_next!==expected_nextpc[retired])
                $fatal(1,"Pre-MEM golden mismatch case=%0d index=%0d pc=%h instr=%h value=%h next=%h",CASE_ID,retired,pre_pc,pre_instr,pre_value,pre_next);
            if(retired>0 && pre_seq<=last_retire_seq)$fatal(1,"Nonmonotonic retirement age case=%0d",CASE_ID);
            owner_count=0;owner=-1;
            for(i=0;i<accepted;i=i+1)if(accept_seq[i]==pre_seq)begin owner=i;owner_count=owner_count+1;end
            if(owner_count!=1)$fatal(1,"Retirement lacks one accepted owner case=%0d seq=%h",CASE_ID,pre_seq);
            if(accept_retired[owner] || accept_pc[owner]!==pre_pc || accept_instr[owner]!==pre_instr)
                $fatal(1,"Retirement lacks one accepted live owner case=%0d seq=%h",CASE_ID,pre_seq);
            if(dut.g_alu.u_pipeline.exmem_q.pred_next_pc!==accept_pred_next[owner] ||
               dut.g_alu.u_pipeline.exmem_q.pred_taken!==accept_pred_taken[owner] || dut.g_alu.u_pipeline.exmem_q.pred_hit!==accept_pred_hit[owner])
                $fatal(1,"Prediction descriptor changed owner case=%0d",CASE_ID);
            accept_retired[owner]=1;last_retire_seq=pre_seq;
            // Recompute control result from retirement's independent shadow RF.
            // No speculative data or branch decision is taken from the RTL.
            calc_branch=pre_instr[6:0]==7'h63;calc_jal=pre_instr[6:0]==7'h6f;calc_jalr=pre_instr[6:0]==7'h67;
            calc_taken=calc_jal||calc_jalr;calc_target=pre_pc+4;calc_imm=0;
            if(calc_branch)begin
                calc_imm={{19{pre_instr[31]}},pre_instr[31],pre_instr[7],pre_instr[30:25],pre_instr[11:8],1'b0};
                calc_target=pre_pc+calc_imm;
                case(pre_instr[14:12])
                    0:calc_taken=shadow_gpr[pre_instr[19:15]]==shadow_gpr[pre_instr[24:20]];
                    1:calc_taken=shadow_gpr[pre_instr[19:15]]!=shadow_gpr[pre_instr[24:20]];
                    4:calc_taken=$signed(shadow_gpr[pre_instr[19:15]])<$signed(shadow_gpr[pre_instr[24:20]]);
                    5:calc_taken=$signed(shadow_gpr[pre_instr[19:15]])>=$signed(shadow_gpr[pre_instr[24:20]]);
                    6:calc_taken=shadow_gpr[pre_instr[19:15]]<shadow_gpr[pre_instr[24:20]];
                    7:calc_taken=shadow_gpr[pre_instr[19:15]]>=shadow_gpr[pre_instr[24:20]];
                    default:$fatal(1,"Illegal branch retired");
                endcase
            end else if(calc_jal)begin
                calc_imm={{11{pre_instr[31]}},pre_instr[31],pre_instr[19:12],pre_instr[20],pre_instr[30:21],1'b0};
                calc_target=pre_pc+calc_imm;
            end else if(calc_jalr)begin
                calc_imm={{20{pre_instr[31]}},pre_instr[31:20]};
                calc_target=(shadow_gpr[pre_instr[19:15]]+calc_imm)&32'hfffffffe;
            end
            calc_next=calc_taken?calc_target:pre_pc+4;
            if(calc_next!==pre_next || dut.g_alu.u_pipeline.exmem_q.branch_target!==calc_target ||
               dut.g_alu.u_pipeline.exmem_q.branch_taken!==calc_taken || dut.g_alu.u_pipeline.exmem_q.is_branch!==calc_branch ||
               dut.g_alu.u_pipeline.exmem_q.is_jal!==calc_jal || dut.g_alu.u_pipeline.exmem_q.is_jalr!==calc_jalr)
                $fatal(1,"Independent control result mismatch case=%0d index=%0d",CASE_ID,retired);
            if(PRED)begin
                if(calc_branch||calc_jal)want_resolved=want_resolved+1;
                if(pre_next!=accept_pred_next[owner])want_mispredict=want_mispredict+1;
                if((calc_branch||calc_jal) && accept_pred_taken[owner]!=calc_taken)want_direrr=want_direrr+1;
                if((calc_branch||calc_jal) && accept_pred_taken[owner] && calc_taken && pre_next!=accept_pred_next[owner])want_tgterr=want_tgterr+1;
            end
        end
        if(dut.unused_bp_update)begin
            if(!fire_retire || dut.alu_bp_seq!==pre_seq || dut.alu_bp_pc!==pre_pc || dut.alu_bp_target!==calc_target ||
               dut.alu_bp_taken!==calc_taken || dut.alu_bp_branch!==calc_branch || dut.alu_bp_jal!==calc_jal)
                $fatal(1,"BP descriptor not same successful MEM owner case=%0d",CASE_ID);
            $fwrite(fd_events,"%0d,bp,%016h,%08h,%08h,%08h,%0d,%08h,%0d,%0d,%0d,%0d\n",cycles,
                pre_seq,pre_pc,pre_next,calc_target,calc_taken,dut.g_alu.u_pipeline.exmem_q.pred_next_pc,
                dut.g_alu.u_pipeline.exmem_q.pred_taken,calc_branch,calc_jal,calc_jalr);
            bp_commits=bp_commits+1;
        end
        #1;
        if(rv!==fire_retire || ic!==before_instret+(fire_retire?1:0))$fatal(1,"Retirement/count edge alignment case=%0d",CASE_ID);
        if(resolved!==want_resolved || mispredict!==want_mispredict || direction_error!==want_direrr || target_error!==want_tgterr)
            $fatal(1,"BP counter alignment case=%0d",CASE_ID);
        if(rv)begin
            if(dut.g_alu.u_pipeline.retire_pc!==pre_pc || dut.g_alu.u_pipeline.retire_instr!==pre_instr || dut.g_alu.u_pipeline.retire_seq!==pre_seq ||
               dut.g_alu.u_pipeline.retire_rd!==pre_rd[4:0] || dut.g_alu.u_pipeline.retire_value!==pre_value ||
               dut.g_alu.u_pipeline.retire_writes_rd!==pre_writes || dut.g_alu.u_pipeline.arch_next_pc_q!==pre_next)
                $fatal(1,"Registered retirement descriptor mismatch case=%0d",CASE_ID);
            retired_seq[retired]=pre_seq;
            $fwrite(fd_trace,"retire,%0d,%0d,%016h,%08h,%08h,%0d,%08h,%0d,%0d,%08h\n",cycles,retired,
                pre_seq,pre_pc,pre_instr,pre_rd,pre_value,pre_writes,ic,pre_next);
            if(pre_writes)begin shadow_gpr[pre_rd[4:0]]=pre_value;written_mask[pre_rd[4:0]]=1;end
            retired=retired+1;
        end
        if(dut.g_alu.u_pipeline.halted)begin
            halt_cycles=halt_cycles+1;
            if(dut.g_alu.u_pipeline.halt_pc!==stop_pc || dut.g_alu.u_pipeline.halt_instr!==stop_instr ||
               dut.g_alu.u_pipeline.halt_fetch_error!==stop_fetch || dut.g_alu.u_pipeline.halt_cause!==stop_cause ||
               dut.g_alu.u_pipeline.halt_tval!==stop_tval)
                $fatal(1,"MEM halt descriptor case=%0d pc=%h instr=%h cause=%h tval=%h",CASE_ID,dut.g_alu.u_pipeline.halt_pc,
                    dut.g_alu.u_pipeline.halt_instr,dut.g_alu.u_pipeline.halt_cause,dut.g_alu.u_pipeline.halt_tval);
            if(dut.g_alu.u_pipeline.exmem_supported_q)$fatal(1,"Final EBREAK must remain unsupported");
            if(halt_cycles==8)begin
                if(retired!=expected_count || wb_packets!=expected_count || ic!=expected_count || bp_commits!=(PRED?expected_count:0))
                    $fatal(1,"Retirement/WB/BP ledger case=%0d retired=%0d WB=%0d BP=%0d expected=%0d",CASE_ID,retired,wb_packets,bp_commits,expected_count);
                for(g=1;g<32;g=g+1)if(dut.g_alu.u_pipeline.u_regfile.regs[g]!==final_gpr[g])
                    $fatal(1,"Final initialized GPR mismatch case=%0d x%0d actual=%h expected=%h",CASE_ID,g,dut.g_alu.u_pipeline.u_regfile.regs[g],final_gpr[g]);
                if(stop_fetch && (!ifault || ifpc!==stop_pc))$fatal(1,"Sticky IF error descriptor case=%0d",CASE_ID);
                if(drequests!=mem_count || dresponses!=mem_count || dpending || dut.g_alu.u_pipeline.ram_owner_valid)
                    $fatal(1,"D ledger not closed case=%0d req=%0d rsp=%0d",CASE_ID,drequests,dresponses);
                fd_ram=$fopen({case_dir,"/actual_ram_final.hex"},"w");
                if(fd_ram==0)$fatal(1,"Cannot open final RAM");
                for(g=0;g<4096;g=g+1)begin
                    if(ram_words[g]!==ram_final[g])$fatal(1,"Final RAM mismatch case=%0d word=%0d",CASE_ID,g);
                    $fwrite(fd_ram,"%08h\n",ram_words[g]);
                end
                $fclose(fd_ram);$fclose(fd_d);
                fd_metrics=$fopen({case_dir,"/metrics.json"},"w");
                if(fd_metrics==0)$fatal(1,"Cannot open metrics");
                $fwrite(fd_metrics,"{\"retired\":%0d,\"wb_packets\":%0d,\"accepted\":%0d,\"redirects\":%0d,\"bp_commits\":%0d,\"cycles\":%0d,\"requests\":%0d,\"responses\":%0d,\"raw_wait_cycles\":%0d,\"resolved\":%0d,\"mispredict\":%0d,\"direction_error\":%0d,\"target_error\":%0d,\"d_requests\":%0d,\"d_responses\":%0d,\"load_turnovers\":%0d}\n",
                    retired,wb_packets,accepted,redirects,bp_commits,cycles,requests,responses,raw_waits,resolved,mispredict,direction_error,target_error,drequests,dresponses,turnovers);
                $fclose(fd_metrics);$fclose(fd_trace);$fclose(fd_accept);$fclose(fd_events);done=1;
                $display("CPU5 RAM CASE PASS case=%0d ID=%0d BP=%0d WAIT=%0d fixture=%s retired=%0d redirects=%0d RAW=%0d cycles=%0d",CASE_ID,ID_MODE,PRED,WAIT,fixture_name,retired,redirects,raw_waits,cycles);
            end
        end
    end
endmodule
