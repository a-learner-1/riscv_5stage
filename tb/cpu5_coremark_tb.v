`timescale 1ns/1ps
`define SYSCORE_CASE dut.u_core.u_cached.u_cpu.g_alu.u_pipeline

// CPU5 CoreMark system self-check. Runs the four frozen (D0 backend x I/D
// cache) configurations in parallel on the schema4/profile2 CPU5 system top.
// Console bytes are taken from the CPU5 MMIO transmit edge and cross-checked
// against start-bit edges on the real uart_tx pin. The window, the ten
// exclusive cycle classes and every cache/BP delta are rebuilt by this testbench
// from the CPU5 event pins and live counters, then compared with the frozen
// statistics snapshots and with the firmware's own UART report.
module cpu5_coremark_tb #(parameter integer CASES = 4);
    wire [3:0] done;
    reg test_pass = 0;
    integer completed = 0;
    genvar i;
    generate
        for (i = 0; i < CASES; i = i + 1) begin : g_cases
            cpu5_coremark_case #(.CASE_ID(i)) u (done[i]);
            always @(posedge done[i]) completed = completed + 1;
        end
    endgenerate
    initial begin
        wait (completed == CASES);
        test_pass = 1;
        $display("CPU5 COREMARK SYSTEM PASS cases=%0d", CASES);
        $stop;
    end
    // Backstop only: each case owns a cycle watchdog.
    initial begin
        #200000000;
        $fatal(1, "CPU5 CoreMark global timeout done=%b", done);
    end
endmodule

