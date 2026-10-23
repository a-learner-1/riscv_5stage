`timescale 1ns/1ps
`include "build/cpu5_s2_alu/meta.vh"
module cpu5_alu_top_tb;
    wire [47:0] done;
    reg test_pass=0;
    cpu5_alu_top_case #(.CASE_ID(0),.KIND(0),.WAIT(0)) fast(done[0]);
    cpu5_alu_top_case #(.CASE_ID(1),.KIND(0),.WAIT(1)) waited(done[1]);
    cpu5_alu_top_case #(.CASE_ID(2),.KIND(1),.WAIT(1)) fetch_error(done[2]);
    genvar n;
    generate for(n=0;n<45;n=n+1)begin:g_unsupported
        cpu5_alu_top_case #(.CASE_ID(n+3),.KIND(2),.INDEX(n),.WAIT(n%2)) u(done[n+3]);
    end endgenerate
    initial begin wait(&done);test_pass=1;$display("CPU5 ALU TOP PASS 48 cases: 550+550 ALU retirements, IF fault prefix, 45 unsupported stops");$stop;end
    initial begin #2000000;$fatal(1,"CPU5 ALU TOP timeout done=%h",done);end
endmodule

module cpu5_alu_top_case #(
    parameter CASE_ID=0,KIND=0,INDEX=0,WAIT=0,FORWARD=0,
    parameter TRACE_DIR="build/cpu5_s2_alu"
)(output reg done=0);
    reg clk=0,rst_n=0,pending=0;
    always #10 clk=~clk;
    wire qv,qr,sv,sr,rv,we,dqv,dqw,dsr,df,tf,ifault,tx;
    wire [31:0] qa,wpc,wdata,dqa,dqd,tpc,tc,tv,ifpc;
    wire [4:0] wrd;
    wire [1:0] dz;
    wire [3:0] dst;
    wire [63:0] cc,ic;
    wire [9:0] perf;
    wire [7:0] gout,goe;
    reg [31:0] addr=0;
    integer delay=0,cycles=0,requests=0,responses=0,retired=0,wb_packets=0,writes=0;
    integer raw_waits=0,halt_cycles=0,fd,metrics,g,expected_count;
    reg [31:0] program_words[0:`CPU5_ALU_PROGRAM_WORDS-1];
    reg [31:0] fault_words[0:`CPU5_ALU_IF_FAULT_PROGRAM_WORDS-1];
    reg [31:0] unsupported_words[0:44];
    reg [31:0] expected_pc[0:`CPU5_ALU_RETIRE_COUNT-1],expected_instr[0:`CPU5_ALU_RETIRE_COUNT-1];
    reg [31:0] expected_rd[0:`CPU5_ALU_RETIRE_COUNT-1],expected_value[0:`CPU5_ALU_RETIRE_COUNT-1];
    reg [31:0] expected_writes[0:`CPU5_ALU_RETIRE_COUNT-1],expected_seq[0:`CPU5_ALU_RETIRE_COUNT-1];
    reg [31:0] expected_nextpc[0:`CPU5_ALU_RETIRE_COUNT-1],final_gpr[0:31];
    reg rsp_held=0;reg [32:0] saved_response;
    reg fire_retire;
    reg [63:0] before_instret;
    // Keep ROM arrays in the explicit combinational dependency set. A function
    // with only addr as its argument can retain pre-$readmemh X at address zero.
    reg [31:0] response_data;
    always @* begin
        response_data=32'h00000013;
        if(KIND==0 && addr/4<`CPU5_ALU_PROGRAM_WORDS)response_data=program_words[addr/4];
        if(KIND==1 && addr/4<`CPU5_ALU_IF_FAULT_PROGRAM_WORDS)response_data=fault_words[addr/4];
        if(KIND==2)case(addr)
            0:response_data=32'h00700093; // addi x1,x0,7
            4:response_data=32'h00508113; // addi x2,x1,5
            8:response_data=unsupported_words[INDEX];
            default:response_data=32'h00000013;
        endcase
    end
    wire response_error=KIND==1 && addr==`CPU5_ALU_IF_FAULT_PC;
    assign qr=rst_n && (!pending||(sv&&sr)) && (!WAIT || cycles%7>=2);
    assign sv=pending && delay==0;
    cpu5_top #(.PROGRAM_FILE("programs/data_handshake_blank.hex"),.IMEM_WORDS(2048),
        .SKELETON_ONLY(0),.ENABLE_FORWARDING(FORWARD),
        .ENABLE_BRANCH_PRED(WAIT),.BRANCH_RESOLVE_IN_ID(WAIT)) dut(.irq_software(1'b0),.irq_timer(1'b0),
        .clk(clk),.rst_n(rst_n),.pc_x(),.instr_x(),.valid_x(),
        .wb_pc(wpc),.wb_rd(wrd),.wb_data(wdata),.wb_we(we),.retire_valid(rv),
        .cycle_count(cc),.instret_count(ic),.uart_tx(tx),.uart_rx(1'b1),
        .gpio_in(8'hff),.gpio_out(gout),.gpio_oe(goe),
        .dmem_req_valid(dqv),.dmem_req_ready(1'b1),.dmem_req_write(dqw),.dmem_req_addr(dqa),
        .dmem_req_size(dz),.dmem_req_wdata(dqd),.dmem_req_wstrb(dst),
        .dmem_rsp_valid(1'b1),.dmem_rsp_ready(dsr),.dmem_rsp_rdata(32'hdeadbeef),
        .dmem_rsp_error(1'b1),.dmem_fault(df),
        .imem_req_valid(qv),.imem_req_ready(qr),.imem_req_addr(qa),
        .imem_rsp_valid(sv),.imem_rsp_ready(sr),.imem_rsp_rdata(response_data),
        .imem_rsp_error(response_error),.imem_fault(ifault),.imem_fault_pc(ifpc),
        .trap_valid(tf),.trap_pc(tpc),.trap_cause(tc),.trap_tval(tv),
        .bp_lookup_count(),.bp_hit_count(),.bp_taken_count(),.bp_resolved_count(),
        .bp_mispredict_count(),.bp_direction_error_count(),.bp_target_error_count(),
        .irq_external(1'b1),.perf_cycle_events(perf));
    initial begin
        $readmemh({TRACE_DIR,"/program.hex"},program_words);
        $readmemh({TRACE_DIR,"/if_fault_program.hex"},fault_words);
        $readmemh({TRACE_DIR,"/unsupported.hex"},unsupported_words);
        $readmemh({TRACE_DIR,"/final_gpr.hex"},final_gpr);
        if(KIND==0)begin
            expected_count=`CPU5_ALU_RETIRE_COUNT;
            $readmemh({TRACE_DIR,"/expected_pc.hex"},expected_pc);
            $readmemh({TRACE_DIR,"/expected_instr.hex"},expected_instr);
            $readmemh({TRACE_DIR,"/expected_rd.hex"},expected_rd);
            $readmemh({TRACE_DIR,"/expected_value.hex"},expected_value);
            $readmemh({TRACE_DIR,"/expected_writes.hex"},expected_writes);
            $readmemh({TRACE_DIR,"/expected_seq.hex"},expected_seq);
            $readmemh({TRACE_DIR,"/expected_nextpc.hex"},expected_nextpc);
        end else if(KIND==1)begin
            expected_count=3;
            $readmemh({TRACE_DIR,"/if_fault_expected_pc.hex"},expected_pc,0,7);
            $readmemh({TRACE_DIR,"/if_fault_expected_instr.hex"},expected_instr,0,7);
            $readmemh({TRACE_DIR,"/if_fault_expected_rd.hex"},expected_rd,0,7);
            $readmemh({TRACE_DIR,"/if_fault_expected_value.hex"},expected_value,0,7);
            $readmemh({TRACE_DIR,"/if_fault_expected_writes.hex"},expected_writes,0,7);
            $readmemh({TRACE_DIR,"/if_fault_expected_seq.hex"},expected_seq,0,7);
            $readmemh({TRACE_DIR,"/if_fault_expected_nextpc.hex"},expected_nextpc,0,7);
        end else begin
            expected_count=2;
            expected_pc[0]=0;expected_pc[1]=4;
            expected_instr[0]=32'h00700093;expected_instr[1]=32'h00508113;
            expected_rd[0]=1;expected_rd[1]=2;expected_value[0]=7;expected_value[1]=12;
            expected_writes[0]=1;expected_writes[1]=1;expected_seq[0]=0;expected_seq[1]=1;
            expected_nextpc[0]=4;expected_nextpc[1]=8;
        end
        fd=$fopen($sformatf("%s/case%0d_trace.csv",TRACE_DIR,CASE_ID),"w");
        $fwrite(fd,"kind,cycle,index,seq,pc,instr,rd,value,writes,instret,nextpc\n");
        repeat(4)@(negedge clk);rst_n=1;
    end
    always @(posedge clk)if(rst_n&&!done)begin
        cycles=cycles+1;
        if({dqv,dqw,dqa,dz,dqd,dst,dsr,df,tf,tpc,tc,tv,gout,goe,perf}!==0 || tx!==1)
            $fatal(1,"Unsupported architectural side effect case=%0d",CASE_ID);
        if(rsp_held && (!sv || {response_error,response_data}!==saved_response))
            $fatal(1,"I response changed under stall");
        rsp_held=sv&&!sr;saved_response={response_error,response_data};
        if(sv&&sr)begin pending<=0;responses=responses+1;end
        if(pending&&delay>0)delay<=delay-1;
        if(qv&&qr)begin
            if(qa!==requests*4)$fatal(1,"I request PC ownership case=%0d",CASE_ID);
            addr<=qa;pending<=1;delay<=WAIT?(requests%4):0;requests=requests+1;
        end
        if(dut.g_alu.u_pipeline.id_raw_wait)raw_waits=raw_waits+1;
        if(dut.g_alu.u_pipeline.id_move)begin
            if(dut.g_alu.u_pipeline.uses_rs1 && dut.g_alu.u_pipeline.rs1==0 && dut.g_alu.u_pipeline.rf1!==0)
                $fatal(1,"x0 source1 read");
            if(dut.g_alu.u_pipeline.uses_rs2 && dut.g_alu.u_pipeline.rs2==0 && dut.g_alu.u_pipeline.rf2!==0)
                $fatal(1,"x0 source2 read");
        end
        if(dut.g_alu.u_pipeline.wb_fire)begin
            if(wb_packets>=retired || dut.g_alu.u_pipeline.memwb_q.seq!==expected_seq[wb_packets] ||
               wpc!==expected_pc[wb_packets] || wrd!==expected_rd[wb_packets][4:0] ||
               wdata!==expected_value[wb_packets] || we!==(expected_writes[wb_packets]!=0))
                $fatal(1,"physical WB identity/value case=%0d n=%0d pc=%h data=%h",CASE_ID,wb_packets,wpc,wdata);
            $fwrite(fd,"wb,%0d,%0d,%0d,%08h,%08h,%0d,%08h,%0d,%0d,%08h\n",cycles,wb_packets,dut.g_alu.u_pipeline.memwb_q.seq,
                wpc,dut.g_alu.u_pipeline.memwb_q.instr,wrd,wdata,we,ic,dut.g_alu.u_pipeline.arch_next_pc_q);
            wb_packets=wb_packets+1;if(we)writes=writes+1;
        end
        fire_retire=dut.g_alu.u_pipeline.retire_fire;before_instret=ic;
        if(fire_retire)begin
            if(retired>=expected_count)$fatal(1,"extra retirement case=%0d",CASE_ID);
            if(dut.g_alu.u_pipeline.exmem_q.pc!==expected_pc[retired] ||
               dut.g_alu.u_pipeline.exmem_q.instr!==expected_instr[retired] ||
               dut.g_alu.u_pipeline.exmem_q.seq!==expected_seq[retired])$fatal(1,"pre MEM identity case=%0d n=%0d",CASE_ID,retired);
        end
        #1;
        if(rv!==fire_retire || ic!==before_instret+(fire_retire?1:0))$fatal(1,"retire/count edge alignment case=%0d",CASE_ID);
        if(rv)begin
            if(dut.g_alu.u_pipeline.retire_pc!==expected_pc[retired] ||
               dut.g_alu.u_pipeline.retire_instr!==expected_instr[retired] ||
               dut.g_alu.u_pipeline.retire_seq!==expected_seq[retired] ||
               dut.g_alu.u_pipeline.retire_rd!==expected_rd[retired][4:0] ||
               dut.g_alu.u_pipeline.retire_value!==expected_value[retired] ||
               dut.g_alu.u_pipeline.retire_writes_rd!==(expected_writes[retired]!=0) ||
               dut.g_alu.u_pipeline.arch_next_pc_q!==expected_nextpc[retired])
                $fatal(1,"post retire oracle case=%0d n=%0d pc=%h value=%h expected=%h",CASE_ID,retired,
                    dut.g_alu.u_pipeline.retire_pc,dut.g_alu.u_pipeline.retire_value,expected_value[retired]);
            $fwrite(fd,"retire,%0d,%0d,%0d,%08h,%08h,%0d,%08h,%0d,%0d,%08h\n",cycles,retired,
                dut.g_alu.u_pipeline.retire_seq,dut.g_alu.u_pipeline.retire_pc,dut.g_alu.u_pipeline.retire_instr,
                dut.g_alu.u_pipeline.retire_rd,dut.g_alu.u_pipeline.retire_value,dut.g_alu.u_pipeline.retire_writes_rd,
                ic,dut.g_alu.u_pipeline.arch_next_pc_q);
            retired=retired+1;
        end
        if(dut.g_alu.u_pipeline.halted)begin
            halt_cycles=halt_cycles+1;
            if(dut.g_alu.u_pipeline.halt_pc!==(KIND==0?`CPU5_ALU_HALT_PC:KIND==1?32'hc:32'h8) ||
               dut.g_alu.u_pipeline.halt_fetch_error!==(KIND==1))$fatal(1,"halt descriptor case=%0d pc=%h instr=%h supported=%b error=%b",CASE_ID,dut.g_alu.u_pipeline.halt_pc,dut.g_alu.u_pipeline.halt_instr,dut.g_alu.u_pipeline.exmem_supported_q,dut.g_alu.u_pipeline.halt_fetch_error);
            if(halt_cycles==6)begin
                if(retired!=expected_count || wb_packets!=expected_count || ic!=expected_count ||
                   (FORWARD ? raw_waits!=0 : raw_waits==0))
                    $fatal(1,"retire/WB/count/stall ledger case=%0d retired=%0d WB=%0d expected=%0d",CASE_ID,retired,wb_packets,expected_count);
                if(KIND==0)for(g=1;g<32;g=g+1)if(dut.g_alu.u_pipeline.u_regfile.regs[g]!==final_gpr[g])$fatal(1,"final GPR case=%0d x%0d",CASE_ID,g);
                if(KIND==1 && (!ifault||ifpc!=12))$fatal(1,"sticky IF fault diagnostic");
                metrics=$fopen($sformatf("%s/case%0d_metrics.csv",TRACE_DIR,CASE_ID),"w");
                $fwrite(metrics,"case,retired,wb_packets,gpr_writes,raw_wait_cycles,cycles,requests,responses\n%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",CASE_ID,retired,wb_packets,writes,raw_waits,cycles,requests,responses);
                $fclose(metrics);$fclose(fd);done=1;
                $display("CPU5 ALU CASE PASS case=%0d kind=%0d retired=%0d wb=%0d writes=%0d RAWwait=%0d cycles=%0d",CASE_ID,KIND,retired,wb_packets,writes,raw_waits,cycles);
            end
        end
    end
endmodule
