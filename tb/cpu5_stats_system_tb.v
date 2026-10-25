`timescale 1ns/1ps
module cpu5_stats_system_tb;
    wire [7:0] done;reg test_pass=0;genvar i;
    generate for(i=0;i<8;i=i+1)begin:g_cases
        cpu5_stats_system_case #(.CASE_ID(i),.D0(i/4),.CACHE((i/2)%2),.WAIT(i%2)) u(done[i]);
    end endgenerate
    initial begin wait(&done);test_pass=1;$display("CPU5 STATS SYSTEM PASS cases=8");$stop;end
    initial begin #8000000;$fatal(1,"CPU5 Stats system timeout done=%h",done);end
endmodule
`define SYSCORE dut.u_core.u_cached.u_cpu.g_alu.u_pipeline
module cpu5_stats_system_case #(parameter CASE_ID=0,D0=0,CACHE=0,WAIT=0)(output reg done=0);
    localparam BASE="build/cpu5_s16_stats_system";
    reg clk=0,rst_n=0;always #10 clk=~clk;
    wire [63:0] cycle_count,instret_count;wire [9:0] events;
    wire trap,ifault,dfault;wire [31:0] trap_pc,trap_cause,trap_tval;
    wire [31:0] ia,ih,im,ir,ie,da,dh,dm,dr,de,dw,db;
    cpu5_stats_axi_lite_top #(.PROGRAM_FILE($sformatf("%s/firmware/case%0d/program.hex",BASE,CASE_ID)),.DATA_FILE(""),
        .ENABLE_D0_BRAM(D0),.ENABLE_ICACHE(CACHE),.ENABLE_DCACHE(CACHE),.ICACHE_SETS(4),.DCACHE_SETS(4),
        .ENABLE_BRANCH_PRED(1),.BTB_ENTRIES(16),.BRANCH_RESOLVE_IN_ID(WAIT),
        .IMEM_REQ_WAIT_CYCLES(WAIT?1:0),.IMEM_RSP_WAIT_CYCLES(WAIT?2:0),
        .D0_REQ_WAIT_CYCLES(WAIT?2:0),.D0_RSP_WAIT_CYCLES(WAIT?3:0),
        .RAM_AW_WAIT_CYCLES(WAIT?2:0),.RAM_W_WAIT_CYCLES(WAIT?1:0),.RAM_AR_WAIT_CYCLES(WAIT?2:0),
        .RAM_B_WAIT_CYCLES(WAIT?3:0),.RAM_R_WAIT_CYCLES(WAIT?3:0)) dut(
        .clk(clk),.rst_n(rst_n),.uart_rx(1'b1),.gpio_in(8'd0),.irq_external(1'b0),.irq_software(1'b0),.irq_timer(1'b0),
        .uart_tx(),.gpio_out(),.gpio_oe(),.pc_x(),.instr_x(),.valid_x(),.wb_pc(),.wb_data(),.wb_rd(),.wb_we(),.retire_valid(),
        .cycle_count(cycle_count),.instret_count(instret_count),.perf_cycle_events(events),
        .imem_fault(ifault),.dmem_fault(dfault),.imem_fault_pc(),.trap_valid(trap),.trap_pc(trap_pc),.trap_cause(trap_cause),.trap_tval(trap_tval),
        .icache_access_count(ia),.icache_hit_count(ih),.icache_miss_count(im),.icache_refill_word_count(ir),.icache_error_count(ie),
        .dcache_access_count(da),.dcache_hit_count(dh),.dcache_miss_count(dm),.dcache_refill_word_count(dr),.dcache_error_count(de),.dcache_write_count(dw),.dcache_bypass_count(db),
        .bp_lookup_count(),.bp_hit_count(),.bp_taken_count(),.bp_resolved_count(),.bp_mispredict_count(),.bp_direction_error_count(),.bp_target_error_count());
    wire [31:0] ram[0:4095];genvar w;
    generate if(D0)begin:g_local
        for(w=0;w<4096;w=w+1)begin:g_words assign ram[w]=dut.u_core.u_backend.g_d0.u_ram.u_data_mem.mem[w];end
    end else begin:g_axi
        for(w=0;w<4096;w=w+1)begin:g_words assign ram[w]=dut.u_ram.u_data_mem.mem[w];end
    end endgenerate
    integer cycle=0,retired=0,wb=0,stats_reads=0,stats_responses=0,raw_start=0,stop_count=0,tail=0,fd_edges,fd_stats,fd_ram,fd_snapshot,fd_summary;
    integer j,ones;reg [63:0] gold[0:9],start_gold[0:9],stop_gold[0:9],start_cycle=0,stop_cycle=0,start_instret=0,stop_instret=0,total;
    reg [31:0] start_words[0:15],stop_words[0:15];
    reg pending=0;reg [31:0] expected_data=0,expected_offset=0;reg [1:0] expected_resp=0;
    reg [63:0] rseq[0:20000];reg [31:0] rpc[0:20000],rins[0:20000],rrd[0:20000],rval[0:20000];reg rwrite[0:20000];
    reg [31:0] offset,value;reg [1:0] response;string directory;
    function [31:0] expected_read(input [31:0] off);
        integer field;reg [63:0] g;
        begin
            expected_read=0;
            case(off)
                0,4:expected_read=32'h434d4158;
                8:expected_read=CACHE?3:0;
                12,16:expected_read=32'h02040010;
                20:expected_read=32'h00100001;
                24:expected_read=4;
                28:expected_read=D0;
                default:begin
                    if(off>=32'h40&&off<=32'h7c)expected_read=start_words[(off-32'h40)/4];
                    else if(off>=32'h80&&off<=32'hbc)expected_read=stop_words[(off-32'h80)/4];
                    else if(off>=32'h100&&off<=32'h12c)begin field=(off-32'h100)/8;g=start_gold[field];expected_read=off[2]?g[63:32]:g[31:0];end
                    else if(off>=32'h140&&off<=32'h16c)begin field=(off-32'h140)/8;g=stop_gold[field];expected_read=off[2]?g[63:32]:g[31:0];end
                    else if(off>=32'h180&&off<=32'h19c)begin field=6+(off-32'h180)/8;g=start_gold[field];expected_read=off[2]?g[63:32]:g[31:0];end
                    else if(off>=32'h1c0&&off<=32'h1dc)begin field=6+(off-32'h1c0)/8;g=stop_gold[field];expected_read=off[2]?g[63:32]:g[31:0];end
                    else $fatal(1,"CPU5 system unexpected Stats address %h",off);
                end
            endcase
        end
    endfunction
    task capture(input bit stop_bank);
        integer n;reg [31:0] vals[0:15];
        begin
            vals[0]=cycle_count[31:0];vals[1]=cycle_count[63:32];vals[2]=instret_count[31:0];vals[3]=instret_count[63:32];
            vals[4]=ia;vals[5]=ih;vals[6]=im;vals[7]=ir;vals[8]=ie;vals[9]=da;vals[10]=dh;vals[11]=dm;vals[12]=dr;vals[13]=de;vals[14]=dw;vals[15]=db;
            for(n=0;n<16;n=n+1)if(stop_bank)stop_words[n]=vals[n];else start_words[n]=vals[n];
            for(n=0;n<10;n=n+1)if(stop_bank)stop_gold[n]=gold[n];else start_gold[n]=gold[n];
            if(stop_bank)begin stop_cycle=cycle_count;stop_instret=instret_count;end
            else begin start_cycle=cycle_count;start_instret=instret_count;end
        end
    endtask
    initial begin
        directory=$sformatf("%s/cases/case%0d",BASE,CASE_ID);
        fd_edges=$fopen({directory,"/edges.csv"},"w");fd_stats=$fopen({directory,"/stats.csv"},"w");
        $fwrite(fd_edges,"cycle,cycle_count,instret,events,retire,wb,arvalid,arready,araddr,rvalid,rready,rdata,rresp\n");
        $fwrite(fd_stats,"event,cycle,offset,data,response\n");
        for(j=0;j<10;j=j+1)begin gold[j]=0;start_gold[j]=0;stop_gold[j]=0;end
        for(j=0;j<16;j=j+1)begin start_words[j]=0;stop_words[j]=0;end
        repeat(4)@(negedge clk);rst_n=1;
    end
    always @(posedge clk)if(rst_n&&!done)begin
        cycle=cycle+1;
        if(cycle_count!==cycle-1||instret_count!==retired)$fatal(1,"CPU5 system independent CPU counters");
        if(trap||ifault||dfault)$fatal(1,"CPU5 system unexpected fault case=%0d pc=%h cause=%h tval=%h",CASE_ID,trap_pc,trap_cause,trap_tval);
        ones=0;total=0;
        for(j=0;j<10;j=j+1)begin
            if(events[j])begin gold[j]=gold[j]+1;ones=ones+1;end
            total=total+gold[j];
        end
        if((cycle==1&&ones!=0)||(cycle>1&&ones!=1)||total!==cycle_count)$fatal(1,"CPU5 system registered onehot/cycle alignment");
        $fwrite(fd_edges,"%0d,%0d,%0d,%03h,%0d,%0d,%0d,%0d,%08h,%0d,%0d,%08h,%0d\n",cycle,cycle_count,instret_count,events,`SYSCORE.retire_fire,`SYSCORE.wb_fire,dut.stats_arvalid,dut.stats_arready,dut.stats_araddr,dut.stats_rvalid,dut.stats_rready,dut.stats_rdata,dut.stats_rresp);
        if(dut.stats_rvalid)begin
            if(!pending||dut.stats_rdata!==expected_data||dut.stats_rresp!==expected_resp)$fatal(1,"CPU5 system independent Stats read response case=%0d off=%h actual=%h expected=%h",CASE_ID,expected_offset,dut.stats_rdata,expected_data);
            if(dut.stats_rready)begin pending=0;stats_responses=stats_responses+1;$fwrite(fd_stats,"rsp,%0d,%08h,%08h,%0d\n",cycle,expected_offset,dut.stats_rdata,dut.stats_rresp);end
        end
        if(dut.stats_arvalid&&dut.stats_arready)begin
            if(pending)$fatal(1,"CPU5 system Stats owner overwritten");
            offset=dut.stats_araddr-32'h30000000;
            if(offset==0)begin raw_start=raw_start+1;capture(0);end
            if(offset==4)begin stop_count=stop_count+1;capture(1);end
            expected_data=expected_read(offset);expected_resp=0;expected_offset=offset;pending=1;stats_reads=stats_reads+1;
            $fwrite(fd_stats,"req,%0d,%08h,%08h,0\n",cycle,offset,expected_data);
        end
        if(`SYSCORE.wb_fire)begin
            if(wb>=retired||`SYSCORE.memwb_q.seq!==rseq[wb]||`SYSCORE.memwb_q.pc!==rpc[wb]||`SYSCORE.memwb_q.instr!==rins[wb]||`SYSCORE.memwb_q.rd!==rrd[wb][4:0]||`SYSCORE.memwb_q.result!==rval[wb])$fatal(1,"CPU5 system physical WB ledger");
            wb=wb+1;
        end
        if(`SYSCORE.retire_fire)begin
            if(retired>=20000)$fatal(1,"CPU5 system retired overflow");
            rseq[retired]=`SYSCORE.exmem_q.seq;rpc[retired]=`SYSCORE.exmem_q.pc;rins[retired]=`SYSCORE.exmem_q.instr;rrd[retired]=`SYSCORE.exmem_q.rd;rval[retired]=`SYSCORE.mem_result_value;retired=retired+1;
        end
        if(ram[0]==32'hbad50005)$fatal(1,"CPU5 C smoke reported failure case=%0d failbits=%h",CASE_ID,ram[1]);
        if(ram[0]==32'h600d5005)tail=tail+1;
        if(tail==100)begin
            if(raw_start!=2||stop_count!=1||stats_reads!=101||stats_responses!=101||pending)$fatal(1,"CPU5 system trigger/read closure");
            total=0;for(j=0;j<10;j=j+1)total=total+(stop_gold[j]-start_gold[j]);
            if(total!=stop_cycle-start_cycle)$fatal(1,"CPU5 system selected window profile sum");
            fd_ram=$fopen({directory,"/actual_ram.hex"},"w");for(j=0;j<4096;j=j+1)$fwrite(fd_ram,"%08h\n",ram[j]);$fclose(fd_ram);
            fd_snapshot=$fopen({directory,"/snapshot.json"},"w");
            $fwrite(fd_snapshot,"{\"hardware_schema\":4,\"cycle_profile_schema\":2,\"event_width\":10,\"counter_bits\":64,\"window_bytes\":512,\"raw_start\":%0d,\"selected_start\":1,\"selected_epoch\":%0d,\"stop\":%0d,\"cycles\":{\"start\":%0d,\"stop\":%0d},\"instret\":{\"start\":%0d,\"stop\":%0d},\"profile\":{\"start\":[",raw_start,raw_start,stop_count,start_cycle,stop_cycle,start_instret,stop_instret);
            for(j=0;j<10;j=j+1)$fwrite(fd_snapshot,"%0d%s",start_gold[j],j==9?"":",");$fwrite(fd_snapshot,"],\"stop\":[");
            for(j=0;j<10;j=j+1)$fwrite(fd_snapshot,"%0d%s",stop_gold[j],j==9?"":",");$fwrite(fd_snapshot,"]}}\n");$fclose(fd_snapshot);
            fd_summary=$fopen({directory,"/summary.json"},"w");$fwrite(fd_summary,"{\"status\":\"PASS\",\"case\":%0d,\"d0\":%0d,\"cache\":%0d,\"wait\":%0d,\"cycles\":%0d,\"retired\":%0d,\"wb\":%0d,\"stats_reads\":%0d,\"stats_responses\":%0d}\n",CASE_ID,D0,CACHE,WAIT,cycle,retired,wb,stats_reads,stats_responses);$fclose(fd_summary);
            $fclose(fd_edges);$fclose(fd_stats);done=1;
            $display("CPU5 STATS SYSTEM CASE PASS case=%0d cycles=%0d retire=%0d",CASE_ID,cycle,retired);
        end
    end
endmodule
`undef SYSCORE
