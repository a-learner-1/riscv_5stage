`timescale 1ns/1ps
`ifndef COREMARK_CONFIG
`define COREMARK_CONFIG "programs/coremark_axi_cache_on_btb_smoke_config.vh"
`endif
`ifndef COREMARK_PROFILE
`include `COREMARK_CONFIG
`endif

// D1 measurement wrapper (read-only observer, no forces, no gating).
//   M1: per-STORE cycle distance S from the STORE issue edge to the next
//       non-local memory operation, the histogram of S, and the residual
//       wait a 1-entry posted write buffer might still incur (projection,
//       not a cycle-accurate performance estimator).
//   M2: split of bp_direction_error into "BTB miss -> default not-taken" vs
//       "BTB hit but the 2-bit counter is wrong", plus the aliasing rate that
//       makes branch_predictor.v REINITIALIZE the counter instead of learning.
// It instantiates the real coremark_axi_tb, so every CRC/UART/RAM/frozen
// counter self-check still runs unchanged.
`define D1_CPU  workload.dut.u_core.u_cpu
`define D1_IF   workload.dut.u_core.u_cpu.u_if_stage
`define D1_BP   workload.dut.u_core.u_cpu.u_if_stage.g_branch_predictor.u_branch_predictor
`define D1_SOC  workload.dut
`define D1_STAT workload.dut.u_stats

module coremark_d1_measure_tb;
    // A 1-entry posted write buffer removes the measured 7 cycles of STORE
    // blocking. The next memory operation therefore arrives 7 cycles EARLIER,
    // so it only waits when S < 2*7:
    //     residual = max(0, 14 - S)      (not max(0, 7 - S))
    localparam integer M1_CAP   = 40;
    localparam integer M1_SAVE  = 7;
    localparam integer M1_LIMIT = 2*M1_SAVE;
    localparam [63:0]  SAVE64   = 64'd7;

    reg test_pass = 0;
    // Keep the original TB defaults; Tcl resumes its successful stop for
    // the observer to finalize, so this wrapper needs no TB parameter.
    coremark_axi_tb workload();
    wire clk   = workload.clk;
    wire rst_n = workload.rst_n;

    reg [63:0] t64 = 0;
    reg [63:0] start_t = 0, stop_t = 0;
    integer start_triggers = 0, stop_triggers = 0, crossings = 0, epoch = 0;
    // G4 revised for the current firmware: two raw STARTs, latest epoch selected.
    integer selected_start_triggers = 0;
    reg released = 0, window_live = 0, window_this_edge = 0;

    reg     m1_pending = 0;
    integer m1_gap = 0;
    integer m1_stores = 0;
    integer m1_censored_cap = 0, m1_truncated_window = 0;
    // Bucket CAP includes exactly-CAP complete gaps and right-censored S >= CAP.
    integer m1_hist [0:M1_CAP];
    reg [63:0] m1_sum = 0, m1_residual = 0, m1_residual_trunc = 0;

    reg [63:0] q_busy_until = 0, q_wait_sum = 0, q_waits_seen = 0;
    integer q_projection_clamps = 0;
    reg [63:0] q_nstores = 0, q_now = 0, q_wait = 0, q_shift = 0;

    reg [63:0] e_resolved = 0, e_hit = 0, e_direrr = 0;
    reg [63:0] e_miss = 0, e_wrong_taken = 0, e_wrong_nt = 0;
    reg [63:0] e_relearn = 0, e_relearn_nojal = 0, e_jalr_unpred = 0;
    reg [63:0] frozen_direrr = 0, frozen_resolved = 0, frozen_write_wait = 0;

    integer wf, bf, k, nsum;

    wire ev_mem    = `D1_CPU.mem_start_x && !`D1_CPU.mem_req_mmio;
    wire ev_store  = `D1_CPU.mem_start_x && `D1_CPU.is_store_x && !`D1_CPU.mem_req_mmio;
    wire m2_pred   = `D1_CPU.bp_resolve_valid && `D1_CPU.bp_predictable_x;
    wire m2_direrr = m2_pred && `D1_CPU.bp_direction_error_x;

    task m1_record;
        input integer gap;
        input integer truncated;
        integer g;
        begin
            g = gap;
            if (g > M1_CAP) g = M1_CAP;
            m1_hist[g] = m1_hist[g] + 1;
            m1_sum = m1_sum + g;
            // mode 0: complete observation, exact residual;
            // mode 1: CAP-censored, S>=CAP>=LIMIT means residual zero;
            // mode 2: window-censored, observed gap is a LOWER bound on S.
            if (g < M1_LIMIT) begin
                if (truncated == 0)
                    m1_residual = m1_residual + (M1_LIMIT - g);
                else if (truncated == 2)
                    m1_residual_trunc = m1_residual_trunc + (M1_LIMIT - g);
            end
        end
    endtask

    // The ID probe in portable_init also freezes the hardware START bank.
    // start_time replaces it. Discard the old observer epoch in exactly the
    // same way; raw trigger/epoch/crossing counters remain lifetime evidence.
    task rearm_window;
        integer h;
        begin
            selected_start_triggers = 0;
            start_t = 0; stop_t = 0;
            window_live = 0; window_this_edge = 0;
            m1_pending = 0; m1_gap = 0; m1_stores = 0;
            m1_censored_cap = 0; m1_truncated_window = 0;
            for (h = 0; h <= M1_CAP; h = h + 1) m1_hist[h] = 0;
            m1_sum = 0; m1_residual = 0; m1_residual_trunc = 0;
            q_busy_until = 0; q_wait_sum = 0; q_waits_seen = 0;
            q_projection_clamps = 0;
            q_nstores = 0; q_now = 0; q_wait = 0; q_shift = 0;
            e_resolved = 0; e_hit = 0; e_direrr = 0;
            e_miss = 0; e_wrong_taken = 0; e_wrong_nt = 0;
            e_relearn = 0; e_relearn_nojal = 0; e_jalr_unpred = 0;
            frozen_direrr = 0; frozen_resolved = 0; frozen_write_wait = 0;
        end
    endtask

    initial begin
        for (k = 0; k <= M1_CAP; k = k + 1) m1_hist[k] = 0;
    end

    always @(posedge clk) begin
        t64 = t64 + 64'd1;
        if (!rst_n) begin
            if (released) $fatal(1, "D1 measurement cannot combine reset epochs");
            m1_pending = 0; m1_gap = 0;
        end else if (!test_pass) begin
            released = 1;

            // Window triggers: the START edge is included, the STOP edge is not.
            if (`D1_SOC.stats_arvalid && `D1_SOC.stats_arready) begin
                if (`D1_SOC.stats_araddr == 32'h30000000) begin
                    start_triggers = start_triggers + 1;
                    if (stop_triggers != 0 || start_triggers > 2 ||
                        epoch != start_triggers - 1 ||
                        (start_triggers == 1 && window_live) ||
                        (start_triggers == 2 && !window_live)) begin
                        crossings = crossings + 1;
                        $fatal(1, "D1 unexpected START sequence raw=%0d epoch=%0d stop=%0d live=%0d",
                               start_triggers, epoch, stop_triggers, window_live);
                    end
                    epoch = epoch + 1;
                    rearm_window();
                    selected_start_triggers = 1;
                    start_t = t64;
                    window_live = 1;
                    // Log pre-NBA BP inputs/counters at the actual handshake.
                    // The START edge is subsequently counted in the new epoch.
                    $display("COREMARK D1 ENDPOINT START profile=%0s edge=%0d sim_time=%0t raw_start=%0d selected_start=%0d epoch=%0d bp_resolve_valid=%b bp_predictable=%b m2_pred=%b m2_direrr=%b bp_resolved_pre=%0d bp_direrr_pre=%0d",
                             `COREMARK_PROFILE, t64, $time, start_triggers,
                             selected_start_triggers, epoch, `D1_CPU.bp_resolve_valid,
                             `D1_CPU.bp_predictable_x, m2_pred, m2_direrr,
                             `D1_CPU.bp_resolved_count, `D1_CPU.bp_direction_error_count);
                end else if (`D1_SOC.stats_araddr == 32'h30000004) begin
                    stop_triggers = stop_triggers + 1;
                    if (stop_triggers != 1 || !window_live || start_triggers != 2 ||
                        selected_start_triggers != 1 || epoch != 2) begin
                        crossings = crossings + 1;
                        $fatal(1, "D1 unexpected STOP sequence raw_start=%0d selected_start=%0d epoch=%0d stop=%0d live=%0d",
                               start_triggers, selected_start_triggers, epoch,
                               stop_triggers, window_live);
                    end
                    stop_t = t64;
                    // STOP is excluded; these events are logged but not counted.
                    $display("COREMARK D1 ENDPOINT STOP profile=%0s edge=%0d sim_time=%0t raw_start=%0d selected_start=%0d epoch=%0d bp_resolve_valid=%b bp_predictable=%b m2_pred=%b m2_direrr=%b bp_resolved_pre=%0d bp_direrr_pre=%0d measured_resolved=%0d measured_direrr=%0d",
                             `COREMARK_PROFILE, t64, $time, start_triggers,
                             selected_start_triggers, epoch, `D1_CPU.bp_resolve_valid,
                             `D1_CPU.bp_predictable_x, m2_pred, m2_direrr,
                             `D1_CPU.bp_resolved_count, `D1_CPU.bp_direction_error_count,
                             e_resolved, e_direrr);
                    // STOP edge excluded. Censor exposure through the STOP boundary:
                    // the normal in-window aging below will not execute at STOP.
                    if (m1_pending) begin
                        m1_gap = m1_gap + 1;
                        m1_record(m1_gap, 2);
                        m1_truncated_window = m1_truncated_window + 1;
                        m1_pending = 0;
                    end
                    window_live = 0;
                end
            end
            window_this_edge = window_live;

            if (window_this_edge) begin
                // ---------------- M1 ------------------------------------------
                if (m1_pending) m1_gap = m1_gap + 1;
                if (m1_pending && ev_mem) begin
                    m1_record(m1_gap, 0);
                    m1_pending = 0;
                end
                if (ev_store) begin
                    if (m1_pending)
                        $fatal(1, "D1 M1 interval overlapped a STORE without settle");
                    m1_pending = 1; m1_gap = 0;
                    m1_stores  = m1_stores + 1;
                end
                if (m1_pending && m1_gap >= M1_CAP) begin
                    m1_record(M1_CAP, 1);
                    m1_censored_cap = m1_censored_cap + 1;
                    m1_pending = 0;
                end

                // ---------------- cascade-aware queue model -------------------
                // Heuristic time-axis projection only; not a cycle-accurate queue.
                if ((q_nstores * SAVE64) >= q_waits_seen)
                    q_shift = (q_nstores * SAVE64) - q_waits_seen;
                else begin
                    q_shift = 64'd0;  // avoid unsigned arithmetic underflow
                    q_projection_clamps = q_projection_clamps + 1;
                end
                if (ev_mem) begin
                    if (q_shift > (t64 - 64'd1)) begin
                        q_now = 64'd0;
                        q_projection_clamps = q_projection_clamps + 1;
                    end else
                        q_now = (t64 - 64'd1) - q_shift;
                    q_wait = (q_busy_until > q_now) ? (q_busy_until - q_now) : 64'd0;
                    q_wait_sum   = q_wait_sum + q_wait;
                    q_waits_seen = q_waits_seen + q_wait;
                    if (ev_store) begin
                        q_busy_until = q_now + q_wait + SAVE64;
                        q_nstores    = q_nstores + 64'd1;
                    end
                end

                // ---------------- M2 ------------------------------------------
                if (m2_pred) begin
                    e_resolved = e_resolved + 1;
                    if (`D1_IF.prediction_hit_x) e_hit = e_hit + 1;
                    if (!`D1_BP.update_match) begin
                        e_relearn = e_relearn + 1;
                        if (!`D1_CPU.is_jal_x) e_relearn_nojal = e_relearn_nojal + 1;
                    end
                end
                if (m2_direrr) begin
                    e_direrr = e_direrr + 1;
                    if (!`D1_IF.prediction_hit_x)
                        e_miss = e_miss + 1;                      // BTB miss
                    else if (`D1_IF.prediction_taken_x)
                        e_wrong_nt = e_wrong_nt + 1;              // said taken
                    else
                        e_wrong_taken = e_wrong_taken + 1;        // said not-taken
                end
                // Only JALR: bp_resolve_valid also covers ordinary instructions.
                if (`D1_CPU.bp_resolve_valid && `D1_CPU.is_jalr_x)
                    e_jalr_unpred = e_jalr_unpred + 1;
            end
        end
    end

    initial begin
        wait (workload.test_pass);
        #2;
        if (m1_pending)
            $fatal(1, "D1 M1 pending after STOP: window closing invariant broken");
        frozen_resolved   = `D1_STAT.bp_stop_snapshot[3] - `D1_STAT.bp_start_snapshot[3];
        frozen_direrr     = `D1_STAT.bp_stop_snapshot[5] - `D1_STAT.bp_start_snapshot[5];
        frozen_write_wait = `D1_STAT.cycle_stop_snapshot[3] - `D1_STAT.cycle_start_snapshot[3];

        wf = $fopen($sformatf("build/d1_measure_%0s_window.csv", `COREMARK_PROFILE), "w");
        bf = $fopen($sformatf("build/d1_measure_%0s_buckets.csv", `COREMARK_PROFILE), "w");
        if (!wf || !bf) $fatal(1, "cannot open build/d1_measure_*.csv; create build/ first");

        $fwrite(wf, "key,value\n");
        $fwrite(wf, "profile,%0s\n", `COREMARK_PROFILE);
        $fwrite(wf, "start_t,%0d\nstop_t,%0d\nwindow_cycles,%0d\n", start_t, stop_t, stop_t - start_t);
        $fwrite(wf, "start_triggers,%0d\nstop_triggers,%0d\nepoch,%0d\ncrossings,%0d\n",
                start_triggers, stop_triggers, epoch, crossings);
        $fwrite(wf, "selected_start_triggers,%0d\n", selected_start_triggers);
        $fwrite(wf, "m1_cap,%0d\nm1_limit,%0d\n", M1_CAP, M1_LIMIT);
        $fwrite(wf, "m1_stores_window,%0d\nm1_censored_cap,%0d\nm1_truncated_window,%0d\n",
                m1_stores, m1_censored_cap, m1_truncated_window);
        // residual_sum = lower bound (complete observations only);
        // residual_trunc_sum = extra possible residual from window-censoring;
        // upper = lower + extra. CAP-censored observations add zero.
        $fwrite(wf, "m1_gap_sum,%0d\nm1_residual_sum,%0d\nm1_residual_trunc_sum,%0d\nm1_residual_upper_sum,%0d\n",
                m1_sum, m1_residual, m1_residual_trunc,
                m1_residual + m1_residual_trunc);
        $fwrite(wf, "queue_residual_sum,%0d\nqueue_projection_clamps,%0d\n",
                 q_wait_sum, q_projection_clamps);
        $fwrite(wf, "frozen_data_write_wait,%0d\n", frozen_write_wait);
        $fwrite(wf, "measured_direction_error,%0d\nfrozen_direction_error,%0d\n",
                e_direrr, frozen_direrr);
        $fwrite(wf, "frozen_resolved,%0d\n", frozen_resolved);
        $fwrite(wf, "e_resolved,%0d\ne_hit,%0d\ne_jalr_unpredictable,%0d\n",
                e_resolved, e_hit, e_jalr_unpred);
        $fclose(wf);

        $fwrite(bf, "key,count\n");
        for (k = 0; k <= M1_CAP; k = k + 1)
            $fwrite(bf, "m1_gap_%0d,%0d\n", k, m1_hist[k]);
        $fwrite(bf, "e_miss_taken,%0d\n",       e_miss);
        $fwrite(bf, "e_hit_wrong_taken,%0d\n",  e_wrong_taken);
        $fwrite(bf, "e_hit_wrong_nt,%0d\n",     e_wrong_nt);
        $fwrite(bf, "e_relearn,%0d\n",          e_relearn);
        $fwrite(bf, "e_relearn_nojal,%0d\n",    e_relearn_nojal);
        $fwrite(bf, "e_relearn_all,%0d\n",      e_relearn);
        $fclose(bf);

        // Explicit G4 amendment: preserve raw START=2; select latest epoch only.
        if (start_triggers != 2 || selected_start_triggers != 1 || epoch != 2 ||
            stop_triggers != 1 || crossings != 0 || window_live)
            $fatal(1, "D1 window lifecycle raw_start=%0d selected_start=%0d epoch=%0d stop=%0d crossings=%0d live=%0d",
                   start_triggers, selected_start_triggers, epoch,
                   stop_triggers, crossings, window_live);
        if (m1_stores == 0 || e_resolved == 0 || (stop_t <= start_t))
            $fatal(1, "D1 produced empty M1/M2 data");
        nsum = 0;
        for (k = 0; k <= M1_CAP; k = k + 1) nsum = nsum + m1_hist[k];
        if (nsum != m1_stores)
            $fatal(1, "D1 M1 bucket ledger %0d != stores %0d", nsum, m1_stores);
        if ((e_miss + e_wrong_taken + e_wrong_nt) != e_direrr)
            $fatal(1, "D1 M2 categories do not sum to direction errors");
        if (e_resolved !== frozen_resolved)
            $fatal(1, "D1 resolved reconciliation measured=%0d frozen=%0d",
                   e_resolved, frozen_resolved);
        if (e_direrr !== frozen_direrr)
            $fatal(1, "D1 direction-error reconciliation measured=%0d frozen=%0d",
                   e_direrr, frozen_direrr);

        $display("COREMARK D1 LIFECYCLE profile=%0s raw_start=%0d selected_start=%0d epoch=%0d stop=%0d crossings=%0d G4=revised_latest_start",
                 `COREMARK_PROFILE, start_triggers, selected_start_triggers,
                 epoch, stop_triggers, crossings);
        $display("COREMARK D1 PASS profile=%0s window=%0d stores=%0d cap_cens=%0d stop_cens=%0d",
                 `COREMARK_PROFILE, stop_t - start_t, m1_stores,
                 m1_censored_cap, m1_truncated_window);
        $display("COREMARK D1 M1 gap_sum=%0d residual_lower=%0d residual_upper=%0d queue=%0d frozen_write_wait=%0d",
                 m1_sum, m1_residual, m1_residual + m1_residual_trunc,
                 q_wait_sum, frozen_write_wait);
        $display("COREMARK D1 M2 resolved=%0d hit=%0d direrr=%0d miss=%0d wrong_nt=%0d wrong_taken=%0d relearn=%0d jalr_unpred=%0d",
                 e_resolved, e_hit, e_direrr, e_miss, e_wrong_nt,
                 e_wrong_taken, e_relearn_nojal, e_jalr_unpred);
        test_pass = 1;
        $stop;
    end
endmodule
