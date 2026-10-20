`timescale 1ns/1ps
`ifndef COREMARK_CONFIG
`define COREMARK_CONFIG "programs/coremark_d0_cache_on_btb_smoke_config.vh"
`endif
`include `COREMARK_CONFIG
`define D0_CPU workload.dut.u_core.u_cpu
`define D0_CORE workload.dut.u_core
`define D0_RAM workload.dut.u_core.g_d0_bram.u_ram
`define D0_STATS workload.dut.u_stats
// Native BRAM timing only. No invented AXI timestamps for local RAM traffic.
module coremark_d0_measure_tb;
    coremark_d0_workload_tb #(.STOP_ON_PASS(0),.ENABLE_D0_BRAM(1)) workload();
    wire clk=workload.clk,rst_n=workload.rst_n;
    reg test_pass=0,active=0,live=0,released=0,window_edge=0,wait_edge=0,check_commit=0;
    integer edge_number=0,transaction=0,epoch=0,starts=0,stops=0,start_edge=-1,stop_edge=-1;
    integer tx_file,window_file,i,lane,slot,launch=-1,cpu_accept=-1,backend_accept=-1,commit=-1,cpu_response=-1;
    integer effects=0,total_effects=0,completed=0,window_stores=0,window_effects=0,txn_epoch=0,txn_waits=0;
    integer hit=0,txn_window=0;
    reg [31:0] txn_pc=0,txn_addr=0,txn_data=0,expected_word=0;
    reg [3:0] txn_strb=0;reg [1:0] txn_size=0;
    reg [63:0] window_cycles=0,window_waits=0,start_counter=0,stop_counter=0,classes[0:5];
    initial begin
        if(`COREMARK_ENABLE_D0_BRAM!=1||`COREMARK_DATA_BACKEND_ID!=1||`COREMARK_CACHE_FLAGS!=3)
            $fatal(1,"D0 measurement requires the D0 firmware/backend and both caches");
        tx_file=$fopen($sformatf("build/verification/coremark_d0_%0s_transactions.csv",`COREMARK_PROFILE),"w");
        window_file=$fopen($sformatf("build/verification/coremark_d0_%0s_window.csv",`COREMARK_PROFILE),"w");
        if(!tx_file||!window_file) $fatal(1,"Create build/verification before D0 measurement");
        $fwrite(tx_file,"profile,transaction,epoch,in_window,pc,addr,wdata,wstrb,size,hit,launch,cpu_accept,backend_accept,commit,cpu_response,retire,effects,data_write_wait,total_cycles\n");
        for(i=0;i<6;i=i+1) classes[i]=0;
        wait(workload.test_pass);#2;
        if(active||completed!=transaction||completed!=total_effects||starts<1||stops!=1||epoch!=starts||live||window_stores==0)
            $fatal(1,"D0 lifetime/window transaction ledger failed");
        if(stop_edge-start_edge!=window_cycles||stop_counter-start_counter!=window_cycles||
            window_waits!==`D0_STATS.cycle_stop_snapshot[3]-`D0_STATS.cycle_start_snapshot[3]||
            window_effects!=window_stores||window_waits!=window_stores*2)
            $fatal(1,"D0 frozen write wait/window/effect ledger failed");
        for(i=0;i<6;i=i+1) if(classes[i]!==`D0_STATS.cycle_stop_snapshot[i]-`D0_STATS.cycle_start_snapshot[i])
            $fatal(1,"D0 independent cycle class differs from frozen bank class=%0d",i);
        $fwrite(window_file,"key,value\nprofile,%0s\nstart_triggers,%0d\nselected_start_triggers,1\nstop_triggers,%0d\nepoch,%0d\nstart_edge,%0d\nstop_edge,%0d\nstart_counter,%0d\nstop_counter,%0d\nwindow_cycles,%0d\nwindow_instret,%0d\nstores_total,%0d\neffects_total,%0d\nstores_window,%0d\neffects_window,%0d\nmeasured_data_write_wait,%0d\nfrozen_data_write_wait,%0d\nboundary_crossings,0\nerrors,0\ncanceled,0\n",
            `COREMARK_PROFILE,starts,stops,epoch,start_edge,stop_edge,start_counter,stop_counter,window_cycles,
            workload.stored_instret_delta,completed,total_effects,window_stores,window_effects,window_waits,
            `D0_STATS.cycle_stop_snapshot[3]-`D0_STATS.cycle_start_snapshot[3]);
        for(i=0;i<6;i=i+1) $fwrite(window_file,"cycle_class_%0d,%0d\n",i,classes[i]);
        $fwrite(window_file,"dcache_access,%0d\ndcache_hit,%0d\ndcache_miss,%0d\ndcache_refill_words,%0d\ndcache_errors,%0d\ndcache_write,%0d\ndcache_bypass,%0d\n",
            workload.stored_d[0],workload.stored_d[1],workload.stored_d[2],workload.stored_d[3],workload.stored_d[4],workload.stored_d[5],workload.stored_d[6]);
        $fclose(tx_file);$fclose(window_file);test_pass=1;
        $display("COREMARK D0 MEASURE PASS profile=%0s stores=%0d write_wait=%0d window=%0d STORE=2 cycles; physical writes and frozen classes close",`COREMARK_PROFILE,window_stores,window_waits,window_cycles);$stop;
    end
    always @(posedge clk) begin
        edge_number=edge_number+1;check_commit=0;
        if(!rst_n) begin if(released) $fatal(1,"D0 workload reset during measurement");end
        else if(!test_pass) begin
            released=1;
            if(workload.dut.stats_arvalid&&workload.dut.stats_arready) begin
                if(workload.dut.stats_araddr==32'h30000000) begin
                    if(active||stops) $fatal(1,"D0 START overlapped STORE or followed STOP");
                    starts=starts+1;epoch=epoch+1;start_edge=edge_number;start_counter=workload.cycle_count;live=1;
                    window_cycles=0;window_waits=0;window_stores=0;window_effects=0;
                    for(i=0;i<6;i=i+1) classes[i]=0;
                end else if(workload.dut.stats_araddr==32'h30000004) begin
                    if(active||!live||stops) $fatal(1,"D0 STOP boundary/lifecycle violation");
                    stops=stops+1;stop_edge=edge_number;stop_counter=workload.cycle_count;live=0;
                end
            end
            window_edge=live;
            wait_edge=(`D0_CPU.counting_started||(`D0_CPU.valid_x&&`D0_CPU.instr_supported_x))&&
                `D0_CPU.stall_x&&(`D0_CPU.mem_active||`D0_CPU.mem_start_x)&&!`D0_CPU.mem_req_mmio&&`D0_CPU.mem_req_write;
            if(`D0_CORE.bridge_req_valid&&`D0_CORE.bridge_req_addr>=32'h10000&&`D0_CORE.bridge_req_addr<32'h14000&&`D0_CORE.axi_req_valid)
                $fatal(1,"D0 ordinary RAM request leaked into AXI bridge");
            if(`D0_CPU.mem_start_x&&`D0_CPU.is_store_x&&!`D0_CPU.mem_req_mmio) begin
                if(active) $fatal(1,"D0 overlapped real-workload STORE");
                active=1;transaction=transaction+1;txn_epoch=epoch;txn_window=live;
                launch=edge_number;cpu_accept=-1;backend_accept=-1;commit=-1;cpu_response=-1;effects=0;txn_waits=0;
                txn_pc=`D0_CPU.pc_x;txn_addr=`D0_CORE.dmem_req_addr;txn_data=`D0_CORE.dmem_req_wdata;
                txn_strb=`D0_CORE.dmem_req_wstrb;txn_size=`D0_CORE.dmem_req_size;
                if(txn_addr<32'h10000||txn_addr>=32'h14000) $fatal(1,"D0 workload unexpected non-RAM external STORE");
            end
            if(wait_edge&&!active) $fatal(1,"D0 write-wait event has no STORE owner");
            if(active&&`D0_CORE.dmem_req_valid&&`D0_CORE.dmem_req_ready&&`D0_CORE.dmem_req_write) begin
                if(cpu_accept>=0||{`D0_CORE.dmem_req_addr,`D0_CORE.dmem_req_wdata,`D0_CORE.dmem_req_wstrb,`D0_CORE.dmem_req_size}!=={txn_addr,txn_data,txn_strb,txn_size})
                    $fatal(1,"D0 CPU request descriptor changed");
                cpu_accept=edge_number;hit=`D0_CORE.g_dcache.u_cache.hit0||`D0_CORE.g_dcache.u_cache.hit1;
            end
            if(active&&`D0_CORE.bridge_req_valid&&`D0_CORE.bridge_req_ready&&`D0_CORE.bridge_req_write) begin
                if(backend_accept>=0||{`D0_CORE.bridge_req_addr,`D0_CORE.bridge_req_wdata,`D0_CORE.bridge_req_wstrb,`D0_CORE.bridge_req_size}!=={txn_addr,txn_data,txn_strb,txn_size})
                    $fatal(1,"D0 cache/backend request descriptor changed");
                backend_accept=edge_number;
            end
            if(`D0_RAM.mem_we) begin
                if(!active||effects||!`D0_RAM.request_ok||`D0_RAM.req_addr!==txn_addr||`D0_RAM.req_wdata!==txn_data||`D0_RAM.req_wstrb!==txn_strb)
                    $fatal(1,"D0 unexpected/duplicate physical RAM write");
                effects=effects+1;total_effects=total_effects+1;commit=edge_number;
                if(live) window_effects=window_effects+1;
                slot=(txn_addr-32'h10000)>>2;expected_word=`D0_RAM.u_data_mem.mem[slot];
                for(lane=0;lane<4;lane=lane+1) if(txn_strb[lane]) expected_word[lane*8+:8]=txn_data[lane*8+:8];
                check_commit=1;
            end
            if(active&&`D0_CORE.dmem_rsp_valid&&`D0_CORE.dmem_rsp_ready) begin
                if(`D0_CORE.dmem_rsp_error||!`D0_CORE.bridge_rsp_valid||!`D0_CORE.bridge_rsp_ready)
                    $fatal(1,"D0 write response error or backend/CPU consumption mismatch");
                cpu_response=edge_number;
            end
            #1;
            if(`D0_CPU.perf_cycle_events[3]!==wait_edge) $fatal(1,"D0 independent write-wait event mismatch");
            if(check_commit&&`D0_RAM.u_data_mem.mem[slot]!==expected_word) $fatal(1,"D0 masked physical RAM readback failed");
            if(wait_edge) begin txn_waits=txn_waits+1;if(window_edge) window_waits=window_waits+1;end
            if(window_edge) begin window_cycles=window_cycles+1;for(i=0;i<6;i=i+1) if(`D0_CPU.perf_cycle_events[i]) classes[i]=classes[i]+1;end
            if(active&&workload.retire_valid&&workload.wb_pc==txn_pc) begin
                if(cpu_accept<launch||backend_accept<cpu_accept||commit!=backend_accept||cpu_response!=edge_number||
                    edge_number-launch!=2||txn_waits!=2||effects!=1||txn_window!=live)
                    $fatal(1,"D0 native STORE timing/effect/window contract failed");
                completed=completed+1;if(live) window_stores=window_stores+1;
                $fwrite(tx_file,"%0s,%0d,%0d,%0d,%08h,%08h,%08h,%h,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                    `COREMARK_PROFILE,transaction,txn_epoch,txn_window,txn_pc,txn_addr,txn_data,txn_strb,txn_size,hit,
                    launch,cpu_accept,backend_accept,commit,cpu_response,edge_number,effects,txn_waits,edge_number-launch);
                active=0;
            end else if(active&&cpu_response>=0) $fatal(1,"D0 response did not retire matching STORE on same edge");
        end
    end
endmodule
`undef D0_CPU
`undef D0_CORE
`undef D0_RAM
`undef D0_STATS
