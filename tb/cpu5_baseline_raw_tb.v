`timescale 1ns/1ps
`ifndef COREMARK_CONFIG
`define COREMARK_CONFIG "programs/coremark_d0_m_cache_on_btb_smoke_config.vh"
`endif
`include `COREMARK_CONFIG
`define RAW_CPU workload.dut.u_core.u_cpu
`define RAW_SOC workload.dut
`define RAW_STATS workload.dut.u_stats

// Passive phase-0 observer. The unchanged workload remains the success gate.
// PRE-edge retire_valid/wb_pc feeds instret at this edge; BP resolves one
// edge earlier. Record both ages, then reconcile their distinct windows.
module cpu5_baseline_raw_tb;
    coremark_d0_workload_tb #(.STOP_ON_PASS(0)) workload();
    wire clk = workload.clk;
    wire rst_n = workload.rst_n;
    reg test_pass = 0;
    reg [31:0] rom [0:8191];
    integer rf, ef, mf, i;
    string output_dir;
    reg [63:0] edge_id = 0, seq_id = 0;
    reg [63:0] start_edge = 0, stop_edge = 0;
    integer raw_starts = 0, raw_stops = 0, selected_epoch = 0;
    reg live = 0;
    reg prev_complete = 0, prev_resolve = 0, prev_predictable = 0;
    reg prev_redirect = 0, prev_direction_error = 0;
    reg [31:0] prev_resolve_pc = 0;
    reg [63:0] measured_retired = 0, measured_resolved = 0;
    reg [63:0] measured_mismatch = 0, measured_direrr = 0;
    reg [63:0] frozen_retired, frozen_resolved, frozen_mismatch, frozen_direrr;
    reg [63:0] frozen_cycles, frozen_profile_sum;
    reg [63:0] profile_delta [0:5];
    reg [31:0] decoded_instr;
    integer retirement_checks = 0;

    initial begin
        if (!$value$plusargs("RAW_OUTPUT=%s", output_dir))
            $fatal(1, "RAW_OUTPUT directory is required");
        for (i=0; i<8192; i=i+1) rom[i] = 32'h00000013;
        $readmemh(`COREMARK_ROM_FILE, rom);
        rf = $fopen({output_dir,"/retirement_trace.csv"}, "w");
        ef = $fopen({output_dir,"/window_endpoints.csv"}, "w");
        if (!rf || !ef) $fatal(1, "cannot open observer files");
        $fwrite(rf,"seq,retire_edge,pc,instr,wb_we,wb_rd,resolve_edge,resolve_valid,predictable,normal_redirect,direction_error\n");
        $fwrite(ef,"kind,edge,raw_starts,epoch,cycle_pre,instret_pre,resolved_pre,mismatch_pre,direrr_pre,retire_pre,resolve_pre,normal_redirect_pre\n");
    end

    always @(posedge clk) begin
        if (rst_n) begin
            edge_id = edge_id + 1;
            if (`RAW_SOC.stats_arvalid && `RAW_SOC.stats_arready) begin
                if (`RAW_SOC.stats_araddr == 32'h30000000) begin
                    if (raw_stops != 0) $fatal(1,"START after STOP");
                    raw_starts = raw_starts + 1;
                    selected_epoch = raw_starts;
                    live = 1;
                    start_edge = edge_id;
                    measured_retired = 0; measured_resolved = 0;
                    measured_mismatch = 0; measured_direrr = 0;
                    $fwrite(ef,"START,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                        edge_id,raw_starts,selected_epoch,`RAW_CPU.cycle_count,`RAW_CPU.instret_count,
                        `RAW_CPU.bp_resolved_count,`RAW_CPU.bp_mispredict_count,
                        `RAW_CPU.bp_direction_error_count,`RAW_CPU.retire_valid,
                        `RAW_CPU.bp_resolve_valid,`RAW_CPU.normal_redirect_x);
                end else if (`RAW_SOC.stats_araddr == 32'h30000004) begin
                    raw_stops = raw_stops + 1;
                    if (raw_stops != 1 || raw_starts < 1 || !live)
                        $fatal(1,"invalid STOP epoch");
                    live = 0; stop_edge = edge_id;
                    $fwrite(ef,"STOP,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                        edge_id,raw_starts,selected_epoch,`RAW_CPU.cycle_count,`RAW_CPU.instret_count,
                        `RAW_CPU.bp_resolved_count,`RAW_CPU.bp_mispredict_count,
                        `RAW_CPU.bp_direction_error_count,`RAW_CPU.retire_valid,
                        `RAW_CPU.bp_resolve_valid,`RAW_CPU.normal_redirect_x);
                end
            end
            if (`RAW_CPU.retire_valid !== prev_complete)
                $fatal(1,"retire_valid does not match prior completion edge=%0d",edge_id);
            if (`RAW_CPU.retire_valid && (stop_edge == 0 || edge_id <= stop_edge+1)) begin
                if (workload.wb_pc[1:0] != 0 || workload.wb_pc >= 32768)
                    $fatal(1,"retirement PC out of ROM %h",workload.wb_pc);
                decoded_instr = rom[workload.wb_pc >> 2];
                if (decoded_instr !== workload.dut.u_core.u_imem.u_instr_mem.mem[workload.wb_pc >> 2])
                    $fatal(1,"observer ROM differs from actual ROM");
                if (prev_resolve && prev_resolve_pc !== workload.wb_pc)
                    $fatal(1,"resolve/retire age mismatch prev=%h retire=%h",prev_resolve_pc,workload.wb_pc);
                seq_id = seq_id + 1;
                retirement_checks = retirement_checks + 1;
                $fwrite(rf,"%0d,%0d,%08h,%08h,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                    seq_id,edge_id,workload.wb_pc,decoded_instr,`RAW_CPU.wb_we,`RAW_CPU.wb_rd,
                    edge_id-1,prev_resolve,prev_predictable,prev_redirect,prev_direction_error);
            end
            if (live) begin
                if (`RAW_CPU.retire_valid) measured_retired = measured_retired + 1;
                if (`RAW_CPU.bp_resolve_valid && `RAW_CPU.bp_predictable_x)
                    measured_resolved = measured_resolved + 1;
                if (`RAW_CPU.bp_resolve_valid && `RAW_CPU.bp_next_mismatch_x)
                    measured_mismatch = measured_mismatch + 1;
                if (`RAW_CPU.bp_resolve_valid && `RAW_CPU.bp_direction_error_x)
                    measured_direrr = measured_direrr + 1;
            end
            prev_complete = `RAW_CPU.retire_to_wb;
            prev_resolve = `RAW_CPU.bp_resolve_valid;
            prev_resolve_pc = `RAW_CPU.pc_x;
            prev_predictable = `RAW_CPU.bp_resolve_valid && `RAW_CPU.bp_predictable_x;
            prev_redirect = `RAW_CPU.normal_redirect_x && `RAW_CPU.redirect_x;
            prev_direction_error = `RAW_CPU.bp_resolve_valid && `RAW_CPU.bp_direction_error_x;
        end
    end

    initial begin
        wait(workload.test_pass === 1);
        @(negedge clk);
        if (raw_starts < 1 || selected_epoch != raw_starts || raw_stops != 1 || live)
            $fatal(1,"window gate failed");
        frozen_cycles = {`RAW_STATS.stop_snapshot[1],`RAW_STATS.stop_snapshot[0]} -
                        {`RAW_STATS.start_snapshot[1],`RAW_STATS.start_snapshot[0]};
        frozen_retired = {`RAW_STATS.stop_snapshot[3],`RAW_STATS.stop_snapshot[2]} -
                         {`RAW_STATS.start_snapshot[3],`RAW_STATS.start_snapshot[2]};
        frozen_resolved = `RAW_STATS.bp_stop_snapshot[3] - `RAW_STATS.bp_start_snapshot[3];
        frozen_mismatch = `RAW_STATS.bp_stop_snapshot[4] - `RAW_STATS.bp_start_snapshot[4];
        frozen_direrr = `RAW_STATS.bp_stop_snapshot[5] - `RAW_STATS.bp_start_snapshot[5];
        frozen_profile_sum = 0;
        for (i=0;i<6;i=i+1) begin
            profile_delta[i] = `RAW_STATS.cycle_stop_snapshot[i]-`RAW_STATS.cycle_start_snapshot[i];
            frozen_profile_sum = frozen_profile_sum + profile_delta[i];
        end
        if (frozen_cycles != stop_edge-start_edge || frozen_profile_sum != frozen_cycles ||
            frozen_retired != measured_retired || frozen_resolved != measured_resolved ||
            frozen_mismatch != measured_mismatch || frozen_direrr != measured_direrr)
            $fatal(1,"observer/frozen closure failed retired=%0d/%0d resolved=%0d/%0d mismatch=%0d/%0d",
                measured_retired,frozen_retired,measured_resolved,frozen_resolved,measured_mismatch,frozen_mismatch);
        mf = $fopen({output_dir,"/observer_metadata.csv"},"w");
        $fwrite(mf,"key,value\nprofile,%s\nraw_starts,%0d\nselected_epoch,%0d\nstop_triggers,%0d\nstart_edge,%0d\nstop_edge,%0d\nfrozen_cycles,%0d\nfrozen_retired,%0d\nfrozen_resolved,%0d\nfrozen_mismatch,%0d\nfrozen_direrr,%0d\ntrace_retirements,%0d\noriginal_workload_pass,1\n",
            `COREMARK_PROFILE,raw_starts,selected_epoch,raw_stops,start_edge,stop_edge,
            frozen_cycles,frozen_retired,frozen_resolved,frozen_mismatch,frozen_direrr,retirement_checks);
        for(i=0;i<6;i=i+1) $fwrite(mf,"cycle_class_%0d,%0d\n",i,profile_delta[i]);
        $fclose(rf); $fclose(ef); $fclose(mf);
        test_pass = 1;
        $display("CPU5 BASELINE RAW PASS profile=%s edges=%0d retired=%0d resolved=%0d mismatch=%0d",
            `COREMARK_PROFILE,frozen_cycles,frozen_retired,frozen_resolved,frozen_mismatch);
        $stop;
    end
endmodule
