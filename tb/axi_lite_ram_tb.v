`timescale 1ns/1ps

// Exercise the real AXI RAM endpoint without the CPU bridge. The manual
// manager sends AW and W independently and checks actual RAM effects.
module axi_lite_ram_tb;
    localparam [31:0] BASE = 32'h00010000;
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    reg [31:0] awaddr = 0, wdata = 0, araddr = 0;
    reg [3:0] wstrb = 0;
    reg awvalid = 0, wvalid = 0, arvalid = 0;
    reg bready = 0, rready = 0;
    wire awready, wready, arready, bvalid, rvalid;
    wire [1:0] bresp, rresp;
    wire [31:0] rdata;
    reg test_pass = 0;

    reg [31:0] expected_mem [0:15];
    integer aw_count = 0, w_count = 0, ar_count = 0;
    integer b_count = 0, r_count = 0;
    integer ram_write_edges = 0, ram_read_edges = 0;
    integer expected_aw = 0, expected_w = 0, expected_ar = 0;
    integer expected_b = 0, expected_r = 0;
    integer expected_writes = 0, expected_reads = 0;
    integer contention_blocks = 0;
    reg b_held = 0, r_held = 0;
    reg [1:0] bresp_held = 0, rresp_held = 0;
    reg [31:0] rdata_held = 0;
    integer k, before_write;
    reg [31:0] snapshot;

    axi_lite_ram #(
        .WORDS(16), .BASE_ADDR(BASE), .INIT_FILE(""),
        .AW_WAIT_CYCLES(0), .W_WAIT_CYCLES(0), .AR_WAIT_CYCLES(0),
        .B_WAIT_CYCLES(0), .R_WAIT_CYCLES(0)
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

    // Count real handshakes and RAM enables, including canceled exchanges.
    // Counts survive reset; only protocol hold checks reset with the slave.
    always @(posedge clk) begin
        if (!rst_n) begin
            b_held = 0;
            r_held = 0;
        end else begin
            if (b_held && (!bvalid || bresp !== bresp_held))
                $fatal(1, "AXI RAM B response changed under backpressure");
            if (r_held && (!rvalid || rresp !== rresp_held || rdata !== rdata_held))
                $fatal(1, "AXI RAM R response changed under backpressure");
            b_held = bvalid && !bready;
            r_held = rvalid && !rready;
            if (b_held) bresp_held = bresp;
            if (r_held) begin rresp_held = rresp; rdata_held = rdata; end
            if (awvalid && awready) aw_count = aw_count + 1;
            if (wvalid && wready) w_count = w_count + 1;
            if (arvalid && arready) ar_count = ar_count + 1;
            if (bvalid && bready) b_count = b_count + 1;
            if (rvalid && rready) r_count = r_count + 1;
            if (dut.u_data_mem.we) ram_write_edges = ram_write_edges + 1;
            if (dut.u_data_mem.re) ram_read_edges = ram_read_edges + 1;
            if (dut.u_data_mem.we && dut.u_data_mem.re)
                $fatal(1, "AXI RAM used its shared memory port twice");
            if (arvalid && !arready && dut.u_data_mem.we)
                contention_blocks = contention_blocks + 1;
        end
    end

    task check_memory;
        integer word_index;
        begin
            for (word_index = 0; word_index < 16; word_index = word_index + 1)
                if (dut.u_data_mem.mem[word_index] !== expected_mem[word_index])
                    $fatal(1, "AXI RAM contents differ word=%0d got=%h expected=%h",
                        word_index, dut.u_data_mem.mem[word_index], expected_mem[word_index]);
        end
    endtask

    task apply_expected_write;
        input [31:0] address, value;
        input [3:0] mask;
        integer slot, lane;
        begin
            slot = (address - BASE) >> 2;
            for (lane = 0; lane < 4; lane = lane + 1)
                if (mask[lane]) expected_mem[slot][lane*8 +: 8] = value[lane*8 +: 8];
            // A valid zero-mask transaction still has one RAM write enable,
            // but no byte changes. The content scoreboard checks the no-op.
            expected_writes = expected_writes + 1;
        end
    endtask

    task send_aw;
        input [31:0] address;
        reg accepted;
        begin
            @(negedge clk); awaddr = address; awvalid = 1;
            accepted = 0;
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
            @(negedge clk); wdata = value; wstrb = mask; wvalid = 1;
            accepted = 0;
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
            @(negedge clk); araddr = address; arvalid = 1;
            accepted = 0;
            while (!accepted) begin
                @(posedge clk);
                if (arready) begin accepted = 1; expected_ar = expected_ar + 1; end
            end
            @(negedge clk); arvalid = 0; araddr = 32'hbad1bad1;
        end
    endtask

    task wait_b;
        input [1:0] response;
        begin
            while (!bvalid) @(negedge clk);
            if (bresp !== response)
                $fatal(1, "AXI RAM BRESP got=%b expected=%b", bresp, response);
        end
    endtask

    task wait_r;
        input [31:0] value;
        input [1:0] response;
        begin
            while (!rvalid) @(negedge clk);
            if (rresp !== response || rdata !== value)
                $fatal(1, "AXI RAM R response data=%h/%h resp=%b/%b", rdata, value, rresp, response);
        end
    endtask

    task consume_b;
        input [1:0] response;
        input integer held_cycles;
        begin
            wait_b(response);
            repeat (held_cycles) begin
                @(posedge clk); #1;
                if (!bvalid || bresp !== response || awready || wready)
                    $fatal(1, "AXI RAM write response/backpressure did not hold");
            end
            @(negedge clk); bready = 1;
            @(posedge clk);
            if (!bvalid || bresp !== response) $fatal(1, "AXI RAM B handshake lost");
            expected_b = expected_b + 1;
            @(negedge clk); bready = 0;
            if (bvalid) $fatal(1, "AXI RAM B response repeated after handshake");
        end
    endtask

    task consume_r;
        input [31:0] value;
        input [1:0] response;
        input integer held_cycles;
        begin
            wait_r(value, response);
            repeat (held_cycles) begin
                @(posedge clk); #1;
                if (!rvalid || rresp !== response || rdata !== value || arready)
                    $fatal(1, "AXI RAM read response/backpressure did not hold");
            end
            @(negedge clk); rready = 1;
            @(posedge clk);
            if (!rvalid || rresp !== response || rdata !== value)
                $fatal(1, "AXI RAM R handshake lost");
            expected_r = expected_r + 1;
            @(negedge clk); rready = 0;
            if (rvalid) $fatal(1, "AXI RAM R response repeated after handshake");
        end
    endtask

    task check_unpaired;
        input integer write_count_before;
        begin
            repeat (3) begin
                @(posedge clk); #1;
                if (bvalid || ram_write_edges != write_count_before)
                    $fatal(1, "AXI RAM wrote or responded before both AW and W");
                check_memory();
            end
        end
    endtask

    // order=0: same edge; order=1: AW first; order=2: W first.
    task write_good;
        input [31:0] address, value;
        input [3:0] mask;
        input integer order;
        integer writes_before;
        begin
            writes_before = ram_write_edges;
            case (order)
                0: fork send_aw(address); send_w(value, mask); join
                1: begin send_aw(address); check_unpaired(writes_before); send_w(value, mask); end
                2: begin send_w(value, mask); check_unpaired(writes_before); send_aw(address); end
                default: $fatal(1, "Bad test write order");
            endcase
            apply_expected_write(address, value, mask);
            consume_b(2'b00, 3);
            if (ram_write_edges != writes_before + 1)
                $fatal(1, "AXI RAM write was missing or repeated");
            check_memory();
        end
    endtask

    task write_bad;
        input [31:0] address;
        input integer order;
        integer writes_before;
        begin
            writes_before = ram_write_edges;
            case (order)
                0: fork send_aw(address); send_w(32'hffffffff, 4'hf); join
                1: begin send_aw(address); send_w(32'hffffffff, 4'hf); end
                2: begin send_w(32'hffffffff, 4'hf); send_aw(address); end
                default: $fatal(1, "Bad test error order");
            endcase
            consume_b(2'b11, 3);
            if (ram_write_edges != writes_before)
                $fatal(1, "AXI RAM invalid write reached memory");
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
            reads_before = ram_read_edges;
            send_ar(address); expected_reads = expected_reads + 1;
            consume_r(value, 2'b00, 3);
            if (ram_read_edges != reads_before + 1)
                $fatal(1, "AXI RAM read was missing or repeated");
            check_memory();
        end
    endtask

    task read_bad;
        input [31:0] address;
        integer reads_before;
        begin
            reads_before = ram_read_edges;
            send_ar(address);
            consume_r(32'd0, 2'b11, 3);
            if (ram_read_edges != reads_before)
                $fatal(1, "AXI RAM invalid read reached memory");
            check_memory();
        end
    endtask

    task reset_endpoint;
        begin
            @(negedge clk);
            rst_n = 0; awvalid = 0; wvalid = 0; arvalid = 0;
            bready = 0; rready = 0;
            #1;
            if (awready || wready || arready || bvalid || rvalid)
                $fatal(1, "AXI RAM reset left a protocol output active");
            check_memory();
            repeat (3) @(negedge clk);
            rst_n = 1;
            #1;
            if (bvalid || rvalid) $fatal(1, "AXI RAM reset retained an old response");
            check_memory();
        end
    endtask

    initial begin
        for (k = 0; k < 16; k = k + 1) expected_mem[k] = 0;
        repeat (4) @(negedge clk); rst_n = 1;
        #1; check_memory();

        write_good(BASE, 32'h11223344, 4'hf, 0);
        // Every legal AXI4-Lite mask is permitted, unlike the bridge's
        // CPU-size validation. Mask zero must preserve the whole word.
        for (k = 0; k < 16; k = k + 1)
            write_good(BASE + 4, 32'h11223344 ^ (32'h01020408 * k), k[3:0], k % 3);
        read_good(BASE);
        read_good(BASE + 4);

        // Hold an old read response while a different write changes that
        // same RAM word. Its captured read payload must remain unchanged.
        write_good(BASE + 8, 32'h01020304, 4'hf, 1);
        snapshot = expected_mem[2];
        send_ar(BASE + 8); expected_reads = expected_reads + 1;
        wait_r(snapshot, 2'b00);
        write_good(BASE + 8, 32'hffeeddcc, 4'hf, 2);
        if (!rvalid || rdata !== snapshot)
            $fatal(1, "AXI RAM synchronous read snapshot followed a later write");
        consume_r(snapshot, 2'b00, 4);
        read_good(BASE + 8);

        // Present AR just before the edge on which the paired write needs
        // the physical RAM port. AR must wait, then read the new value.
        @(negedge clk);
        awaddr = BASE + 40; awvalid = 1;
        wdata = 32'h55667788; wstrb = 4'hf; wvalid = 1;
        @(posedge clk);
        if (!awready || !wready) $fatal(1, "AXI RAM contention setup not idle");
        expected_aw = expected_aw + 1; expected_w = expected_w + 1;
        @(negedge clk);
        awvalid = 0; wvalid = 0; araddr = BASE + 40; arvalid = 1;
        apply_expected_write(BASE + 40, 32'h55667788, 4'hf);
        #1;
        if (arready) $fatal(1, "AXI RAM accepted a read during its write port cycle");
        @(posedge clk);
        if (arready || !dut.u_data_mem.we || dut.u_data_mem.re)
            $fatal(1, "AXI RAM shared-port priority failed");
        @(posedge clk);
        if (!arready) $fatal(1, "AXI RAM blocked read after write port became free");
        expected_ar = expected_ar + 1; expected_reads = expected_reads + 1;
        @(negedge clk); arvalid = 0;
        consume_b(2'b00, 3);
        consume_r(32'h55667788, 2'b00, 3);
        check_memory();

        write_bad(BASE + 1, 0);
        write_bad(BASE - 4, 1);
        write_bad(BASE + 64, 2);
        read_bad(BASE + 2);
        read_bad(BASE - 4);
        read_bad(BASE + 64);

        // Reset an address-only exchange, then send a fresh W-first write
        // to prove the old address cannot be paired with fresh data.
        before_write = ram_write_edges;
        send_aw(BASE + 12);
        check_unpaired(before_write);
        reset_endpoint();
        write_good(BASE + 16, 32'h13579bdf, 4'hf, 2);
        // Reset a data-only exchange, then prove the old data is discarded.
        before_write = ram_write_edges;
        send_w(32'hdeadc0de, 4'hf);
        check_unpaired(before_write);
        reset_endpoint();
        write_good(BASE + 20, 32'h2468ace0, 4'hf, 1);

        // The write has committed, but its B response has not been consumed.
        fork send_aw(BASE + 24); send_w(32'h88776655, 4'hf); join
        apply_expected_write(BASE + 24, 32'h88776655, 4'hf);
        wait_b(2'b00);
        check_memory();
        reset_endpoint();
        read_good(BASE + 24);

        // Cancel a held read response. RAM must survive, and neither old
        // response may reappear after the shared reset is released.
        send_ar(BASE + 24); expected_reads = expected_reads + 1;
        wait_r(32'h88776655, 2'b00);
        reset_endpoint();
        read_good(BASE + 24);
        write_good(BASE + 28, 32'hc001d00d, 4'hf, 0);

        repeat (3) @(negedge clk);
        check_memory();
        if (aw_count != expected_aw || w_count != expected_w || ar_count != expected_ar ||
            b_count != expected_b || r_count != expected_r ||
            ram_write_edges != expected_writes || ram_read_edges != expected_reads ||
            contention_blocks != 1 || bvalid || rvalid)
            $fatal(1, "AXI RAM counts AW=%0d/%0d W=%0d/%0d AR=%0d/%0d B=%0d/%0d R=%0d/%0d writes=%0d/%0d reads=%0d/%0d contention=%0d",
                aw_count, expected_aw, w_count, expected_w, ar_count, expected_ar,
                b_count, expected_b, r_count, expected_r, ram_write_edges, expected_writes,
                ram_read_edges, expected_reads, contention_blocks);
        $display("PASS: real AXI RAM: AW/W order, all 16 masks, B/R stability, synchronous snapshot, shared port, DECERR isolation and reset retention");
        $display("AXI RAM totals: AW=%0d W=%0d B=%0d AR=%0d R=%0d valid write enables=%0d read enables=%0d",
            aw_count, w_count, b_count, ar_count, r_count, ram_write_edges, ram_read_edges);
        test_pass = 1;
        $stop;
    end

    initial begin
        #100000;
        $fatal(1, "AXI RAM endpoint test timed out");
    end
endmodule
