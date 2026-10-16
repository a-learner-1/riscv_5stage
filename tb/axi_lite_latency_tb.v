`timescale 1ns/1ps

// Public-channel latency contract, independent of the slave's internal FSM.
// Memory hierarchy is observed only to check actual access effects/counts.
module axi_lite_latency_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    wire done_0, done_1, done_3;
    reg test_pass = 0;

    axi_lite_latency_case #(.WAIT_CYCLES(0)) case_0 (.clk(clk), .done(done_0));
    axi_lite_latency_case #(.WAIT_CYCLES(1)) case_1 (.clk(clk), .done(done_1));
    axi_lite_latency_case #(.WAIT_CYCLES(3)) case_3 (.clk(clk), .done(done_3));

    initial begin
        wait (done_0 && done_1 && done_3);
        $display("AXI LATENCY TESTS PASS: zero-wait B/R one-cycle responses and preserved nonzero delays");
        test_pass = 1;
        #1;
        $stop;
    end

    initial begin
        #200000;
        $fatal(1, "AXI latency tests timed out");
    end
endmodule

module axi_lite_latency_case #(
    parameter integer WAIT_CYCLES = 0
) (
    input wire clk,
    output reg done
);
    localparam [31:0] BASE = 32'h00010000;
    // Last AW/W handshake -> BVALID; AR handshake -> RVALID.
    localparam integer EXPECTED_LATENCY = (WAIT_CYCLES == 0) ? 1 : WAIT_CYCLES + 2;
    reg rst_n = 0;
    reg [31:0] awaddr = 0, wdata = 0, araddr = 0;
    reg [3:0] wstrb = 0;
    reg awvalid = 0, wvalid = 0, arvalid = 0;
    reg bready = 0, rready = 0;
    wire awready, wready, arready, bvalid, rvalid;
    wire [1:0] bresp, rresp;
    wire [31:0] rdata;

    reg [31:0] expected_mem [0:15];
    integer cycle = 0, aw_cycle = -1, w_cycle = -1, ar_cycle = -1;
    integer paired_cycle;
    reg aw_seen = 0, w_seen = 0, ar_seen = 0;
    reg b_first_seen = 0, r_first_seen = 0;
    integer b_seen_count = 0, r_seen_count = 0;
    integer aw_count = 0, w_count = 0, ar_count = 0;
    integer b_count = 0, r_count = 0;
    integer expected_aw = 0, expected_w = 0, expected_ar = 0;
    integer expected_b = 0, expected_r = 0;
    integer memory_writes = 0, memory_reads = 0;
    integer expected_writes = 0, expected_reads = 0;
    reg b_held = 0, r_held = 0;
    reg [1:0] held_bresp = 0, held_rresp = 0;
    reg [31:0] held_rdata = 0;
    integer k;

    axi_lite_ram #(
        .WORDS(16), .BASE_ADDR(BASE), .INIT_FILE(""),
        .AW_WAIT_CYCLES(0), .W_WAIT_CYCLES(0), .AR_WAIT_CYCLES(0),
        .B_WAIT_CYCLES(WAIT_CYCLES), .R_WAIT_CYCLES(WAIT_CYCLES)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'b000),
        .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'b000),
        .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp),
        .s_axi_rvalid(rvalid), .s_axi_rready(rready)
    );

    // Record handshakes before NBA updates, then sample the newly registered
    // response after NBA updates. A response held for many cycles is measured
    // once; BREADY/RREADY never affect the measured first-VALID edge.
    always @(posedge clk) begin
        cycle = cycle + 1;
        if (!rst_n) begin
            aw_seen = 0; w_seen = 0; ar_seen = 0;
            aw_cycle = -1; w_cycle = -1; ar_cycle = -1;
            b_first_seen = 0; r_first_seen = 0;
            b_held = 0; r_held = 0;
        end else begin
            if (b_held && (!bvalid || bresp !== held_bresp))
                $fatal(1, "wait=%0d B response changed under backpressure", WAIT_CYCLES);
            if (r_held && (!rvalid || rresp !== held_rresp || rdata !== held_rdata))
                $fatal(1, "wait=%0d R response changed under backpressure", WAIT_CYCLES);
            b_held = bvalid && !bready;
            r_held = rvalid && !rready;
            if (b_held) held_bresp = bresp;
            if (r_held) begin held_rresp = rresp; held_rdata = rdata; end

            if (awvalid && awready) begin
                if (aw_seen) $fatal(1, "wait=%0d duplicate AW acceptance", WAIT_CYCLES);
                aw_seen = 1; aw_cycle = cycle; aw_count = aw_count + 1;
            end
            if (wvalid && wready) begin
                if (w_seen) $fatal(1, "wait=%0d duplicate W acceptance", WAIT_CYCLES);
                w_seen = 1; w_cycle = cycle; w_count = w_count + 1;
            end
            if (arvalid && arready) begin
                if (ar_seen) $fatal(1, "wait=%0d duplicate AR acceptance", WAIT_CYCLES);
                ar_seen = 1; ar_cycle = cycle; ar_count = ar_count + 1;
            end
            if (bvalid && bready) begin
                b_count = b_count + 1;
                aw_seen = 0; w_seen = 0; b_first_seen = 0;
            end
            if (rvalid && rready) begin
                r_count = r_count + 1;
                ar_seen = 0; r_first_seen = 0;
            end
            if (dut.u_data_mem.we) memory_writes = memory_writes + 1;
            if (dut.u_data_mem.re) memory_reads = memory_reads + 1;
            if (dut.u_data_mem.we && dut.u_data_mem.re)
                $fatal(1, "wait=%0d RAM shared port used twice", WAIT_CYCLES);

            #1;
            if (rst_n && bvalid && !b_first_seen) begin
                if (!aw_seen || !w_seen)
                    $fatal(1, "wait=%0d unsolicited or unpaired B response", WAIT_CYCLES);
                paired_cycle = (aw_cycle > w_cycle) ? aw_cycle : w_cycle;
                if (cycle - paired_cycle != EXPECTED_LATENCY)
                    $fatal(1, "wait=%0d B latency=%0d expected=%0d", WAIT_CYCLES,
                        cycle - paired_cycle, EXPECTED_LATENCY);
                b_first_seen = 1;
                b_seen_count = b_seen_count + 1;
            end
            if (rst_n && rvalid && !r_first_seen) begin
                if (!ar_seen)
                    $fatal(1, "wait=%0d unsolicited R response", WAIT_CYCLES);
                if (cycle - ar_cycle != EXPECTED_LATENCY)
                    $fatal(1, "wait=%0d R latency=%0d expected=%0d", WAIT_CYCLES,
                        cycle - ar_cycle, EXPECTED_LATENCY);
                r_first_seen = 1;
                r_seen_count = r_seen_count + 1;
            end
        end
    end

    task check_memory;
        integer slot;
        begin
            for (slot = 0; slot < 16; slot = slot + 1)
                if (dut.u_data_mem.mem[slot] !== expected_mem[slot])
                    $fatal(1, "wait=%0d memory[%0d]=%h expected=%h", WAIT_CYCLES,
                        slot, dut.u_data_mem.mem[slot], expected_mem[slot]);
        end
    endtask

    task apply_write;
        input [31:0] address, value;
        input [3:0] mask;
        integer slot, lane;
        begin
            slot = (address - BASE) >> 2;
            for (lane = 0; lane < 4; lane = lane + 1)
                if (mask[lane]) expected_mem[slot][lane*8 +: 8] = value[lane*8 +: 8];
            expected_writes = expected_writes + 1;
        end
    endtask

    task send_aw;
        input [31:0] address;
        reg accepted;
        begin
            @(negedge clk); awaddr = address; awvalid = 1; accepted = 0;
            while (!accepted) begin
                @(posedge clk);
                if (awready) begin accepted = 1; expected_aw = expected_aw + 1; end
            end
            @(negedge clk); awvalid = 0; awaddr = 32'hdeadcafe;
        end
    endtask

    task send_w;
        input [31:0] value;
        input [3:0] mask;
        reg accepted;
        begin
            @(negedge clk); wdata = value; wstrb = mask; wvalid = 1; accepted = 0;
            while (!accepted) begin
                @(posedge clk);
                if (wready) begin accepted = 1; expected_w = expected_w + 1; end
            end
            @(negedge clk); wvalid = 0; wdata = 32'hbad0bad0; wstrb = 0;
        end
    endtask

    task send_ar;
        input [31:0] address;
        reg accepted;
        begin
            @(negedge clk); araddr = address; arvalid = 1; accepted = 0;
            while (!accepted) begin
                @(posedge clk);
                if (arready) begin accepted = 1; expected_ar = expected_ar + 1; end
            end
            @(negedge clk); arvalid = 0; araddr = 32'hbad1bad1;
        end
    endtask

    task check_unpaired;
        input integer writes_before;
        begin
            repeat (3) begin
                @(posedge clk); #1;
                if (bvalid || memory_writes != writes_before)
                    $fatal(1, "wait=%0d unpaired write affected memory/response", WAIT_CYCLES);
                check_memory();
            end
        end
    endtask

    // order=0: same edge; order=1: AW first; order=2: W first.
    task issue_write;
        input [31:0] address, value;
        input [3:0] mask;
        input integer order;
        integer writes_before;
        begin
            writes_before = memory_writes;
            case (order)
                0: fork send_aw(address); send_w(value, mask); join
                1: begin send_aw(address); check_unpaired(writes_before); send_w(value, mask); end
                2: begin send_w(value, mask); check_unpaired(writes_before); send_aw(address); end
                default: $fatal(1, "Bad latency test write order");
            endcase
        end
    endtask

    task wait_b;
        input [1:0] response;
        begin
            while (!bvalid) @(negedge clk);
            if (bresp !== response)
                $fatal(1, "wait=%0d BRESP=%b expected=%b", WAIT_CYCLES, bresp, response);
        end
    endtask

    task wait_r;
        input [31:0] value;
        input [1:0] response;
        begin
            while (!rvalid) @(negedge clk);
            if (rresp !== response || rdata !== value)
                $fatal(1, "wait=%0d R data=%h/%h resp=%b/%b", WAIT_CYCLES,
                    rdata, value, rresp, response);
        end
    endtask

    task consume_b;
        input [1:0] response;
        begin
            wait_b(response);
            repeat (4) begin
                @(posedge clk); #1;
                if (!bvalid || bresp !== response || awready || wready)
                    $fatal(1, "wait=%0d B hold/busy check failed", WAIT_CYCLES);
            end
            @(negedge clk); bready = 1;
            @(posedge clk);
            if (!bvalid || bresp !== response)
                $fatal(1, "wait=%0d B handshake lost", WAIT_CYCLES);
            expected_b = expected_b + 1;
            @(negedge clk); bready = 0;
            if (bvalid) $fatal(1, "wait=%0d B repeated after handshake", WAIT_CYCLES);
        end
    endtask

    task consume_r;
        input [31:0] value;
        input [1:0] response;
        begin
            wait_r(value, response);
            repeat (4) begin
                @(posedge clk); #1;
                if (!rvalid || rresp !== response || rdata !== value || arready)
                    $fatal(1, "wait=%0d R hold/busy check failed", WAIT_CYCLES);
            end
            @(negedge clk); rready = 1;
            @(posedge clk);
            if (!rvalid || rresp !== response || rdata !== value)
                $fatal(1, "wait=%0d R handshake lost", WAIT_CYCLES);
            expected_r = expected_r + 1;
            @(negedge clk); rready = 0;
            if (rvalid) $fatal(1, "wait=%0d R repeated after handshake", WAIT_CYCLES);
        end
    endtask

    task write_good;
        input [31:0] address, value;
        input [3:0] mask;
        input integer order;
        integer writes_before;
        begin
            writes_before = memory_writes;
            issue_write(address, value, mask, order);
            apply_write(address, value, mask);
            consume_b(2'b00);
            if (memory_writes != writes_before + 1)
                $fatal(1, "wait=%0d write missing/repeated", WAIT_CYCLES);
            check_memory();
        end
    endtask

    task write_bad;
        input [31:0] address;
        input integer order;
        integer writes_before;
        begin
            writes_before = memory_writes;
            issue_write(address, 32'hffffffff, 4'hf, order);
            consume_b(2'b11);
            if (memory_writes != writes_before)
                $fatal(1, "wait=%0d invalid write reached RAM", WAIT_CYCLES);
            check_memory();
        end
    endtask

    task read_good;
        input [31:0] address;
        integer slot, reads_before;
        reg [31:0] value;
        begin
            slot = (address - BASE) >> 2;
            value = expected_mem[slot];
            reads_before = memory_reads;
            send_ar(address); expected_reads = expected_reads + 1;
            consume_r(value, 2'b00);
            if (memory_reads != reads_before + 1)
                $fatal(1, "wait=%0d read missing/repeated", WAIT_CYCLES);
            check_memory();
        end
    endtask

    task read_bad;
        input [31:0] address;
        integer reads_before;
        begin
            reads_before = memory_reads;
            send_ar(address);
            consume_r(32'd0, 2'b11);
            if (memory_reads != reads_before)
                $fatal(1, "wait=%0d invalid read reached RAM", WAIT_CYCLES);
            check_memory();
        end
    endtask

    task reset_endpoint;
        begin
            @(negedge clk);
            rst_n = 0; awvalid = 0; wvalid = 0; arvalid = 0; bready = 0; rready = 0;
            #1;
            if (awready || wready || arready || bvalid || rvalid)
                $fatal(1, "wait=%0d protocol output active in reset", WAIT_CYCLES);
            check_memory();
            repeat (3) @(negedge clk);
            rst_n = 1;
            repeat (2) begin
                @(posedge clk); #1;
                if (bvalid || rvalid)
                    $fatal(1, "wait=%0d old response survived reset", WAIT_CYCLES);
            end
            check_memory();
        end
    endtask

    initial begin
        done = 0;
        for (k = 0; k < 16; k = k + 1) expected_mem[k] = 0;
        repeat (4) @(negedge clk); rst_n = 1;
        #1; check_memory();

        write_good(BASE,     32'h11223344, 4'hf, 0);
        read_good(BASE);
        write_good(BASE + 4, 32'h55667788, 4'hf, 1);
        read_good(BASE + 4);
        write_good(BASE + 8, 32'h99aabbcc, 4'hf, 2);
        read_good(BASE + 8);
        write_good(BASE, 32'ha1b2c3d4, 4'b0101, 1);
        read_good(BASE);

        write_bad(BASE + 1, 0);
        write_bad(BASE - 4, 1);
        write_bad(BASE + 64, 2);
        read_bad(BASE + 2);
        read_bad(BASE - 4);
        read_bad(BASE + 64);

        // Capture a synchronous read, then change its backing word while R
        // remains stalled: the old response must retain its original data.
        write_good(BASE + 12, 32'h10203040, 4'hf, 0);
        send_ar(BASE + 12); expected_reads = expected_reads + 1;
        wait_r(32'h10203040, 2'b00);
        write_good(BASE + 12, 32'haabbccdd, 4'hf, 2);
        consume_r(32'h10203040, 2'b00);
        read_good(BASE + 12);

        // Reset a completed write whose B response is still stalled.
        issue_write(BASE + 16, 32'h88776655, 4'hf, 0);
        apply_write(BASE + 16, 32'h88776655, 4'hf);
        wait_b(2'b00);
        repeat (3) @(negedge clk);
        check_memory();
        reset_endpoint();
        read_good(BASE + 16);

        // Reset a held read response, then reread the retained RAM contents.
        send_ar(BASE + 16); expected_reads = expected_reads + 1;
        wait_r(32'h88776655, 2'b00);
        repeat (3) @(negedge clk);
        reset_endpoint();
        read_good(BASE + 16);
        write_good(BASE + 20, 32'hc001d00d, 4'hf, 2);
        read_good(BASE + 20);

        repeat (4) @(negedge clk);
        check_memory();
        if (aw_count != expected_aw || w_count != expected_w || ar_count != expected_ar ||
            b_count != expected_b || r_count != expected_r ||
            b_seen_count != expected_aw || r_seen_count != expected_ar ||
            memory_writes != expected_writes || memory_reads != expected_reads ||
            bvalid || rvalid)
            $fatal(1, "wait=%0d counts AW=%0d/%0d W=%0d/%0d AR=%0d/%0d B=%0d/%0d R=%0d/%0d Bfirst=%0d Rfirst=%0d writes=%0d/%0d reads=%0d/%0d",
                WAIT_CYCLES, aw_count, expected_aw, w_count, expected_w, ar_count, expected_ar,
                b_count, expected_b, r_count, expected_r, b_seen_count, r_seen_count,
                memory_writes, expected_writes, memory_reads, expected_reads);
        $display("AXI latency case PASS: wait=%0d B/R latency=%0d AW/W orders, effects, DECERR, stalls and reset", WAIT_CYCLES, EXPECTED_LATENCY);
        done = 1;
    end
endmodule