module cpu5_coremark_case #(parameter integer CASE_ID = 0) (output reg done = 0);
    localparam integer D0 = CASE_ID / 2;
    localparam integer CACHE = ((CASE_ID % 2) == 0) ? 0 : 3;
    localparam integer CACHE_ENABLED = (CACHE == 3);
    localparam integer BTB_ENTRIES = 16;
    localparam integer BP_ENABLED = 1;
    localparam [31:0] BP_CONFIG = (BTB_ENTRIES << 16) | BP_ENABLED;
    localparam [31:0] CACHE_GEOMETRY = 32'h02040010;
    localparam [31:0] STATS_BASE = 32'h30000000;
    localparam [31:0] TOHOST_ADDR = 32'h00013ffc;
    localparam integer TOHOST_WORD = (TOHOST_ADDR - 32'h00010000) >> 2;
    localparam integer WATCHDOG_CYCLES = 8000000;
    localparam string BASE = "build/cpu5_s17_coremark/firmware";

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;  // 20 ns period: 50 MHz

    wire [63:0] cycle_count, instret_count;
    wire [9:0] events;
    wire trap, ifault, dfault;
    wire [31:0] trap_pc, trap_cause, trap_tval, pc_x, instr_x;
    wire uart_tx;
    wire [31:0] ia, ih, im, ir, ie, da, dh, dm, dr, de, dw, db;
    wire [31:0] bpl, bph, bpt, bpz, bpm, bpdir, bptgt;

    cpu5_stats_axi_lite_top #(
        .PROGRAM_FILE($sformatf("%s/case%0d/program.hex", BASE, CASE_ID)),
        .DATA_FILE($sformatf("%s/case%0d/program_data.hex", BASE, CASE_ID)),
        .IMEM_WORDS(8192), .DMEM_WORDS(4096), .DMEM_BASE_ADDR(32'h10000),
        .ENABLE_D0_BRAM(D0), .D0_REQ_WAIT_CYCLES(0), .D0_RSP_WAIT_CYCLES(0),
        .ENABLE_ICACHE(CACHE_ENABLED), .ICACHE_SETS(4), .ICACHE_LINE_WORDS(4),
        .ENABLE_DCACHE(CACHE_ENABLED), .DCACHE_SETS(4), .DCACHE_LINE_WORDS(4),
        .ENABLE_BRANCH_PRED(BP_ENABLED), .BTB_ENTRIES(BTB_ENTRIES),
        .BRANCH_RESOLVE_IN_ID(0), .ENABLE_FORWARDING(1),
        .UART_CLOCK_HZ(50000000), .UART_BAUD(5000000),
        .UART_RX_FIFO_DEPTH(16), .SIM_CONSOLE_ECHO(0)
    ) dut (
        .clk(clk), .rst_n(rst_n), .uart_rx(1'b1), .gpio_in(8'd0),
        .irq_external(1'b0), .irq_software(1'b0), .irq_timer(1'b0),
        .uart_tx(uart_tx), .gpio_out(), .gpio_oe(),
        .pc_x(pc_x), .instr_x(instr_x), .valid_x(), .wb_pc(), .wb_data(), .wb_rd(), .wb_we(),
        .retire_valid(),
        .cycle_count(cycle_count), .instret_count(instret_count), .perf_cycle_events(events),
        .imem_fault(ifault), .dmem_fault(dfault), .imem_fault_pc(),
        .trap_valid(trap), .trap_pc(trap_pc), .trap_cause(trap_cause), .trap_tval(trap_tval),
        .icache_access_count(ia), .icache_hit_count(ih), .icache_miss_count(im),
        .icache_refill_word_count(ir), .icache_error_count(ie),
        .dcache_access_count(da), .dcache_hit_count(dh), .dcache_miss_count(dm),
        .dcache_refill_word_count(dr), .dcache_error_count(de),
        .dcache_write_count(dw), .dcache_bypass_count(db),
        .bp_lookup_count(bpl), .bp_hit_count(bph), .bp_taken_count(bpt),
        .bp_resolved_count(bpz), .bp_mispredict_count(bpm),
        .bp_direction_error_count(bpdir), .bp_target_error_count(bptgt)
    );

    wire [31:0] ram[0:4095];
    genvar w;
    generate
        if (D0) begin : g_local
            for (w = 0; w < 4096; w = w + 1) begin : g_words
                assign ram[w] = dut.u_core.u_backend.g_d0.u_ram.u_data_mem.mem[w];
            end
        end else begin : g_axi
            for (w = 0; w < 4096; w = w + 1) begin : g_words
                assign ram[w] = dut.u_ram.u_data_mem.mem[w];
            end
        end
    endgenerate

    // Console transmit edge inside the CPU5 local MMIO endpoint.
    wire ep_tx_fire = dut.u_core.u_cached.u_cpu.g_machine.u_router.u_normal.u_endpoint.tx_fire;
    wire [7:0] ep_tx_byte =
        dut.u_core.u_cached.u_cpu.g_machine.u_router.u_normal.u_endpoint.wdata_q[7:0];

    integer cycle = 0, retired = 0, wb = 0, ones, total, j, number, index;
    integer raw_starts = 0, stops = 0, console_bytes = 0;
    integer tohost_requests = 0, tohost_responses = 0, watchdog_cycles = 0, tail = 0;
    integer fd_console, fd_summary;
    reg [63:0] gold[0:9], start_gold[0:9], stop_gold[0:9];
    reg [63:0] start_cycle = 0, stop_cycle = 0, start_instret = 0, stop_instret = 0;
    reg [63:0] last_retire_seq = 0;
    reg [63:0] snapshot_cycle_delta, snapshot_instret_delta, profile_sum;
    reg [63:0] profile_delta[0:9];
    reg [63:0] cycle_start_snap[0:9], cycle_stop_snap[0:9];
    reg [31:0] icache_start[0:4], icache_stop[0:4];
    reg [31:0] dcache_start[0:6], dcache_stop[0:6];
    reg [31:0] bp_start_snap[0:6], bp_stop_snap[0:6];
    reg [31:0] pending_tohost = 0;
    reg tohost_pending = 0, completion_seen = 0;
    integer tohost_completions = 0, tohost_retire_index = -1;
    integer tohost_complete_cycle = 0, tohost_retire_cycle = 0;
    reg [31:0] tohost_pc = 0, tohost_instr = 0;
    reg tohost_completed = 0, tohost_retired = 0;
    reg retire_seen = 0;
    string console = "";
    string expected;
    string directory;

    function automatic integer contains(input string whole, input string part);
        integer scan;
        begin
            contains = 0;
            for (scan = 0; scan + part.len() <= whole.len(); scan = scan + 1)
                if (whole.substr(scan, scan + part.len() - 1) == part) contains = 1;
        end
    endfunction

    task require_text(input string part);
        begin
            if (!contains(console, part))
                $fatal(1, "CPU5 CoreMark case%0d d0=%0d cache=%0d missing UART text: %s",
                       CASE_ID, D0, CACHE, part);
        end
    endtask

    task capture(input integer stop_bank);
        begin
            if (stop_bank) begin
                stop_cycle = cycle_count;
                stop_instret = instret_count;
                for (index = 0; index < 10; index = index + 1)
                    stop_gold[index] = gold[index];
            end else begin
                start_cycle = cycle_count;
                start_instret = instret_count;
                for (index = 0; index < 10; index = index + 1)
                    start_gold[index] = gold[index];
            end
        end
    endtask

    initial begin
        directory = $sformatf("%s/cases/case%0d", BASE, CASE_ID);
        fd_console = $fopen({directory, "/console.txt"}, "w");
        for (j = 0; j < 10; j = j + 1) begin
            gold[j] = 0;
            start_gold[j] = 0;
            stop_gold[j] = 0;
        end
        repeat (4) @(negedge clk);
        rst_n = 1;
    end

    // Byte level console record used by every text check.
    always @(posedge clk) if (rst_n && !done) begin
        if (ep_tx_fire) begin
            console = {console, string'(ep_tx_byte)};
            $fwrite(fd_console, "%c", ep_tx_byte);
            console_bytes = console_bytes + 1;
            // Periodic flush keeps the on-disk console usable as a progress
            // trace without paying a flush per byte.
            if (console_bytes % 64 == 0) $fflush(fd_console);
        end
    end

    // Real pin activity: decode the eight data bits of every UART frame and
    // compare the decoded stream with the MMIO transmit byte stream. The
    // transmitter holds one bit for exactly ten 50 MHz clocks (5 MBaud), so
    // data bit k is stable at detection + 14 + 10k and the stop bit at +94.
    integer tx_state = 0, tx_count = 0, tx_bit = 0, tx_bytes = 0;
    integer tx_mismatch = 0, tx_stop_errors = 0;
    reg [7:0] tx_shift = 8'd0;
    always @(posedge clk) if (rst_n && !done) begin
        if (tx_state == 0) begin
            if (uart_tx === 1'b0) begin
                tx_state = 1;
                tx_count = 0;
                tx_bit = 0;
            end
        end else begin
            tx_count = tx_count + 1;
            if (tx_bit < 8 && tx_count == 14 + 10 * tx_bit) begin
                tx_shift = {uart_tx, tx_shift[7:1]};  // LSB first
                tx_bit = tx_bit + 1;
            end
            if (tx_count == 94) begin
                if (uart_tx !== 1'b1) tx_stop_errors = tx_stop_errors + 1;
                if (tx_bytes < console.len()) begin
                    if (console.substr(tx_bytes, tx_bytes) != string'(tx_shift))
                        tx_mismatch = tx_mismatch + 1;
                end else begin
                    tx_mismatch = tx_mismatch + 1;
                end
                tx_bytes = tx_bytes + 1;
                tx_state = 0;
            end
        end
    end

    // Per-cycle structural and ownership checks.
    always @(posedge clk) if (rst_n && !done) begin
        cycle = cycle + 1;
        watchdog_cycles = watchdog_cycles + 1;
        if (watchdog_cycles > WATCHDOG_CYCLES)
            $fatal(1, "CPU5 CoreMark case%0d timeout pc=%h instr=%h retired=%0d",
                   CASE_ID, pc_x, instr_x, retired);
        if (cycle_count !== cycle - 1 || instret_count !== retired)
            $fatal(1, "CPU5 CoreMark case%0d independent cycle/instret counters", CASE_ID);
        if (trap || ifault || dfault)
            $fatal(1, "CPU5 CoreMark case%0d exception/fault pc=%h cause=%h tval=%h",
                   CASE_ID, trap_pc, trap_cause, trap_tval);
        ones = 0;
        total = 0;
        for (j = 0; j < 10; j = j + 1) begin
            if (events[j]) begin
                gold[j] = gold[j] + 1;
                ones = ones + 1;
            end
            total = total + gold[j];
        end
        if ((cycle == 1 && ones != 0) || (cycle > 1 && ones != 1) || total !== cycle_count)
            $fatal(1, "CPU5 CoreMark case%0d event one-hot/cycle alignment", CASE_ID);
        if (dut.stats_arvalid && dut.stats_arready) begin
            case (dut.stats_araddr - STATS_BASE)
                32'h00: begin raw_starts = raw_starts + 1; capture(0); end
                32'h04: begin stops = stops + 1; capture(1); end
                default: ;
            endcase
        end
        // Completion requires one full-word nonzero store to tohost, its own
        // successful owner completion, its own retirement and its own writeback.
        // A RAM word alone could be a stale image value, and a count-only check
        // would accept a run whose terminal store never retired.
        if (`SYSCORE_CASE.ram_req_fire &&
            dut.u_core.u_cached.u_cpu.core_dreq_write &&
            dut.u_core.u_cached.u_cpu.core_dreq_addr == TOHOST_ADDR) begin
            if (dut.u_core.u_cached.u_cpu.core_dreq_size !== 2'd2 ||
                dut.u_core.u_cached.u_cpu.core_dreq_wstrb !== 4'hf)
                $fatal(1, "CPU5 CoreMark case%0d tohost was not a full-word store", CASE_ID);
            if (dut.u_core.u_cached.u_cpu.core_dreq_wdata != 0) begin
                if (dut.u_core.u_cached.u_cpu.core_dreq_wdata !== 1 &&
                    dut.u_core.u_cached.u_cpu.core_dreq_wdata !== 2)
                    $fatal(1, "CPU5 CoreMark case%0d invalid nonzero tohost value", CASE_ID);
                if (tohost_pending || completion_seen)
                    $fatal(1, "CPU5 CoreMark case%0d repeated a terminal tohost store", CASE_ID);
                tohost_pending = 1;
                pending_tohost = dut.u_core.u_cached.u_cpu.core_dreq_wdata;
                tohost_requests = tohost_requests + 1;
                // The owner exposes the PC/instruction it accepted, so the
                // terminal store can be followed to its own retirement.
                tohost_pc = `SYSCORE_CASE.ram_req_pc;
                tohost_instr = `SYSCORE_CASE.ram_req_instr;
            end
        end
        // The owner presents its completion in the same cycle the pipeline
        // consumes it (retire), or in the stalled COMPLETE state; either way it
        // is the store's own completion and is recorded before the retire check
        // below runs in the same cycle.
        if (tohost_requests == 1 && !tohost_completed &&
            `SYSCORE_CASE.ram_completion_valid &&
            `SYSCORE_CASE.ram_completion_store &&
            `SYSCORE_CASE.ram_completion_addr == TOHOST_ADDR) begin
            if (`SYSCORE_CASE.ram_completion_error)
                $fatal(1, "CPU5 CoreMark case%0d tohost completion reported an error", CASE_ID);
            tohost_completed = 1;
            tohost_completions = tohost_completions + 1;
            tohost_complete_cycle = cycle;
        end
        if (tohost_pending && dut.u_core.u_cached.u_cpu.core_drsp_valid &&
            dut.u_core.u_cached.u_cpu.core_drsp_ready) begin
            if (dut.u_core.u_cached.u_cpu.core_drsp_error)
                $fatal(1, "CPU5 CoreMark case%0d tohost store response failed", CASE_ID);
            tohost_pending = 0;
            tohost_responses = tohost_responses + 1;
            completion_seen = 1;
        end
        if (watchdog_cycles % 500000 == 0)
            $display("CPU5 CoreMark case%0d progress cycle=%0d retired=%0d console=%0d",
                     CASE_ID, cycle, retired, console_bytes);
        if (`SYSCORE_CASE.wb_fire) begin
            if (wb >= retired)
                $fatal(1, "CPU5 CoreMark case%0d writeback without an older retirement", CASE_ID);
            wb = wb + 1;
        end
        if (`SYSCORE_CASE.retire_fire) begin
            if (retire_seen && !(`SYSCORE_CASE.exmem_q.seq > last_retire_seq))
                $fatal(1, "CPU5 CoreMark case%0d retirement order regressed", CASE_ID);
            if (!tohost_retired && tohost_requests == 1 &&
                `SYSCORE_CASE.exmem_q.pc == tohost_pc &&
                `SYSCORE_CASE.exmem_q.instr == tohost_instr) begin
                if (!tohost_completed)
                    $fatal(1, "CPU5 CoreMark case%0d tohost retired before its completion", CASE_ID);
                tohost_retired = 1;
                tohost_retire_index = retired;
                tohost_retire_cycle = cycle;
            end
            retire_seen = 1;
            last_retire_seq = `SYSCORE_CASE.exmem_q.seq;
            retired = retired + 1;
        end
    end

    // Final judgement runs once, two cycles after completion so that the last
    // retirement and writeback have both landed.
    initial begin
        wait (completion_seen === 1'b1);
        repeat (4) @(negedge clk);
        // Wait (bounded) for three real events that may still be in flight when
        // the completion store lands: the terminal store's own retirement, its
        // write-back, and the UART pin going idle (the busy flag drops at the
        // start of the stop bit, so the last frame can still be on the wire).
        for (index = 0; index < 2000 &&
             (!tohost_retired || wb < tohost_retire_index + 1 ||
              tx_state != 0 || uart_tx !== 1'b1); index = index + 1) @(negedge clk);
        if (tohost_requests != 1 || tohost_responses != 1 || pending_tohost !== 1)
            $fatal(1, "CPU5 CoreMark case%0d firmware reported FAIL tohost=2", CASE_ID);
        // The terminal store itself must complete once, retire once after that
        // completion, and receive its own writeback; counters alone are weak.
        if (!tohost_completed || !tohost_retired || tohost_completions != 1)
            $fatal(1, "CPU5 CoreMark case%0d terminal tohost store did not complete and retire (completed=%0b retired=%0b completions=%0d)",
                   CASE_ID, tohost_completed, tohost_retired, tohost_completions);
        if (tohost_retire_cycle < tohost_complete_cycle)
            $fatal(1, "CPU5 CoreMark case%0d terminal tohost retired before its completion", CASE_ID);
        if (wb < tohost_retire_index + 1)
            $fatal(1, "CPU5 CoreMark case%0d terminal tohost store was never written back", CASE_ID);
        if (ram[TOHOST_WORD] !== 1)
            $fatal(1, "CPU5 CoreMark case%0d physical tohost word is not the success value", CASE_ID);
        if (console_bytes == 0 || tx_bytes != console_bytes ||
            tx_mismatch != 0 || tx_stop_errors != 0)
            $fatal(1, "CPU5 CoreMark case%0d UART frame mismatch bytes=%0d frames=%0d data=%0d stop=%0d",
                   CASE_ID, console_bytes, tx_bytes, tx_mismatch, tx_stop_errors);
        if (raw_starts != 2 || stops != 1)
            $fatal(1, "CPU5 CoreMark case%0d statistics trigger closure starts=%0d stops=%0d",
                   CASE_ID, raw_starts, stops);
        // The write-back stage trails retirement by a bounded pipeline depth;
        // no write-back may ever be newer than a retirement.
        if (retired == 0 || wb > retired || retired - wb > 4)
            $fatal(1, "CPU5 CoreMark case%0d retire/writeback ledger retired=%0d wb=%0d",
                   CASE_ID, retired, wb);
        snapshot_cycle_delta = {dut.u_stats.stop_snapshot[1], dut.u_stats.stop_snapshot[0]} -
                               {dut.u_stats.start_snapshot[1], dut.u_stats.start_snapshot[0]};
        snapshot_instret_delta = {dut.u_stats.stop_snapshot[3], dut.u_stats.stop_snapshot[2]} -
                                 {dut.u_stats.start_snapshot[3], dut.u_stats.start_snapshot[2]};
        if (stop_cycle - start_cycle != snapshot_cycle_delta ||
            stop_instret - start_instret != snapshot_instret_delta ||
            snapshot_cycle_delta == 0 || snapshot_instret_delta == 0 ||
            snapshot_cycle_delta >= 64'h100000000)
            $fatal(1, "CPU5 CoreMark case%0d frozen window disagrees with live counters", CASE_ID);
        profile_sum = 0;
        for (number = 0; number < 10; number = number + 1) begin
            cycle_start_snap[number] = dut.u_stats.cycle_start_snapshot[number];
            cycle_stop_snap[number] = dut.u_stats.cycle_stop_snapshot[number];
            profile_delta[number] = cycle_stop_snap[number] - cycle_start_snap[number];
            if (profile_delta[number] != stop_gold[number] - start_gold[number])
                $fatal(1, "CPU5 CoreMark case%0d class %0d disagrees with the event ledger",
                       CASE_ID, number);
            if (profile_delta[number] > snapshot_cycle_delta)
                $fatal(1, "CPU5 CoreMark case%0d class %0d exceeds the window", CASE_ID, number);
            profile_sum = profile_sum + profile_delta[number];
        end
        if (profile_sum != snapshot_cycle_delta)
            $fatal(1, "CPU5 CoreMark case%0d ten exclusive classes do not partition the window",
                   CASE_ID);
        for (number = 0; number < 5; number = number + 1) begin
            icache_start[number] = dut.u_stats.start_snapshot[4 + number];
            icache_stop[number] = dut.u_stats.stop_snapshot[4 + number];
        end
        for (number = 0; number < 7; number = number + 1) begin
            dcache_start[number] = dut.u_stats.start_snapshot[9 + number];
            dcache_stop[number] = dut.u_stats.stop_snapshot[9 + number];
            bp_start_snap[number] = dut.u_stats.bp_start_snapshot[number];
            bp_stop_snap[number] = dut.u_stats.bp_stop_snapshot[number];
        end
        if (icache_stop[4] != icache_start[4] || dcache_stop[4] != dcache_start[4] ||
            ie != 0 || de != 0)
            $fatal(1, "CPU5 CoreMark case%0d cache error counter is nonzero", CASE_ID);
        if (CACHE_ENABLED) begin
            for (number = 0; number < 4; number = number + 1)
                if (icache_stop[number] == icache_start[number] ||
                    dcache_stop[number] == dcache_start[number])
                    $fatal(1, "CPU5 CoreMark case%0d enabled cache did not exercise field %0d",
                           CASE_ID, number);
        end else begin
            for (number = 0; number < 5; number = number + 1)
                if (icache_stop[number] != 0 || icache_start[number] != 0)
                    $fatal(1, "CPU5 CoreMark case%0d disabled I-Cache statistics bank nonzero",
                           CASE_ID);
            for (number = 0; number < 7; number = number + 1)
                if (dcache_stop[number] != 0 || dcache_start[number] != 0)
                    $fatal(1, "CPU5 CoreMark case%0d disabled D-Cache statistics bank nonzero",
                           CASE_ID);
        end
        for (number = 0; number < 4; number = number + 1)
            if (bp_stop_snap[number] == bp_start_snap[number])
                $fatal(1, "CPU5 CoreMark case%0d enabled BTB did not exercise field %0d",
                       CASE_ID, number);

        require_text("COREMARK platform=cpu5\n");
        require_text("COREMARK isa=rv32im\n");
        if (D0) require_text("COREMARK data_backend=bram\n");
        else require_text("COREMARK data_backend=axi\n");
        require_text($sformatf("COREMARK backend_id=%0d\n", D0));
        require_text($sformatf("COREMARK cache_enable=%0d\n", CACHE));
        require_text($sformatf("COREMARK cache_geometry=%0d\n", CACHE_GEOMETRY));
        require_text($sformatf("COREMARK branch_pred_enable=%0d\n", BP_ENABLED));
        require_text($sformatf("COREMARK btb_entries=%0d\n", BTB_ENTRIES));
        require_text($sformatf("COREMARK btb_config=%0d\n", BP_CONFIG));
        require_text("COREMARK stats_schema=4\n");
        require_text("COREMARK cycle_profile_schema=2\n");
        require_text("COREMARK counter_window=START-before-mtime;STOP-after-mtime;includes-boundary-overhead\n");
        require_text("COREMARK counter_valid=1\n");
        require_text($sformatf("COREMARK counter_cycles=%0d\n", snapshot_cycle_delta));
        require_text($sformatf("COREMARK counter_retired=%0d\n", snapshot_instret_delta));
        require_text("COREMARK cycle_profile_valid=1\n");
        for (number = 0; number < 10; number = number + 1) begin
            case (number)
                0: expected = "COREMARK cycle_work_other=";
                1: expected = "COREMARK cycle_ifetch_wait=";
                2: expected = "COREMARK cycle_data_read_wait=";
                3: expected = "COREMARK cycle_data_write_wait=";
                4: expected = "COREMARK cycle_local_mmio_wait=";
                5: expected = "COREMARK cycle_redirect_wait=";
                6: expected = "COREMARK cycle_mul_wait=";
                7: expected = "COREMARK cycle_div_wait=";
                8: expected = "COREMARK cycle_load_use_wait=";
                9: expected = "COREMARK cycle_id_hazard_wait=";
            endcase
            require_text({expected, $sformatf("%0d\n", profile_delta[number])});
        end
        require_text($sformatf("COREMARK cycle_profile_sum=%0d\n", profile_sum));
        for (number = 0; number < 5; number = number + 1) begin
            case (number)
                0: expected = "COREMARK icache_access=";
                1: expected = "COREMARK icache_hit=";
                2: expected = "COREMARK icache_miss=";
                3: expected = "COREMARK icache_refill_words=";
                4: expected = "COREMARK icache_errors=";
            endcase
            require_text({expected, $sformatf("%0d\n",
                                              icache_stop[number] - icache_start[number])});
        end
        for (number = 0; number < 7; number = number + 1) begin
            case (number)
                0: expected = "COREMARK dcache_access=";
                1: expected = "COREMARK dcache_hit=";
                2: expected = "COREMARK dcache_miss=";
                3: expected = "COREMARK dcache_refill_words=";
                4: expected = "COREMARK dcache_errors=";
                5: expected = "COREMARK dcache_write=";
                6: expected = "COREMARK dcache_bypass=";
            endcase
            require_text({expected, $sformatf("%0d\n",
                                              dcache_stop[number] - dcache_start[number])});
        end
        for (number = 0; number < 7; number = number + 1) begin
            case (number)
                0: expected = "COREMARK bp_lookup=";
                1: expected = "COREMARK bp_hit=";
                2: expected = "COREMARK bp_predicted_taken=";
                3: expected = "COREMARK bp_resolved=";
                4: expected = "COREMARK bp_next_pc_mismatch=";
                5: expected = "COREMARK bp_direction_error=";
                6: expected = "COREMARK bp_target_error=";
            endcase
            require_text({expected, $sformatf("%0d\n",
                                              bp_stop_snap[number] - bp_start_snap[number])});
        end
        require_text("COREMARK cache_state=fixed-iterations;no-explicit-flush\n");
        require_text("COREMARK predictor_state=fixed-iterations;no-explicit-reset\n");
        require_text("COREMARK iterations_requested=1\n");
        require_text("COREMARK iterations=1\n");
        require_text("COREMARK cpu_hz=50000000\n");
        require_text("COREMARK uart_baud=5000000\n");
        require_text("seedcrc          : 0xe9f5");
        require_text("[0]crclist       : 0xe714");
        require_text("[0]crcmatrix     : 0x1fd7");
        require_text("[0]crcstate      : 0x8e3a");
        // Upstream warns that a one-iteration run is too short for a score;
        // this platform accepts only the functional CRCs.
        require_text("ERROR! Must execute for at least 10 secs");
        require_text("NOTE: smoke timing is a functional observation; it is not a formal score.");
        require_text("COREMARK RESULT: SMOKE PASS");
        if (contains(console, "ERROR! list") || contains(console, "ERROR! matrix") ||
            contains(console, "ERROR! state") || contains(console, "ERROR:") ||
            contains(console, "Cannot validate operation") ||
            contains(console, "COREMARK RESULT: FORMAL") ||
            contains(console, "SMOKE FAIL"))
            $fatal(1, "CPU5 CoreMark case%0d console contained an error or a formal claim", CASE_ID);

        fd_summary = $fopen({directory, "/summary.json"}, "w");
        $fwrite(fd_summary, "{\"status\":\"PASS\",\"case\":%0d,\"d0\":%0d,\"cache\":%0d,", CASE_ID, D0, CACHE);
        $fwrite(fd_summary, "\"compute_cycles\":%0d,\"retired\":%0d,\"writebacks\":%0d,", cycle, retired, wb);
        $fwrite(fd_summary, "\"console_bytes\":%0d,\"uart_frames\":%0d,\"uart_data_mismatch\":%0d,\"uart_stop_errors\":%0d,",
                console_bytes, tx_bytes, tx_mismatch, tx_stop_errors);
        $fwrite(fd_summary, "\"raw_starts\":%0d,\"stops\":%0d,", raw_starts, stops);
        $fwrite(fd_summary, "\"tohost\":{\"requests\":%0d,\"responses\":%0d,\"completions\":%0d,\"retired\":%0d,\"retire_index\":%0d,\"writebacks\":%0d},",
                tohost_requests, tohost_responses, tohost_completions,
                tohost_retired, tohost_retire_index, wb);
        $fwrite(fd_summary, "\"window\":{\"start_cycle\":%0d,\"stop_cycle\":%0d,\"start_instret\":%0d,\"stop_instret\":%0d,",
                start_cycle, stop_cycle, start_instret, stop_instret);
        $fwrite(fd_summary, "\"snapshot_cycle_delta\":%0d,\"snapshot_instret_delta\":%0d},",
                snapshot_cycle_delta, snapshot_instret_delta);
        $fwrite(fd_summary, "\"profile\":{\"start\":[");
        for (number = 0; number < 10; number = number + 1)
            $fwrite(fd_summary, "%0d%s", start_gold[number], number == 9 ? "" : ",");
        $fwrite(fd_summary, "],\"stop\":[");
        for (number = 0; number < 10; number = number + 1)
            $fwrite(fd_summary, "%0d%s", stop_gold[number], number == 9 ? "" : ",");
        $fwrite(fd_summary, "],\"delta\":[");
        for (number = 0; number < 10; number = number + 1)
            $fwrite(fd_summary, "%0d%s", profile_delta[number], number == 9 ? "" : ",");
        $fwrite(fd_summary, "]},\"icache\":{\"start\":[");
        for (number = 0; number < 5; number = number + 1)
            $fwrite(fd_summary, "%0d%s", icache_start[number], number == 4 ? "" : ",");
        $fwrite(fd_summary, "],\"stop\":[");
        for (number = 0; number < 5; number = number + 1)
            $fwrite(fd_summary, "%0d%s", icache_stop[number], number == 4 ? "" : ",");
        $fwrite(fd_summary, "]},\"dcache\":{\"start\":[");
        for (number = 0; number < 7; number = number + 1)
            $fwrite(fd_summary, "%0d%s", dcache_start[number], number == 6 ? "" : ",");
        $fwrite(fd_summary, "],\"stop\":[");
        for (number = 0; number < 7; number = number + 1)
            $fwrite(fd_summary, "%0d%s", dcache_stop[number], number == 6 ? "" : ",");
        $fwrite(fd_summary, "]},\"bp\":{\"start\":[");
        for (number = 0; number < 7; number = number + 1)
            $fwrite(fd_summary, "%0d%s", bp_start_snap[number], number == 6 ? "" : ",");
        $fwrite(fd_summary, "],\"stop\":[");
        for (number = 0; number < 7; number = number + 1)
            $fwrite(fd_summary, "%0d%s", bp_stop_snap[number], number == 6 ? "" : ",");
        $fwrite(fd_summary, "]}}\n");
        $fclose(fd_summary);
        $fclose(fd_console);
        done = 1;
        $display("CPU5 COREMARK CASE PASS case=%0d d0=%0d cache=%0d cycles=%0d retired=%0d window=%0d",
                 CASE_ID, D0, CACHE, cycle, retired, snapshot_cycle_delta);
        $display("%s", console);
    end
endmodule

`undef SYSCORE_CASE
