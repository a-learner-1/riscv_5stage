`timescale 1ns/1ps
`include "tb/cpu5_coremark_harness.v"
`define CPU_CASE dut.u_core.u_cached.u_cpu
`define MEP_CASE dut.u_core.u_cached.u_cpu.g_machine.u_router.u_machine_endpoint
`define SYSCORE_CASE dut.u_core.u_cached.u_cpu.g_alu.u_pipeline

// CPU5 CoreMark system self-check. Runs the four frozen (D0 backend x I/D
// cache) configurations in parallel on the schema4/profile2 CPU5 system top.
// Console bytes are taken from the CPU5 MMIO transmit edge and cross-checked
// against start-bit edges on the real uart_tx pin. The window, the ten
// exclusive cycle classes and every cache/BP delta are rebuilt by this testbench
// from the CPU5 event pins and live counters, then compared with the frozen
// statistics snapshots and with the firmware's own UART report.
module cpu5_coremark_tb #(parameter integer CASES = 4, QUICK_PROBE = 0,
    parameter string FIRMWARE_BASE="build/cpu5_s18_coremark/firmware");
    wire [3:0] done;
    reg test_pass = 0;
    integer completed = 0;
    genvar i;
    generate
        for (i = 0; i < CASES; i = i + 1) begin : g_cases
            cpu5_coremark_case #(.CASE_ID(i), .QUICK_PROBE(QUICK_PROBE), .BASE(FIRMWARE_BASE)) u (done[i]);
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

module cpu5_coremark_case #(parameter integer CASE_ID = 0, QUICK_PROBE = 0,
    parameter string BASE="build/cpu5_s18_coremark/firmware") (output reg done = 0);
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

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;  // 20 ns period: 50 MHz

    wire [63:0] cycle_count, instret_count;
    wire [9:0] events;
    wire trap, ifault, dfault;
    wire [31:0] trap_pc, trap_cause, trap_tval, pc_x, instr_x;
    wire uart_tx;
    wire [31:0] ia, ih, im, ir, ie, da, dh, dm, dr, de, dw, db;
    wire [31:0] bpl, bph, bpt, bpz, bpm, bpdir, bptgt;

    reg fetch_enable = 1;
    cpu5_coremark_system_harness #(
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
        .fetch_enable(fetch_enable),
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

    wire ram_we;
    wire [31:0] ram[0:4095];
    genvar w;
    generate
        if (D0) begin : g_local
            assign ram_we = dut.u_core.u_backend.g_d0.u_ram.u_data_mem.we;
            for (w = 0; w < 4096; w = w + 1) begin : g_words
                assign ram[w] = dut.u_core.u_backend.g_d0.u_ram.u_data_mem.mem[w];
            end
        end else begin : g_axi
            assign ram_we = dut.u_ram.u_data_mem.we;
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
    string run_id="unbound";

    // All CSV observations are pre-edge values. Hex columns have no 0x prefix.
    // The independent WB slot contains the exact packet retired on an earlier
    // edge, so equal counters cannot hide a skipped/replayed/replaced packet.
    integer fd_edges, fd_retire, fd_terminal, fd_stats, fd_triggers, fd_timer;
    integer fd_native, fd_serial, fd_ram;
    integer ram_physical_writes = 0, native_ram_writes = 0;
    integer tohost_request_cycle = 0, tohost_response_cycle = 0, tohost_wb_cycle = 0;
    reg [63:0] tohost_seq = 0;
    reg tohost_written_back = 0;
    reg expected_wb_valid = 0;
    reg [63:0] expected_wb_seq;
    reg [31:0] expected_wb_pc, expected_wb_instr, expected_wb_value;
    reg [4:0] expected_wb_rd;
    reg expected_wb_writes;
    reg native_pending = 0;
    reg [63:0] native_seq;
    reg [31:0] native_pc, native_addr, native_wdata;
    reg [3:0] native_wstrb;
    reg [1:0] native_size;
    reg native_write;
    reg stats_pending = 0;
    reg [31:0] stats_offset;
    reg [63:0] gold_mtime = 0, timer_low_full = 0;
    reg [31:0] timer_high, timer_low;
    integer timer_phase = 0, timer_reads = 0, timer_pairs = 0;
    reg [63:0] timer_start_ticks = 0, timer_stop_ticks = 0, timer_assembled;
    integer gate_cycle = 0;
    wire pipeline_empty = !`CPU_CASE.ifid_valid_q &&
        !`SYSCORE_CASE.idex_valid_q && !`SYSCORE_CASE.exmem_valid_q &&
        !`SYSCORE_CASE.memwb_valid_q && !`SYSCORE_CASE.ram_owner_valid &&
        !`SYSCORE_CASE.m_owner_valid;
    wire drain_closed = pipeline_empty && !expected_wb_valid && !native_pending &&
        !stats_pending && !dut.u_core.u_cached.presented_q &&
        dut.u_core.u_cached.if_accepted_count == dut.u_core.u_cached.if_returned_count &&
        retired == wb;

    task terminal_event(input string event_name, input [31:0] value);
        $fwrite(fd_terminal, "%s,%0d,%h,%h,%h,%h,%h,0\n", event_name,
                cycle, tohost_seq, tohost_pc, tohost_instr, TOHOST_ADDR, value);
    endtask

    task trigger_event(input string kind);
        integer k;
        begin
            // AR is accepted while its unique native D owner is still active.
            if (!native_pending || !`SYSCORE_CASE.ram_owner_valid ||
                native_seq !== `SYSCORE_CASE.ram_owner_seq ||
                native_addr !== dut.stats_araddr || native_write ||
                `SYSCORE_CASE.ram_owner_killed)
                $fatal(1, "CPU5 CoreMark case%0d Stats trigger lost its native owner", CASE_ID);
            $fwrite(fd_triggers, "%s,%0d,%0d,%0d,%0d,%h,%h,%0d,%0d,%0d,%0d,%h,%0d,%h,%0d,%0d",
                kind, cycle, cycle_count, instret_count,
                `SYSCORE_CASE.ram_owner_valid, `SYSCORE_CASE.ram_owner_seq,
                native_addr, `SYSCORE_CASE.ram_owner_store,
                `SYSCORE_CASE.ram_owner_killed, `SYSCORE_CASE.ram_owner_state,
                `SYSCORE_CASE.m_owner_valid, `SYSCORE_CASE.m_owner_seq,
                `SYSCORE_CASE.m_owner_killed, `SYSCORE_CASE.m_owner_generation,
                `SYSCORE_CASE.g_m.u_owner.op_q, `SYSCORE_CASE.g_m.u_owner.state_q);
            for (k=0;k<10;k=k+1) $fwrite(fd_triggers, ",%0d", gold[k]);
            $fwrite(fd_triggers, ",%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                ia,ih,im,ir,ie,da,dh,dm,dr,de,dw,db,bpl,bph,bpt,bpz,bpm,bpdir,bptgt);
        end
    endtask

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
                icache_stop[0]=ia; icache_stop[1]=ih; icache_stop[2]=im;
                icache_stop[3]=ir; icache_stop[4]=ie;
                dcache_stop[0]=da; dcache_stop[1]=dh; dcache_stop[2]=dm;
                dcache_stop[3]=dr; dcache_stop[4]=de; dcache_stop[5]=dw; dcache_stop[6]=db;
                bp_stop_snap[0]=bpl; bp_stop_snap[1]=bph; bp_stop_snap[2]=bpt;
                bp_stop_snap[3]=bpz; bp_stop_snap[4]=bpm; bp_stop_snap[5]=bpdir; bp_stop_snap[6]=bptgt;
                stop_cycle = cycle_count;
                stop_instret = instret_count;
                for (index = 0; index < 10; index = index + 1)
                    stop_gold[index] = gold[index];
            end else begin
                icache_start[0]=ia; icache_start[1]=ih; icache_start[2]=im;
                icache_start[3]=ir; icache_start[4]=ie;
                dcache_start[0]=da; dcache_start[1]=dh; dcache_start[2]=dm;
                dcache_start[3]=dr; dcache_start[4]=de; dcache_start[5]=dw; dcache_start[6]=db;
                bp_start_snap[0]=bpl; bp_start_snap[1]=bph; bp_start_snap[2]=bpt;
                bp_start_snap[3]=bpz; bp_start_snap[4]=bpm; bp_start_snap[5]=bpdir; bp_start_snap[6]=bptgt;
                start_cycle = cycle_count;
                start_instret = instret_count;
                for (index = 0; index < 10; index = index + 1)
                    start_gold[index] = gold[index];
            end
        end
    endtask

    initial begin
        if ($value$plusargs("RUN_ID=%s", run_id)) begin end
        directory = "build/cpu5_s18_coremark/cases";
        if ($value$plusargs("RAW_BASE=%s", directory)) begin end
        directory = $sformatf("%s/case%0d", directory, CASE_ID);
        fd_console = $fopen({directory, "/console.txt"}, "w");
        fd_serial = $fopen({directory, "/uart_serial.txt"}, "w");
        fd_edges = $fopen({directory, "/edges.csv"}, "w");
        fd_retire = $fopen({directory, "/retire.csv"}, "w");
        fd_terminal = $fopen({directory, "/terminal.csv"}, "w");
        fd_stats = $fopen({directory, "/stats.csv"}, "w");
        fd_triggers = $fopen({directory, "/triggers.csv"}, "w");
        fd_timer = $fopen({directory, "/timer.csv"}, "w");
        fd_native = $fopen({directory, "/native.csv"}, "w");
        if (!fd_console || !fd_serial || !fd_edges || !fd_retire || !fd_terminal ||
            !fd_stats || !fd_triggers || !fd_timer || !fd_native)
            $fatal(1, "CPU5 CoreMark case%0d cannot open raw evidence directory %s", CASE_ID, directory);
        $fwrite(fd_edges, "cycle,count,instret,events,retire,wb\n");
        $fwrite(fd_retire, "event,cycle,seq,pc,instr,rd,value,writes\n");
        $fwrite(fd_terminal, "event,cycle,seq,pc,instr,addr,value,error\n");
        $fwrite(fd_stats, "event,cycle,offset,data,response\n");
        $fwrite(fd_triggers, "kind,cycle,count,instret,d_valid,d_seq,d_addr,d_write,d_killed,d_state,m_valid,m_seq,m_killed,m_gen,m_op,m_state,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,i_access,i_hit,i_miss,i_refill,i_error,d_access,d_hit,d_miss,d_refill,d_error,d_write_count,d_bypass,bp_lookup,bp_hit,bp_taken,bp_resolved,bp_mispredict,bp_direction,bp_target\n");
        $fwrite(fd_timer, "cycle,seq,offset,data,mtime,error\n");
        $fwrite(fd_native, "event,cycle,seq,pc,addr,wdata,wstrb,size,is_write,rdata,error\n");
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
                $fwrite(fd_serial, "%c", tx_shift);
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
        $fwrite(fd_edges, "%0d,%0d,%0d,%h,%0d,%0d\n", cycle,
            cycle_count, instret_count, events, `SYSCORE_CASE.retire_fire, `SYSCORE_CASE.wb_fire);
        if (ram_we) ram_physical_writes = ram_physical_writes + 1;
        // The timer model has its own state and advances once per shared clock.
        // Endpoint execution freezes the pre-edge read; later rsp latency does
        // not move the high/low/high sample to a different time.
        if (`MEP_CASE.mtime_value !== gold_mtime || `MEP_CASE.timer_write_fire)
            $fatal(1, "CPU5 CoreMark case%0d independent mtime model mismatch", CASE_ID);
        if (`MEP_CASE.endpoint_fire) begin
            if (`MEP_CASE.write_q || !`MEP_CASE.access_legal ||
                !native_pending || native_seq !== `SYSCORE_CASE.ram_owner_seq)
                $fatal(1, "CPU5 CoreMark case%0d illegal/unowned timer read", CASE_ID);
            if (`MEP_CASE.read_value !== (`MEP_CASE.addr_q==32'h20000044 ? gold_mtime[63:32] : gold_mtime[31:0]))
                $fatal(1, "CPU5 CoreMark case%0d timer read value mismatch", CASE_ID);
            $fwrite(fd_timer, "%0d,%h,%h,%h,%h,0\n", cycle, native_seq,
                `MEP_CASE.addr_q-32'h20000000, `MEP_CASE.read_value, gold_mtime);
            timer_reads = timer_reads + 1;
            case (timer_phase)
                0: begin
                    if (`MEP_CASE.addr_q !== 32'h20000044) $fatal(1,"timer must start with high");
                    timer_high=`MEP_CASE.read_value; timer_phase=1;
                end
                1: begin
                    if (`MEP_CASE.addr_q !== 32'h20000040) $fatal(1,"timer high must be followed by low");
                    timer_low=`MEP_CASE.read_value; timer_low_full=gold_mtime; timer_phase=2;
                end
                2: begin
                    if (`MEP_CASE.addr_q !== 32'h20000044) $fatal(1,"timer low must be followed by high");
                    if (timer_high==`MEP_CASE.read_value) begin
                        timer_assembled={timer_high,timer_low};
                        if (timer_assembled !== timer_low_full) $fatal(1,"timer high-low-high assembly");
                        if (timer_pairs==0) timer_start_ticks=timer_assembled;
                        else if (timer_pairs==1) timer_stop_ticks=timer_assembled;
                        else $fatal(1,"unexpected extra coherent timer sample");
                        timer_pairs=timer_pairs+1;
                    end
                    timer_phase=0;
                end
            endcase
        end
        gold_mtime = gold_mtime + 1;
        // Native D ledger is independent from the owner's stored descriptor.
        // Drain old rsp before accepting a same-edge load-turnover request.
        if (`SYSCORE_CASE.ram_rsp_fire) begin
            if (!native_pending || `SYSCORE_CASE.ram_rsp_seq !== native_seq ||
                `SYSCORE_CASE.ram_rsp_pc !== native_pc)
                $fatal(1,"CPU5 CoreMark case%0d native response owner mismatch",CASE_ID);
            $fwrite(fd_native,"rsp,%0d,%h,%h,%h,%h,%h,%0d,%0d,%h,%0d\n",cycle,
                native_seq,native_pc,native_addr,native_wdata,native_wstrb,native_size,native_write,
                `CPU_CASE.core_drsp_rdata,`CPU_CASE.core_drsp_error);
            if (tohost_pending) begin
                if (native_seq !== tohost_seq || `CPU_CASE.core_drsp_error)
                    $fatal(1,"CPU5 CoreMark case%0d terminal response owner/error",CASE_ID);
                tohost_pending=0; tohost_responses=tohost_responses+1;
                tohost_response_cycle=cycle; completion_seen=1;
                terminal_event("rsp", `CPU_CASE.core_drsp_rdata);
            end
            native_pending=0;
        end
        if (`SYSCORE_CASE.ram_req_fire) begin
            if (native_pending) $fatal(1,"CPU5 CoreMark case%0d overlapping native D requests",CASE_ID);
            native_pending=1; native_seq=`SYSCORE_CASE.ram_req_seq; native_pc=`SYSCORE_CASE.ram_req_pc;
            native_addr=`CPU_CASE.core_dreq_addr; native_wdata=`CPU_CASE.core_dreq_wdata;
            native_wstrb=`CPU_CASE.core_dreq_wstrb; native_size=`CPU_CASE.core_dreq_size;
            native_write=`CPU_CASE.core_dreq_write;
            $fwrite(fd_native,"req,%0d,%h,%h,%h,%h,%h,%0d,%0d,00000000,0\n",cycle,
                native_seq,native_pc,native_addr,native_wdata,native_wstrb,native_size,native_write);
            if (native_write && native_addr>=32'h10000 && native_addr<32'h14000)
                native_ram_writes=native_ram_writes+1;
            if (native_write && native_addr==TOHOST_ADDR && native_wdata!=0) begin
                if (native_size!==2 || native_wstrb!==15 ||
                    (native_wdata!==1 && native_wdata!==2) || tohost_requests!=0)
                    $fatal(1,"CPU5 CoreMark case%0d malformed/repeated terminal request",CASE_ID);
                tohost_pending=1; pending_tohost=native_wdata; tohost_requests=tohost_requests+1;
                tohost_seq=native_seq; tohost_pc=`SYSCORE_CASE.ram_req_pc;
                tohost_instr=`SYSCORE_CASE.ram_req_instr; tohost_request_cycle=cycle;
                terminal_event("req",native_wdata);
            end
        end
        if (dut.stats_rvalid && dut.stats_rready) begin
            if (!stats_pending || dut.stats_rresp!==0)
                $fatal(1,"CPU5 CoreMark case%0d unowned/error Stats response",CASE_ID);
            $fwrite(fd_stats,"rsp,%0d,%h,%h,%0d\n",cycle,stats_offset,dut.stats_rdata,dut.stats_rresp);
            stats_pending=0;
        end
        if (dut.stats_arvalid && dut.stats_arready) begin
            if (stats_pending) $fatal(1,"CPU5 CoreMark overlapping Stats reads");
            stats_pending=1; stats_offset=dut.stats_araddr-STATS_BASE;
            $fwrite(fd_stats,"req,%0d,%h,00000000,0\n",cycle,stats_offset);
            case (stats_offset)
                32'h00: begin raw_starts=raw_starts+1; capture(0); trigger_event("start"); end
                32'h04: begin stops=stops+1; capture(1); trigger_event("stop"); end
                default: ;
            endcase
        end
        if (`SYSCORE_CASE.ram_completion_valid && `SYSCORE_CASE.ram_completion_ready &&
            tohost_requests==1 && `SYSCORE_CASE.ram_completion_seq==tohost_seq) begin
            if (tohost_completed || `SYSCORE_CASE.ram_completion_killed ||
                `SYSCORE_CASE.ram_completion_error || !`SYSCORE_CASE.ram_completion_store ||
                `SYSCORE_CASE.ram_completion_addr!==TOHOST_ADDR ||
                `SYSCORE_CASE.ram_completion_pc!==tohost_pc ||
                `SYSCORE_CASE.ram_completion_instr!==tohost_instr)
                $fatal(1,"CPU5 CoreMark case%0d invalid terminal completion",CASE_ID);
            tohost_completed=1; tohost_completions=tohost_completions+1;
            tohost_complete_cycle=cycle; terminal_event("completion",`SYSCORE_CASE.ram_completion_data);
        end
        if (watchdog_cycles % 500000 == 0)
            $display("CPU5 CoreMark case%0d progress cycle=%0d retired=%0d console=%0d",CASE_ID,cycle,retired,console_bytes);
        if (`SYSCORE_CASE.wb_fire) begin
            if (!expected_wb_valid || `SYSCORE_CASE.memwb_q.seq!==expected_wb_seq ||
                `SYSCORE_CASE.memwb_q.pc!==expected_wb_pc || `SYSCORE_CASE.memwb_q.instr!==expected_wb_instr ||
                `SYSCORE_CASE.memwb_q.rd!==expected_wb_rd || `SYSCORE_CASE.memwb_q.result!==expected_wb_value ||
                `SYSCORE_CASE.memwb_q.writes_rd!==expected_wb_writes ||
                `SYSCORE_CASE.wb_we!==(expected_wb_writes && expected_wb_rd!=0))
                $fatal(1,"CPU5 CoreMark case%0d WB packet is not the prior retired packet",CASE_ID);
            $fwrite(fd_retire,"wb,%0d,%h,%h,%h,%0d,%h,%0d\n",cycle,expected_wb_seq,
                expected_wb_pc,expected_wb_instr,expected_wb_rd,expected_wb_value,expected_wb_writes);
            if (tohost_requests==1 && expected_wb_seq==tohost_seq) begin
                if (!tohost_retired || tohost_written_back || `SYSCORE_CASE.wb_we || expected_wb_writes)
                    $fatal(1,"CPU5 CoreMark invalid terminal WB");
                tohost_written_back=1; tohost_wb_cycle=cycle;
                terminal_event("wb",expected_wb_value);
            end
            expected_wb_valid=0; wb=wb+1;
        end
        if (`SYSCORE_CASE.retire_fire) begin
            if (expected_wb_valid || (retire_seen && !(`SYSCORE_CASE.exmem_q.seq>last_retire_seq)))
                $fatal(1,"CPU5 CoreMark case%0d retirement sequence/slot violation",CASE_ID);
            expected_wb_valid=1; expected_wb_seq=`SYSCORE_CASE.exmem_q.seq;
            expected_wb_pc=`SYSCORE_CASE.exmem_q.pc; expected_wb_instr=`SYSCORE_CASE.exmem_q.instr;
            expected_wb_rd=`SYSCORE_CASE.exmem_q.rd; expected_wb_value=`SYSCORE_CASE.mem_result_value;
            expected_wb_writes=`SYSCORE_CASE.exmem_q.writes_rd;
            $fwrite(fd_retire,"retire,%0d,%h,%h,%h,%0d,%h,%0d\n",cycle,expected_wb_seq,
                expected_wb_pc,expected_wb_instr,expected_wb_rd,expected_wb_value,expected_wb_writes);
            if (tohost_requests==1 && expected_wb_seq==tohost_seq) begin
                if (tohost_retired || !tohost_completed || !completion_seen ||
                    expected_wb_pc!==tohost_pc || expected_wb_instr!==tohost_instr ||
                    !`SYSCORE_CASE.exmem_q.is_store || `SYSCORE_CASE.exmem_q.mem_addr!==TOHOST_ADDR ||
                    `SYSCORE_CASE.exmem_q.mem_wdata!==pending_tohost || expected_wb_writes)
                    $fatal(1,"CPU5 CoreMark case%0d invalid terminal retirement",CASE_ID);
                tohost_retired=1; tohost_retire_index=retired; tohost_retire_cycle=cycle;
                terminal_event("retire",expected_wb_value);
            end
            retire_seen=1; last_retire_seq=expected_wb_seq; retired=retired+1;
        end
    end

    // Close only future IF presentations. Existing requests/responses and all
    // pipeline/owner/WB packets drain naturally before shared reset cancels the
    // final never-accepted frontend request. No product signal is forced.
    initial begin
        wait (tohost_requests == 1);
        @(negedge clk); fetch_enable=0; gate_cycle=cycle;
        for (tail=0;tail<2000 && (!completion_seen || !tohost_written_back ||
            !drain_closed || tx_state!=0 || uart_tx!==1'b1);tail=tail+1) @(negedge clk);
        if (!drain_closed || !tohost_written_back || !tohost_retired || !tohost_completed ||
            tohost_requests!=1 || tohost_responses!=1 || tohost_completions!=1 ||
            pending_tohost!==1 || ram[TOHOST_WORD]!==1)
            $fatal(1,"CPU5 CoreMark case%0d terminal/drain closure failed retired=%0d wb=%0d tail=%0d",CASE_ID,retired,wb,tail);
        if (tohost_response_cycle<tohost_request_cycle || tohost_complete_cycle<tohost_response_cycle ||
            tohost_retire_cycle<tohost_complete_cycle || tohost_wb_cycle<=tohost_retire_cycle)
            $fatal(1,"CPU5 CoreMark case%0d terminal stage ordering",CASE_ID);
        if (retired==0 || retired!=wb || expected_wb_valid || !pipeline_empty)
            $fatal(1,"CPU5 CoreMark case%0d exact retire/WB drain mismatch",CASE_ID);
        if (ram_physical_writes!=native_ram_writes)
            $fatal(1,"CPU5 CoreMark case%0d physical/native RAM write count mismatch",CASE_ID);
        if (timer_phase!=0 || timer_pairs!=2 || timer_reads<6 || timer_stop_ticks<=timer_start_ticks)
            $fatal(1,"CPU5 CoreMark case%0d coherent timer samples missing",CASE_ID);
        if ((!QUICK_PROBE && console_bytes==0) || tx_bytes!=console_bytes || tx_mismatch!=0 || tx_stop_errors!=0 ||
            tx_state!=0 || uart_tx!==1'b1)
            $fatal(1,"CPU5 CoreMark case%0d UART pin stream did not close",CASE_ID);
        if (raw_starts!=2 || stops!=1)
            $fatal(1,"CPU5 CoreMark case%0d Stats triggers did not close",CASE_ID);
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
            if (icache_start[number] !== dut.u_stats.start_snapshot[4 + number] ||
                icache_stop[number] !== dut.u_stats.stop_snapshot[4 + number])
                $fatal(1,"CPU5 CoreMark case%0d I-cache bank differs from AR live sample",CASE_ID);
        end
        for (number = 0; number < 7; number = number + 1) begin
            if (dcache_start[number] !== dut.u_stats.start_snapshot[9 + number] ||
                dcache_stop[number] !== dut.u_stats.stop_snapshot[9 + number] ||
                bp_start_snap[number] !== dut.u_stats.bp_start_snapshot[number] ||
                bp_stop_snap[number] !== dut.u_stats.bp_stop_snapshot[number])
                $fatal(1,"CPU5 CoreMark case%0d D-cache/BP bank differs from AR live sample",CASE_ID);
        end
        if (!QUICK_PROBE) begin
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

        end // Full CoreMark report checks; probe still uses every raw/owner monitor.

        fd_summary = $fopen({directory, "/summary.json"}, "w");
        $fwrite(fd_summary, "{\"status\":\"PASS\",\"case\":%0d,\"d0\":%0d,\"cache\":%0d,\"quick_probe\":%0d,\"run_id\":\"%s\",", CASE_ID, D0, CACHE, QUICK_PROBE, run_id);
        $fwrite(fd_summary, "\"compute_cycles\":%0d,\"retired\":%0d,\"writebacks\":%0d,", cycle, retired, wb);
        $fwrite(fd_summary, "\"console_bytes\":%0d,\"uart_frames\":%0d,\"uart_data_mismatch\":%0d,\"uart_stop_errors\":%0d,",
                console_bytes, tx_bytes, tx_mismatch, tx_stop_errors);
        $fwrite(fd_summary, "\"raw_starts\":%0d,\"stops\":%0d,", raw_starts, stops);
        $fwrite(fd_summary, "\"ram_physical_writes\":%0d,\"native_ram_writes\":%0d,",ram_physical_writes,native_ram_writes);
        $fwrite(fd_summary, "\"timer\":{\"reads\":%0d,\"pairs\":%0d,\"start_ticks\":%0d,\"stop_ticks\":%0d,\"raw_ticks\":%0d},",timer_reads,timer_pairs,timer_start_ticks,timer_stop_ticks,timer_stop_ticks-timer_start_ticks);
        $fwrite(fd_summary, "\"drain\":{\"gate_cycle\":%0d,\"tail_cycles\":%0d,\"pipeline_empty\":1,\"expected_wb_valid\":0,\"memwb_valid_at_stop\":0,",gate_cycle,tail);
        $fwrite(fd_summary, "\"if_accepted\":%0d,\"if_returned\":%0d,\"never_accepted_fetch_valid\":%0d,\"shared_reset_after_snapshot\":1},",dut.u_core.u_cached.if_accepted_count,dut.u_core.u_cached.if_returned_count,dut.u_core.u_cached.cpu_imem_req_valid);
        $fwrite(fd_summary, "\"tohost\":{\"requests\":%0d,\"responses\":%0d,\"completions\":%0d,\"retired\":%0d,\"retire_index\":%0d,\"writebacks\":%0d,",tohost_requests,tohost_responses,tohost_completions,tohost_retired,tohost_retire_index,wb);
        $fwrite(fd_summary, "\"seq\":\"%h\",\"pc\":\"%h\",\"instr\":\"%h\",\"addr\":\"%h\",\"value\":%0d,",tohost_seq,tohost_pc,tohost_instr,TOHOST_ADDR,pending_tohost);
        $fwrite(fd_summary, "\"request_cycle\":%0d,\"response_cycle\":%0d,\"completion_cycle\":%0d,\"retire_cycle\":%0d,\"wb_cycle\":%0d,\"wb_matched\":1,\"writes_we\":0},",tohost_request_cycle,tohost_response_cycle,tohost_complete_cycle,tohost_retire_cycle,tohost_wb_cycle);
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
        fd_ram=$fopen({directory,"/actual_ram.hex"},"w");
        if (!fd_ram) $fatal(1,"cannot open final RAM dump");
        for (number=0;number<4096;number=number+1) $fwrite(fd_ram,"%h\n",ram[number]);
        $fclose(fd_ram);
        $fclose(fd_console); $fclose(fd_serial); $fclose(fd_edges); $fclose(fd_retire);
        $fclose(fd_terminal); $fclose(fd_stats); $fclose(fd_triggers); $fclose(fd_timer); $fclose(fd_native);
        done = 1;
        // Cancel only never-accepted frontend presentation after all observations.
        rst_n = 0;
        $display("CPU5 COREMARK CASE PASS case=%0d d0=%0d cache=%0d cycles=%0d retired=%0d window=%0d",
                 CASE_ID, D0, CACHE, cycle, retired, snapshot_cycle_delta);
        $display("%s", console);
    end
endmodule

`undef SYSCORE_CASE
`undef CPU_CASE
`undef MEP_CASE
