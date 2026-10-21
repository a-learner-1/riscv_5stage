`timescale 1ns/1ps
`ifndef COREMARK_CONFIG
`define COREMARK_CONFIG "programs/coremark_d0_m_cache_on_btb_smoke_config.vh"
`endif
`include `COREMARK_CONFIG
`define M_CPU workload.dut.u_core.u_cpu
`define M_SOC workload.dut
`define M_STATS workload.dut.u_stats

// Passive three-stage RV32IM observer. All pre-edge CPU events are logged
// before NBA; unit done is first observed #1 after its producing edge.
// This does not drive any CPU, cache, bus, statistics, or unit signal.
module cpu5_m_breakdown_tb;
    coremark_d0_workload_tb #(.STOP_ON_PASS(0)) workload();
    wire clk=workload.clk, rst_n=workload.rst_n;
    reg test_pass=0, live=0, owner=0, owner_complete=0, owner_done=0;
    string output_dir;
    integer ofile, efile, wfile, mfile, i, c;
    integer starts=0, stops=0, epoch=0;
    reg [63:0] edge_id=0, owner_id=0, start_edge=0, stop_edge=0;
    reg [63:0] os=0, od=0, oc=0, ow=0;
    reg [2:0] op;
    reg [31:0] opc, lhs, rhs, result;
    reg [4:0] rd;
    reg [63:0] retired=0, frozen_cycles, frozen_retired, frozen_sum;
    reg [63:0] cycle_counts [0:5];
    reg [63:0] snap_cycles [0:5];
    reg [63:0] start_counts [0:7];
    reg [63:0] done_counts [0:7];
    reg [63:0] complete_counts [0:7];
    reg [63:0] retire_counts [0:7];
    reg [63:0] wait_counts [0:7];
    reg [63:0] contingency [0:23];
    reg previous_completion=0;
    reg [5:0] class_now;

    initial begin
        if (!$value$plusargs("M_OUTPUT=%s",output_dir)) $fatal(1,"M_OUTPUT required");
        ofile=$fopen({output_dir,"/m_owners.csv"},"w");
        efile=$fopen({output_dir,"/m_events.csv"},"w");
        wfile=$fopen({output_dir,"/window_endpoints.csv"},"w");
        if(!ofile || !efile || !wfile) $fatal(1,"cannot open observer files");
        $fwrite(ofile,"owner,pc,op,rd,lhs,rhs,result,start_edge,unit_done_edge,cpu_complete_edge,retire_edge,wait_cycles\n");
        $fwrite(efile,"kind,edge,owner,op,epoch,live\n");
        $fwrite(wfile,"kind,edge,raw_starts,epoch,cycle_pre,instret_pre,owner,owner_start\n");
        for(i=0;i<6;i=i+1)cycle_counts[i]=0;
        for(i=0;i<8;i=i+1)begin
            start_counts[i]=0;done_counts[i]=0;complete_counts[i]=0;
            retire_counts[i]=0;wait_counts[i]=0;
        end
        for(i=0;i<24;i=i+1)contingency[i]=0;
    end

    always @(posedge clk) if(rst_n)begin
        edge_id=edge_id+1;
        if(`M_SOC.stats_arvalid && `M_SOC.stats_arready)begin
            if(`M_SOC.stats_araddr==32'h30000000)begin
                if(stops)$fatal(1,"START after STOP");
                starts=starts+1;epoch=starts;start_edge=edge_id;live=1;retired=0;
                for(i=0;i<6;i=i+1)cycle_counts[i]=0;
                for(i=0;i<8;i=i+1)begin
                    start_counts[i]=0;done_counts[i]=0;complete_counts[i]=0;
                    retire_counts[i]=0;wait_counts[i]=0;
                end
                for(i=0;i<24;i=i+1)contingency[i]=0;
                $fwrite(wfile,"START,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",edge_id,starts,epoch,
                    `M_CPU.cycle_count,`M_CPU.instret_count,owner,os);
            end else if(`M_SOC.stats_araddr==32'h30000004)begin
                stops=stops+1;
                if(stops!=1 || starts<1 || !live)$fatal(1,"invalid STOP");
                live=0;stop_edge=edge_id;
                $fwrite(wfile,"STOP,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",edge_id,starts,epoch,
                    `M_CPU.cycle_count,`M_CPU.instret_count,owner,os);
            end
        end
        if(`M_CPU.retire_valid !== previous_completion)$fatal(1,"retire edge alignment");
        // Retire consumes the previous edge's completion and precedes any new owner.
        if(owner && owner_complete && `M_CPU.retire_valid)begin
            if(edge_id!=oc+1 || `M_CPU.wb_pc!==opc || `M_CPU.wb_rd!==rd ||
                `M_CPU.wb_data!==result || `M_CPU.wb_we!==(rd!=0))
                $fatal(1,"M retirement ownership mismatch owner=%0d",owner_id);
            $fwrite(ofile,"%0d,%08h,%0d,%0d,%08h,%08h,%08h,%0d,%0d,%0d,%0d,%0d\n",
                owner_id,opc,op,rd,lhs,rhs,result,os,od,oc,edge_id,ow);
            $fwrite(efile,"retire,%0d,%0d,%0d,%0d,%0d\n",edge_id,owner_id,op,epoch,live);
            if(live)retire_counts[op]=retire_counts[op]+1;
            owner=0;owner_complete=0;owner_done=0;
        end
        if(`M_CPU.m_start_x)begin
            if(owner || `M_CPU.m_busy || `M_CPU.g_m.u_muldiv.state!=0)
                $fatal(1,"start cannot be accepted owner=%0d",owner_id);
            owner=1;owner_id=owner_id+1;os=edge_id;od=0;oc=0;ow=0;
            owner_complete=0;owner_done=0;
            op=`M_CPU.instr_x[14:12];opc=`M_CPU.pc_x;rd=`M_CPU.rd_addr_x;
            lhs=`M_CPU.rs1_value_x;rhs=`M_CPU.rs2_value_x;
            $fwrite(efile,"start,%0d,%0d,%0d,%0d,%0d\n",edge_id,owner_id,op,epoch,live);
            if(live)start_counts[op]=start_counts[op]+1;
        end
        if(`M_CPU.m_complete_x)begin
            if(!owner || owner_complete || !owner_done || od>=edge_id ||
                `M_CPU.m_pc_q!==opc || `M_CPU.m_rd_q!==rd)
                $fatal(1,"completion lost/duplicated owner");
            owner_complete=1;oc=edge_id;result=`M_CPU.m_result;
            $fwrite(efile,"cpu_complete,%0d,%0d,%0d,%0d,%0d\n",edge_id,owner_id,op,epoch,live);
            if(live)complete_counts[op]=complete_counts[op]+1;
        end
        if(`M_CPU.m_wait_x)begin
            if(!owner || owner_complete || `M_CPU.instr_x[14:12]!==op || `M_CPU.pc_x!==opc)
                $fatal(1,"wait missing stable M owner");
            ow=ow+1;
            if(live)wait_counts[op]=wait_counts[op]+1;
        end
        class_now=0;
        if(`M_CPU.counting_started || (`M_CPU.valid_x && `M_CPU.instr_supported_x))begin
            if(`M_CPU.stall_x && (`M_CPU.mem_active || `M_CPU.mem_start_x))
                class_now=`M_CPU.mem_req_mmio ? 6'b010000 :
                    (`M_CPU.mem_req_write ? 6'b001000 : 6'b000100);
            else if(!`M_CPU.valid_x && `M_CPU.perf_redirect_pending &&
                !`M_CPU.trap_event && !`M_CPU.mret_commit_x && !`M_CPU.imem_fault && !`M_CPU.dmem_fault)
                class_now=6'b100000;
            else if(!`M_CPU.valid_x && !`M_CPU.imem_fault && !`M_CPU.dmem_fault)class_now=6'b000010;
            else class_now=6'b000001;
        end
        if(live)begin
            if(`M_CPU.retire_valid)retired=retired+1;
            if(class_now==0 || (class_now & (class_now-1))!=0)$fatal(1,"class not onehot");
            for(c=0;c<6;c=c+1)if(class_now[c])begin
                cycle_counts[c]=cycle_counts[c]+1;
                i=c*4+(`M_CPU.retire_valid ? 2 : 0)+(`M_CPU.m_wait_x ? 1 : 0);
                contingency[i]=contingency[i]+1;
            end
        end
        previous_completion=`M_CPU.retire_to_wb;
        #1;
        if(class_now!==`M_CPU.perf_cycle_events)$fatal(1,"passive class prediction != registered CPU event");
        if(owner && !owner_done && `M_CPU.m_done)begin
            owner_done=1;od=edge_id;
            if(`M_CPU.m_busy)$fatal(1,"done with busy");
            $fwrite(efile,"unit_done,%0d,%0d,%0d,%0d,%0d\n",edge_id,owner_id,op,epoch,live);
            if(live)done_counts[op]=done_counts[op]+1;
        end
    end

    initial begin
        wait(workload.test_pass===1);@(negedge clk);
        if(starts<1 || epoch!=starts || stops!=1 || live || owner)
            $fatal(1,"window or unfinished owner gate");
        frozen_cycles={`M_STATS.stop_snapshot[1],`M_STATS.stop_snapshot[0]}-
            {`M_STATS.start_snapshot[1],`M_STATS.start_snapshot[0]};
        frozen_retired={`M_STATS.stop_snapshot[3],`M_STATS.stop_snapshot[2]}-
            {`M_STATS.start_snapshot[3],`M_STATS.start_snapshot[2]};
        frozen_sum=0;
        for(i=0;i<6;i=i+1)begin
            snap_cycles[i]=`M_STATS.cycle_stop_snapshot[i]-`M_STATS.cycle_start_snapshot[i];
            frozen_sum=frozen_sum+snap_cycles[i];
            if(snap_cycles[i]!=cycle_counts[i])$fatal(1,"class %0d mismatch",i);
        end
        if(frozen_cycles!=stop_edge-start_edge || retired!=frozen_retired || frozen_sum!=frozen_cycles)
            $fatal(1,"six-class/retire closure failed");
        mfile=$fopen({output_dir,"/observer_metadata.csv"},"w");
        $fwrite(mfile,"key,value\nprofile,%s\nraw_starts,%0d\nselected_epoch,%0d\nstop_triggers,%0d\nstart_edge,%0d\nstop_edge,%0d\nfrozen_cycles,%0d\nfrozen_retired,%0d\noriginal_workload_pass,1\nall_owners,%0d\n",`COREMARK_PROFILE,starts,epoch,stops,start_edge,stop_edge,frozen_cycles,frozen_retired,owner_id);
        for(i=0;i<6;i=i+1)$fwrite(mfile,"cycle_class_%0d,%0d\n",i,snap_cycles[i]);
        for(i=0;i<8;i=i+1)begin
            $fwrite(mfile,"op_%0d_start,%0d\nop_%0d_done,%0d\nop_%0d_complete,%0d\nop_%0d_retire,%0d\nop_%0d_wait,%0d\n",i,start_counts[i],i,done_counts[i],i,complete_counts[i],i,retire_counts[i],i,wait_counts[i]);
        end
        for(i=0;i<24;i=i+1)$fwrite(mfile,"contingency_%0d,%0d\n",i,contingency[i]);
        $fclose(ofile);$fclose(efile);$fclose(wfile);$fclose(mfile);
        test_pass=1;
        $display("CPU5 M BREAKDOWN PASS profile=%s cycles=%0d retired=%0d owners=%0d",`COREMARK_PROFILE,frozen_cycles,frozen_retired,owner_id);
        $stop;
    end
endmodule
