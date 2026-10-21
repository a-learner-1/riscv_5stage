`timescale 1ns/1ps
`ifndef COREMARK_CONFIG
`define COREMARK_CONFIG "programs/coremark_axi_cache_off_smoke_config.vh"
`endif
`include `COREMARK_CONFIG

// Real-firmware self-check. Only fixed, one-iteration smoke fixtures are
// accepted; the cycle profile extends the frozen statistics contract.
module coremark_axi_tb;
    reg clk = 0, rst_n = 0, test_pass = 0;
    wire [31:0] pc_x, instr_x, wb_pc;
    wire retire_valid, trap_valid, imem_fault, dmem_fault;
    wire [63:0] cycle_count, instret_count;
    wire [31:0] i_access, i_hit, i_miss, i_refill, i_error;
    wire [31:0] d_access, d_hit, d_miss, d_refill, d_error, d_write, d_bypass;
    wire [31:0] bp_lookup, bp_hit, bp_taken, bp_resolved;
    wire [31:0] bp_next_pc_mismatch, bp_direction_error, bp_target_error;
    localparam integer CACHE_ENABLED = (`COREMARK_CACHE_FLAGS == 3);
    localparam integer BP_ENABLED = `COREMARK_ENABLE_BRANCH_PRED;
    localparam integer START_WORD = (`COREMARK_START_TICKS - 32'h10000) / 4;
    localparam integer STOP_WORD = (`COREMARK_STOP_TICKS - 32'h10000) / 4;
    localparam integer TOTAL_WORD = (`COREMARK_TOTAL_TICKS - 32'h10000) / 4;
    localparam integer FAILED_WORD = (`COREMARK_FAILED - 32'h10000) / 4;
    localparam integer ITER_WORD = (`COREMARK_ACTUAL_ITERATIONS - 32'h10000) / 4;
    localparam integer MODE_WORD = (`COREMARK_AXI_MODE_SEEN_ADDR - 32'h10000) / 4;
    localparam integer VALID_WORD = (`COREMARK_AXI_STATS_VALID_ADDR - 32'h10000) / 4;
    localparam integer PLATFORM_FAILED_WORD = (`COREMARK_AXI_PLATFORM_FAILED_ADDR - 32'h10000) / 4;
    localparam integer CYCLE_DELTA_WORD = (`COREMARK_AXI_CYCLE_DELTA_ADDR - 32'h10000) / 4;
    localparam integer INSTRET_DELTA_WORD = (`COREMARK_AXI_INSTRET_DELTA_ADDR - 32'h10000) / 4;
    localparam integer I_DELTA_WORD = (`COREMARK_AXI_ICACHE_DELTA_ADDR - 32'h10000) / 4;
    localparam integer D_DELTA_WORD = (`COREMARK_AXI_DCACHE_DELTA_ADDR - 32'h10000) / 4;
    localparam integer BP_MODE_WORD = (`COREMARK_AXI_BTB_MODE_SEEN_ADDR - 32'h10000) / 4;
    localparam integer BP_DELTA_WORD = (`COREMARK_AXI_BTB_DELTA_ADDR - 32'h10000) / 4;
    localparam integer PROFILE_VALID_WORD = (`COREMARK_AXI_CYCLE_PROFILE_VALID_ADDR - 32'h10000) / 4;
    localparam integer PROFILE_DELTA_WORD = (`COREMARK_AXI_CYCLE_PROFILE_DELTA_ADDR - 32'h10000) / 4;
    localparam integer PROFILE_SUM_WORD = (`COREMARK_AXI_CYCLE_PROFILE_SUM_ADDR - 32'h10000) / 4;

    integer watchdog_cycles = 0, timer_phase = 0, snapshots = 0;
    integer k;
    reg [31:0] high_first = 0;
    reg [63:0] low_sample = 0, observed_start = 0, observed_stop = 0;
    reg [63:0] start_retired = 0, stop_retired = 0;
    reg [63:0] stored_start, stored_stop, stored_total;
    reg [63:0] stored_cycle_delta, stored_instret_delta;
    reg [63:0] expected_cycle_delta, expected_instret_delta;
    reg [31:0] stored_i [0:4];
    reg [31:0] stored_d [0:6];
    reg [31:0] stored_bp [0:6];
    reg [63:0] stored_profile [0:5];
    reg [63:0] profile_sum, profile_start_sum, profile_stop_sum;
    reg [63:0] expected_profile;
    reg tohost_pending = 0, completion_seen = 0;
    reg [31:0] pending_result = 0, completed_result = 0;
    string console = "";
    string expected;

    soc_coremark_axi_top #(
        .PROGRAM_FILE(`COREMARK_ROM_FILE), .DATA_FILE(`COREMARK_RAM_FILE),
        .IMEM_WORDS(8192), .DMEM_WORDS(4096), .DMEM_BASE_ADDR(32'h10000),
        .ENABLE_ICACHE(CACHE_ENABLED), .ENABLE_DCACHE(CACHE_ENABLED),
        .ENABLE_M(`COREMARK_ENABLE_M), .ENABLE_BRANCH_PRED(BP_ENABLED), .BTB_ENTRIES(`COREMARK_BTB_ENTRIES),
        .UART_CLOCK_HZ(`COREMARK_CLOCK_HZ), .UART_BAUD(`COREMARK_UART_BAUD),
        .SIM_CONSOLE_ECHO(0)
    ) dut (
        .clk(clk), .rst_n(rst_n), .uart_rx(1'b1), .uart_tx(),
        .gpio_in(8'd0), .gpio_out(), .gpio_oe(),
        .pc_x(pc_x), .instr_x(instr_x), .valid_x(),
        .wb_pc(wb_pc), .wb_rd(), .wb_data(), .wb_we(),
        .retire_valid(retire_valid), .cycle_count(cycle_count), .instret_count(instret_count),
        .imem_fault(imem_fault), .imem_fault_pc(), .dmem_fault(dmem_fault),
        .trap_valid(trap_valid), .trap_pc(), .trap_cause(), .trap_tval(),
        .icache_access_count(i_access), .icache_hit_count(i_hit), .icache_miss_count(i_miss),
        .icache_refill_word_count(i_refill), .icache_error_count(i_error),
        .dcache_access_count(d_access), .dcache_hit_count(d_hit), .dcache_miss_count(d_miss),
        .dcache_refill_word_count(d_refill), .dcache_error_count(d_error),
        .dcache_write_count(d_write), .dcache_bypass_count(d_bypass),
        .bp_lookup_count(bp_lookup), .bp_hit_count(bp_hit), .bp_taken_count(bp_taken),
        .bp_resolved_count(bp_resolved), .bp_mispredict_count(bp_next_pc_mismatch),
        .bp_direction_error_count(bp_direction_error), .bp_target_error_count(bp_target_error)
    );
    always #(500000000.0 / `COREMARK_CLOCK_HZ) clk = ~clk;

    function automatic integer contains(input string whole, input string part);
        integer i;
        begin
            contains = 0;
            for (i = 0; i + part.len() <= whole.len(); i = i + 1)
                if (whole.substr(i, i + part.len() - 1) == part) contains = 1;
        end
    endfunction

    function automatic [63:0] ram_u64(input integer word_index);
        begin
            ram_u64 = {dut.u_ram.u_data_mem.mem[word_index + 1],
                       dut.u_ram.u_data_mem.mem[word_index]};
        end
    endfunction

    task require_text(input string part);
        begin
            if (!contains(console, part))
                $fatal(1, "AXI CoreMark %s flags=%0d missing UART text: %s",
                       `COREMARK_PROFILE, `COREMARK_CACHE_FLAGS, part);
        end
    endtask

    // Monitor accepted CPU transactions rather than polling a RAM tohost word.
    // Completion requires the corresponding successful store response. This
    // remains valid if a RAM word was stale or a Cache transaction is pending.
    always @(posedge clk) if (rst_n) begin
        if (dut.u_core.u_cpu.csr_mie !== 0 || dut.u_core.u_cpu.csr_mstatus[3] !== 0)
            $fatal(1, "AXI CoreMark unexpectedly enabled machine interrupts");

        if (dut.u_core.u_cpu.mem_req_fire && dut.u_core.u_cpu.mem_req_write &&
            dut.u_core.u_cpu.mem_addr_x == `COREMARK_TOHOST) begin
            if (dut.u_core.u_cpu.mem_size_x !== 2'd2 ||
                dut.u_core.u_cpu.mem_wstrb_x !== 4'hf)
                $fatal(1, "AXI CoreMark tohost was not a full word store");
            if (dut.u_core.u_cpu.mem_wdata_x != 0) begin
                if (dut.u_core.u_cpu.mem_wdata_x !== 1 && dut.u_core.u_cpu.mem_wdata_x !== 2)
                    $fatal(1, "AXI CoreMark invalid nonzero tohost value");
                if (tohost_pending || completion_seen)
                    $fatal(1, "AXI CoreMark repeated a terminal tohost store");
                tohost_pending = 1;
                pending_result = dut.u_core.u_cpu.mem_wdata_x;
            end
        end
        if (dut.u_core.u_cpu.mem_rsp_fire && tohost_pending) begin
            if (dut.u_core.u_cpu.mem_rsp_error)
                $fatal(1, "AXI CoreMark tohost store response failed");
            completion_seen = 1;
            completed_result = pending_result;
            tohost_pending = 0;
        end

        // Match stored 64-bit mtime values to real high/low/high CPU reads.
        if (dut.u_core.u_cpu.mem_req_fire && !dut.u_core.u_cpu.mem_req_write &&
            dut.u_core.u_cpu.timer_read_hit_x) begin
            if (timer_phase == 0) begin
                if (dut.u_core.u_cpu.mem_addr_x !== 32'h20000044)
                    $fatal(1, "AXI CoreMark timer snapshot did not begin with high word");
                high_first = dut.u_core.u_cpu.timer_mtime[63:32];
                timer_phase = 1;
            end else if (timer_phase == 1) begin
                if (dut.u_core.u_cpu.mem_addr_x !== 32'h20000040)
                    $fatal(1, "AXI CoreMark timer snapshot did not read low word second");
                low_sample = dut.u_core.u_cpu.timer_mtime;
                timer_phase = 2;
            end else begin
                if (dut.u_core.u_cpu.mem_addr_x !== 32'h20000044)
                    $fatal(1, "AXI CoreMark timer snapshot did not verify high word");
                if (high_first == dut.u_core.u_cpu.timer_mtime[63:32]) begin
                    if (snapshots == 0) begin
                        observed_start = low_sample;
                        start_retired = instret_count;
                    end else if (snapshots == 1) begin
                        observed_stop = low_sample;
                        stop_retired = instret_count;
                    end else $fatal(1, "Short AXI CoreMark performed unexpected calibration timing");
                    snapshots = snapshots + 1;
                end
                timer_phase = 0;
            end
        end
        #1;
        if (dut.u_core.u_cpu.mmio_putchar_valid)
            console = {console, string'(dut.u_core.u_cpu.mmio_putchar_data)};
        if (trap_valid || imem_fault || dmem_fault)
            $fatal(1, "AXI CoreMark CPU exception/fault pc=%h", pc_x);
    end

    initial begin
        if (`COREMARK_ITERATIONS != 1 || `COREMARK_FORMAL != 0 ||
            `COREMARK_CLOCK_HZ != 50000000 || `COREMARK_UART_BAUD != 5000000)
            $fatal(1, "AXI HDL accepts only 50 MHz / 5 MHz UART one-iteration smoke fixtures");
        if (`COREMARK_CACHE_FLAGS != 0 && `COREMARK_CACHE_FLAGS != 3)
            $fatal(1, "AXI CoreMark smoke must select Cache flags 0 or 3");
        if ((BP_ENABLED != 0 && BP_ENABLED != 1) ||
            (BP_ENABLED && !CACHE_ENABLED) || `COREMARK_BTB_ENTRIES != 64 ||
            `COREMARK_AXI_STATS_SCHEMA != 3 ||
            `COREMARK_AXI_CYCLE_PROFILE_SCHEMA != 1 ||
            `COREMARK_AXI_CYCLE_PROFILE_FIELDS != 6 ||
            `COREMARK_AXI_CYCLE_PROFILE_BITS != 64 ||
            `COREMARK_AXI_CYCLE_PROFILE_START_BANK != 32'h100 ||
            `COREMARK_AXI_CYCLE_PROFILE_STOP_BANK != 32'h140 ||
            `COREMARK_AXI_STATS_WINDOW_BYTES != 512 ||
            `COREMARK_AXI_BP_CONFIG != (32'h00400000 | BP_ENABLED))
            $fatal(1, "AXI CoreMark smoke requires schema 3, the six-field cycle profile and selected 64-entry BTB mode");
        repeat (3) @(negedge clk);
        rst_n = 1;
        while (!completion_seen) begin
            @(posedge clk);
            #2;
            watchdog_cycles = watchdog_cycles + 1;
            if (watchdog_cycles > 40000000)
                $fatal(1, "AXI CoreMark %s flags=%0d timeout pc=%h instr=%h",
                       `COREMARK_PROFILE, `COREMARK_CACHE_FLAGS, pc_x, instr_x);
        end
        @(negedge clk);
        if (completed_result !== 1)
            $fatal(1, "AXI CoreMark smoke returned FAIL tohost=2");
        if (snapshots != 2 || timer_phase != 0)
            $fatal(1, "AXI CoreMark missing complete start/stop mtime snapshots");
        // Every preceding store has completed. D Cache is write-through, so
        // backing RAM now contains the firmware's own report variables.
        stored_start = ram_u64(START_WORD);
        stored_stop = ram_u64(STOP_WORD);
        stored_total = ram_u64(TOTAL_WORD);
        if (stored_start !== observed_start || stored_stop !== observed_stop ||
            stored_total !== observed_stop - observed_start)
            $fatal(1, "AXI CoreMark stored mtime disagrees with real timer reads");
        if (observed_stop <= observed_start || stop_retired <= start_retired ||
            stored_total == 0 || stored_total >= cycle_count)
            $fatal(1, "AXI CoreMark timing did not isolate a nonempty algorithm interval");
        if (dut.u_ram.u_data_mem.mem[ITER_WORD] !== 1 ||
            dut.u_ram.u_data_mem.mem[FAILED_WORD] !== 0 ||
            dut.u_ram.u_data_mem.mem[PLATFORM_FAILED_WORD] !== 0 ||
            dut.u_ram.u_data_mem.mem[VALID_WORD] !== 1 ||
            dut.u_ram.u_data_mem.mem[PROFILE_VALID_WORD] !== 1 ||
            dut.u_ram.u_data_mem.mem[MODE_WORD] !== `COREMARK_CACHE_FLAGS ||
            dut.u_ram.u_data_mem.mem[BP_MODE_WORD] !== `COREMARK_AXI_BP_CONFIG)
            $fatal(1, "AXI CoreMark firmware iteration/platform/statistics validation failed");

        stored_cycle_delta = ram_u64(CYCLE_DELTA_WORD);
        stored_instret_delta = ram_u64(INSTRET_DELTA_WORD);
        expected_cycle_delta = {dut.u_stats.stop_snapshot[1], dut.u_stats.stop_snapshot[0]} -
                               {dut.u_stats.start_snapshot[1], dut.u_stats.start_snapshot[0]};
        expected_instret_delta = {dut.u_stats.stop_snapshot[3], dut.u_stats.stop_snapshot[2]} -
                                 {dut.u_stats.start_snapshot[3], dut.u_stats.start_snapshot[2]};
        if (stored_cycle_delta !== expected_cycle_delta ||
            stored_instret_delta !== expected_instret_delta ||
            stored_cycle_delta == 0 || stored_instret_delta == 0 ||
            stored_cycle_delta >= 64'h100000000 || stored_cycle_delta < stored_total ||
            stored_instret_delta >= instret_count)
            $fatal(1, "AXI CoreMark 64-bit counter difference/window mismatch");
        profile_sum = 0;
        profile_start_sum = 0;
        profile_stop_sum = 0;
        for (k = 0; k < 6; k = k + 1) begin
            stored_profile[k] = ram_u64(PROFILE_DELTA_WORD + k * 2);
            expected_profile = dut.u_stats.cycle_stop_snapshot[k] -
                               dut.u_stats.cycle_start_snapshot[k];
            if (stored_profile[k] !== expected_profile ||
                stored_profile[k] > stored_cycle_delta)
                $fatal(1, "AXI CoreMark cycle class %0d delta/bound mismatch", k);
            profile_sum = profile_sum + stored_profile[k];
            profile_start_sum = profile_start_sum + dut.u_stats.cycle_start_snapshot[k];
            profile_stop_sum = profile_stop_sum + dut.u_stats.cycle_stop_snapshot[k];
        end
        if (profile_sum !== stored_cycle_delta || ram_u64(PROFILE_SUM_WORD) !== profile_sum ||
            profile_start_sum !== {dut.u_stats.start_snapshot[1], dut.u_stats.start_snapshot[0]} ||
            profile_stop_sum !== {dut.u_stats.stop_snapshot[1], dut.u_stats.stop_snapshot[0]})
            $fatal(1, "AXI CoreMark six exclusive cycle classes do not partition the frozen window");
        for (k = 0; k < 5; k = k + 1) begin
            stored_i[k] = dut.u_ram.u_data_mem.mem[I_DELTA_WORD + k];
            if (stored_i[k] !== dut.u_stats.stop_snapshot[4 + k] - dut.u_stats.start_snapshot[4 + k])
                $fatal(1, "AXI CoreMark I Cache delta field %0d mismatch", k);
        end
        for (k = 0; k < 7; k = k + 1) begin
            stored_d[k] = dut.u_ram.u_data_mem.mem[D_DELTA_WORD + k];
            if (stored_d[k] !== dut.u_stats.stop_snapshot[9 + k] - dut.u_stats.start_snapshot[9 + k])
                $fatal(1, "AXI CoreMark D Cache delta field %0d mismatch", k);
        end
        for (k = 0; k < 7; k = k + 1) begin
            stored_bp[k] = dut.u_ram.u_data_mem.mem[BP_DELTA_WORD + k];
            if (stored_bp[k] !== dut.u_stats.bp_stop_snapshot[k] - dut.u_stats.bp_start_snapshot[k])
                $fatal(1, "AXI CoreMark branch predictor delta field %0d mismatch", k);
        end
        if (BP_ENABLED) begin
            if (stored_bp[0] == 0 || stored_bp[1] == 0 || stored_bp[2] == 0 || stored_bp[3] == 0)
                $fatal(1, "AXI CoreMark enabled BTB did not exercise lookup/hit/taken/resolution");
        end else begin
            // The statistics device must gate disabled BP banks even if some
            // internal diagnostic inputs continue changing without prediction.
            for (k = 0; k < 7; k = k + 1)
                if (stored_bp[k] !== 0 || dut.u_stats.bp_start_snapshot[k] !== 0 ||
                    dut.u_stats.bp_stop_snapshot[k] !== 0)
                    $fatal(1, "Disabled branch predictor statistics bank/delta is nonzero");
        end
        if (stored_i[4] !== 0 || stored_d[4] !== 0 || i_error !== 0 || d_error !== 0)
            $fatal(1, "AXI CoreMark Cache error counter is nonzero");
        if (CACHE_ENABLED) begin
            if (stored_i[0] == 0 || stored_i[1] == 0 || stored_i[2] == 0 || stored_i[3] == 0 ||
                stored_d[0] == 0 || stored_d[1] == 0 || stored_d[2] == 0 || stored_d[3] == 0)
                $fatal(1, "AXI CoreMark enabled Cache did not exercise access/hit/miss/refill");
        end else begin
            for (k = 0; k < 5; k = k + 1)
                if (stored_i[k] !== 0) $fatal(1, "Disabled I Cache reports an active delta");
            for (k = 0; k < 7; k = k + 1)
                if (stored_d[k] !== 0) $fatal(1, "Disabled D Cache reports an active delta");
            if ({i_access, i_hit, i_miss, i_refill, i_error,
                 d_access, d_hit, d_miss, d_refill, d_error, d_write, d_bypass} !== 384'd0)
                $fatal(1, "Disabled AXI Cache live counters are nonzero");
        end

        require_text("COREMARK RESULT: SMOKE PASS");
        require_text($sformatf("COREMARK platform=%s\n", `COREMARK_PLATFORM));
        require_text($sformatf("COREMARK cache_enable=%0d", `COREMARK_CACHE_FLAGS));
        require_text($sformatf("COREMARK branch_pred_enable=%0d\n", BP_ENABLED));
        require_text("COREMARK btb_entries=64\n");
        require_text($sformatf("COREMARK btb_config=%0d\n", `COREMARK_AXI_BP_CONFIG));
        require_text("COREMARK counter_valid=1");
        require_text($sformatf("COREMARK counter_cycles=%0d", stored_cycle_delta));
        require_text($sformatf("COREMARK counter_retired=%0d", stored_instret_delta));
        require_text("COREMARK cycle_profile_schema=1\n");
        require_text("COREMARK cycle_profile_valid=1\n");
        require_text($sformatf("COREMARK cycle_profile_sum=%0d\n", profile_sum));
        for (k = 0; k < 6; k = k + 1) begin
            case (k)
                0: expected = $sformatf("COREMARK cycle_work_other=%0d\n", stored_profile[k]);
                1: expected = $sformatf("COREMARK cycle_ifetch_wait=%0d\n", stored_profile[k]);
                2: expected = $sformatf("COREMARK cycle_data_read_wait=%0d\n", stored_profile[k]);
                3: expected = $sformatf("COREMARK cycle_data_write_wait=%0d\n", stored_profile[k]);
                4: expected = $sformatf("COREMARK cycle_local_mmio_wait=%0d\n", stored_profile[k]);
                5: expected = $sformatf("COREMARK cycle_redirect_wait=%0d\n", stored_profile[k]);
            endcase
            require_text(expected);
        end
        require_text($sformatf("COREMARK raw_ticks=%0d", stored_total));
        require_text("COREMARK cpu_hz=50000000");
        require_text("COREMARK uart_baud=5000000");
        require_text($sformatf("seedcrc          : 0x%04x", `COREMARK_SEED_CRC));
        require_text($sformatf("[0]crclist       : 0x%04x", `COREMARK_LIST_CRC));
        require_text($sformatf("[0]crcmatrix     : 0x%04x", `COREMARK_MATRIX_CRC));
        require_text($sformatf("[0]crcstate      : 0x%04x", `COREMARK_STATE_CRC));
        for (k = 0; k < 5; k = k + 1) begin
            case (k)
                0: expected = $sformatf("COREMARK icache_access=%0d", stored_i[k]);
                1: expected = $sformatf("COREMARK icache_hit=%0d", stored_i[k]);
                2: expected = $sformatf("COREMARK icache_miss=%0d", stored_i[k]);
                3: expected = $sformatf("COREMARK icache_refill_words=%0d", stored_i[k]);
                4: expected = $sformatf("COREMARK icache_errors=%0d", stored_i[k]);
            endcase
            require_text(expected);
        end
        for (k = 0; k < 7; k = k + 1) begin
            case (k)
                0: expected = $sformatf("COREMARK dcache_access=%0d", stored_d[k]);
                1: expected = $sformatf("COREMARK dcache_hit=%0d", stored_d[k]);
                2: expected = $sformatf("COREMARK dcache_miss=%0d", stored_d[k]);
                3: expected = $sformatf("COREMARK dcache_refill_words=%0d", stored_d[k]);
                4: expected = $sformatf("COREMARK dcache_errors=%0d", stored_d[k]);
                5: expected = $sformatf("COREMARK dcache_write=%0d", stored_d[k]);
                6: expected = $sformatf("COREMARK dcache_bypass=%0d", stored_d[k]);
            endcase
            require_text(expected);
        end
        for (k = 0; k < 7; k = k + 1) begin
            case (k)
                0: expected = $sformatf("COREMARK bp_lookup=%0d\n", stored_bp[k]);
                1: expected = $sformatf("COREMARK bp_hit=%0d\n", stored_bp[k]);
                2: expected = $sformatf("COREMARK bp_predicted_taken=%0d\n", stored_bp[k]);
                3: expected = $sformatf("COREMARK bp_resolved=%0d\n", stored_bp[k]);
                // Next-PC recovery counts include ordinary instructions after
                // stale predictions. They are not a branch miss-rate numerator.
                4: expected = $sformatf("COREMARK bp_next_pc_mismatch=%0d\n", stored_bp[k]);
                5: expected = $sformatf("COREMARK bp_direction_error=%0d\n", stored_bp[k]);
                6: expected = $sformatf("COREMARK bp_target_error=%0d\n", stored_bp[k]);
            endcase
            require_text(expected);
        end
        // Upstream explicitly warns that a one-iteration smoke run is too
        // short for a formal score; the reused port accepts only its CRCs.
        require_text("ERROR! Must execute for at least 10 secs");
        require_text("NOTE: smoke timing is a functional observation; it is not a formal score.");
        if (contains(console, "ERROR! list") || contains(console, "ERROR! matrix") ||
            contains(console, "ERROR! state") || contains(console, "ERROR:") ||
            contains(console, "Cannot validate operation") ||
            contains(console, "COREMARK RESULT: FORMAL"))
            $fatal(1, "AXI CoreMark smoke UART contained an error or a formal score claim");
        $display("%s", console);
        $display("PASS: AXI CoreMark %s flags=%0d BP=%0d real C CRCs, successful CPU tohost, mtime and frozen I/D/BP statistics",
                 `COREMARK_PROFILE, `COREMARK_CACHE_FLAGS, BP_ENABLED);
        $display("PASS: AXI CoreMark cycle profile six 64-bit classes exactly partition the frozen cycle window and UART/RAM deltas");
        test_pass = 1;
        $stop;
    end
endmodule
