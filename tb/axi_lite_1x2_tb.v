`timescale 1ns/1ps

module axi_lite_1x2_tb;
    wire [1:0] done;
    reg test_pass = 0;
    axi_router_case #(.CASE_ID(0), .BASE1(32'h30000000)) normal_case (.done(done[0]));
    axi_router_case #(.CASE_ID(1), .BASE1(32'hffffffc0)) high_case (.done(done[1]));
    initial begin
        wait (&done);
        test_pass = 1;
        $display("PASS: AXI 1x2 public-channel routing, backpressure, independent read/write, misses and shared reset");
        $stop;
    end
    initial begin #100000; $fatal(1, "AXI 1x2 timeout done=%b", done); end
endmodule

// The reference model observes public handshakes only. It does not use any
// DUT state, route register or internal pending flag to determine correctness.
module axi_router_case #(
    parameter integer CASE_ID = 0,
    parameter [31:0] BASE1 = 32'h30000000
) (output reg done = 0);
    localparam [31:0] BASE0 = 32'h00010000;
    localparam [31:0] SIZE = 32'd64;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg [31:0] awaddr = 0, wdata = 0, araddr = 0;
    reg [2:0] awprot = 0, arprot = 0;
    reg [3:0] wstrb = 0;
    reg awvalid = 0, wvalid = 0, arvalid = 0, bready = 0, rready = 0;
    wire awready, wready, arready, bvalid, rvalid;
    wire [1:0] bresp, rresp;
    wire [31:0] rdata;
    wire [31:0] d_awaddr [0:1];
    wire [2:0] d_awprot [0:1];
    wire d_awvalid [0:1];
    wire d_awready [0:1];
    wire [31:0] d_wdata [0:1];
    wire [3:0] d_wstrb [0:1];
    wire d_wvalid [0:1];
    wire d_wready [0:1];
    wire [1:0] d_bresp [0:1];
    wire d_bvalid [0:1];
    wire d_bready [0:1];
    wire [31:0] d_araddr [0:1];
    wire [2:0] d_arprot [0:1];
    wire d_arvalid [0:1];
    wire d_arready [0:1];
    wire [31:0] d_rdata [0:1];
    wire [1:0] d_rresp [0:1];
    wire d_rvalid [0:1];
    wire d_rready [0:1];
    reg [1:0] allow_aw = 0, allow_w = 0, allow_ar = 0, allow_b = 0, allow_r = 0;
    reg [1:0] slave_bresp [0:1], slave_rresp [0:1];
    wire [31:0] slave_aw_count [0:1], slave_w_count [0:1];
    wire [31:0] slave_ar_count [0:1], slave_write_count [0:1];

    axi_lite_1x2 #(
        .M0_BASE_ADDR(BASE0), .M0_SIZE_BYTES(SIZE),
        .M1_BASE_ADDR(BASE1), .M1_SIZE_BYTES(SIZE)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(awaddr),
        .s_axi_awprot(awprot),
        .s_axi_awvalid(awvalid),
        .s_axi_awready(awready),
        .s_axi_wdata(wdata),
        .s_axi_wstrb(wstrb),
        .s_axi_wvalid(wvalid),
        .s_axi_wready(wready),
        .s_axi_bresp(bresp),
        .s_axi_bvalid(bvalid),
        .s_axi_bready(bready),
        .s_axi_araddr(araddr),
        .s_axi_arprot(arprot),
        .s_axi_arvalid(arvalid),
        .s_axi_arready(arready),
        .s_axi_rdata(rdata),
        .s_axi_rresp(rresp),
        .s_axi_rvalid(rvalid),
        .s_axi_rready(rready),
        .m0_axi_awaddr(d_awaddr[0]),
        .m0_axi_awprot(d_awprot[0]),
        .m0_axi_awvalid(d_awvalid[0]),
        .m0_axi_awready(d_awready[0]),
        .m0_axi_wdata(d_wdata[0]),
        .m0_axi_wstrb(d_wstrb[0]),
        .m0_axi_wvalid(d_wvalid[0]),
        .m0_axi_wready(d_wready[0]),
        .m0_axi_bresp(d_bresp[0]),
        .m0_axi_bvalid(d_bvalid[0]),
        .m0_axi_bready(d_bready[0]),
        .m0_axi_araddr(d_araddr[0]),
        .m0_axi_arprot(d_arprot[0]),
        .m0_axi_arvalid(d_arvalid[0]),
        .m0_axi_arready(d_arready[0]),
        .m0_axi_rdata(d_rdata[0]),
        .m0_axi_rresp(d_rresp[0]),
        .m0_axi_rvalid(d_rvalid[0]),
        .m0_axi_rready(d_rready[0]),
        .m1_axi_awaddr(d_awaddr[1]),
        .m1_axi_awprot(d_awprot[1]),
        .m1_axi_awvalid(d_awvalid[1]),
        .m1_axi_awready(d_awready[1]),
        .m1_axi_wdata(d_wdata[1]),
        .m1_axi_wstrb(d_wstrb[1]),
        .m1_axi_wvalid(d_wvalid[1]),
        .m1_axi_wready(d_wready[1]),
        .m1_axi_bresp(d_bresp[1]),
        .m1_axi_bvalid(d_bvalid[1]),
        .m1_axi_bready(d_bready[1]),
        .m1_axi_araddr(d_araddr[1]),
        .m1_axi_arprot(d_arprot[1]),
        .m1_axi_arvalid(d_arvalid[1]),
        .m1_axi_arready(d_arready[1]),
        .m1_axi_rdata(d_rdata[1]),
        .m1_axi_rresp(d_rresp[1]),
        .m1_axi_rvalid(d_rvalid[1]),
        .m1_axi_rready(d_rready[1])
    );
    genvar g;
    generate for (g=0; g<2; g=g+1) begin : slaves
        axi_router_fake_slave #(
            .BASE(g==0 ? BASE0 : BASE1), .INITIAL_WORD(g==0 ? 32'ha0000000 : 32'hb0000000)
        ) endpoint (
            .clk(clk), .rst_n(rst_n),
            .allow_aw(allow_aw[g]), .allow_w(allow_w[g]), .allow_ar(allow_ar[g]),
            .allow_b(allow_b[g]), .allow_r(allow_r[g]),
            .configured_bresp(slave_bresp[g]), .configured_rresp(slave_rresp[g]),
            .awaddr(d_awaddr[g]),
            .awprot(d_awprot[g]),
            .awvalid(d_awvalid[g]),
            .awready(d_awready[g]),
            .wdata(d_wdata[g]),
            .wstrb(d_wstrb[g]),
            .wvalid(d_wvalid[g]),
            .wready(d_wready[g]),
            .bresp(d_bresp[g]),
            .bvalid(d_bvalid[g]),
            .bready(d_bready[g]),
            .araddr(d_araddr[g]),
            .arprot(d_arprot[g]),
            .arvalid(d_arvalid[g]),
            .arready(d_arready[g]),
            .rdata(d_rdata[g]),
            .rresp(d_rresp[g]),
            .rvalid(d_rvalid[g]),
            .rready(d_rready[g]),
            .aw_count(slave_aw_count[g]), .w_count(slave_w_count[g]),
            .ar_count(slave_ar_count[g]), .write_count(slave_write_count[g])
        );
    end endgenerate

    function integer reference_target;
        input [31:0] address;
        begin
            // Subtraction is intentionally different from the DUT end-address
            // comparison and covers a window whose end is exactly 4 GiB.
            if (address >= BASE0 && (address-BASE0) < SIZE) reference_target = 0;
            else if (address >= BASE1 && (address-BASE1) < SIZE) reference_target = 1;
            else reference_target = 2;
        end
    endfunction

    reg e_aw = 0, e_w = 0, e_ar = 0;
    reg seen_aw = 0, seen_w = 0, seen_ar = 0;
    reg [31:0] e_awaddr, e_wdata, e_araddr, e_rdata;
    reg [2:0] e_awprot, e_arprot;
    reg [3:0] e_wstrb;
    reg [1:0] e_bresp, e_rresp, planned_bresp = 0, planned_rresp = 0;
    reg [31:0] planned_rdata = 0;
    integer wt = 2, rt = 2;
    integer b_count = 0, r_count = 0, expected_b_count = 0, expected_r_count = 0;
    integer expected_applied_writes = 0, overlap_cycles = 0;
    integer write_cancels = 0, read_cancels = 0;
    reg [1:0] aw_held = 0, w_held = 0, ar_held = 0;
    reg [31:0] held_awaddr [0:1], held_wdata [0:1], held_araddr [0:1];
    reg [2:0] held_awprot [0:1], held_arprot [0:1];
    reg [3:0] held_wstrb [0:1];
    reg b_held = 0, r_held = 0;
    reg [1:0] held_bresp, held_rresp;
    reg [31:0] held_rdata;
    integer i;

    always @(posedge clk) begin
        if (!rst_n) begin
            if (e_aw || e_w) write_cancels = write_cancels + 1;
            if (e_ar) read_cancels = read_cancels + 1;
            e_aw = 0; e_w = 0; e_ar = 0;
            seen_aw = 0; seen_w = 0; seen_ar = 0;
            wt = 2; rt = 2;
            aw_held = 0; w_held = 0; ar_held = 0;
            b_held = 0; r_held = 0;
        end else begin
            if (b_held && (!bvalid || bresp !== held_bresp))
                $fatal(1, "case %0d upstream B changed while blocked", CASE_ID);
            if (r_held && (!rvalid || rresp !== held_rresp || rdata !== held_rdata))
                $fatal(1, "case %0d upstream R changed while blocked", CASE_ID);
            b_held = bvalid && !bready;
            r_held = rvalid && !rready;
            if (b_held) held_bresp = bresp;
            if (r_held) begin held_rresp = rresp; held_rdata = rdata; end
            if (awvalid && awready) begin
                if (e_aw) $fatal(1, "duplicate upstream AW");
                e_aw = 1; e_awaddr = awaddr; e_awprot = awprot;
                wt = reference_target(awaddr);
                e_bresp = wt==2 ? 2'b11 : planned_bresp;
            end
            if (wvalid && wready) begin
                if (e_w) $fatal(1, "duplicate upstream W");
                e_w = 1; e_wdata = wdata; e_wstrb = wstrb;
            end
            if (arvalid && arready) begin
                if (e_ar) $fatal(1, "duplicate upstream AR");
                e_ar = 1; e_araddr = araddr; e_arprot = arprot;
                rt = reference_target(araddr);
                e_rresp = rt==2 ? 2'b11 : planned_rresp;
                e_rdata = rt==2 ? 32'd0 : planned_rdata;
            end
            if ((e_aw || e_w) && e_ar) overlap_cycles = overlap_cycles + 1;
            for (i=0; i<2; i=i+1) begin
                if (aw_held[i] && (!d_awvalid[i] || d_awaddr[i] !== held_awaddr[i] ||
                    d_awprot[i] !== held_awprot[i])) $fatal(1, "downstream AW changed target=%0d", i);
                if (w_held[i] && (!d_wvalid[i] || d_wdata[i] !== held_wdata[i] ||
                    d_wstrb[i] !== held_wstrb[i])) $fatal(1, "downstream W changed target=%0d", i);
                if (ar_held[i] && (!d_arvalid[i] || d_araddr[i] !== held_araddr[i] ||
                    d_arprot[i] !== held_arprot[i])) $fatal(1, "downstream AR changed target=%0d", i);
                aw_held[i] = d_awvalid[i] && !d_awready[i];
                w_held[i] = d_wvalid[i] && !d_wready[i];
                ar_held[i] = d_arvalid[i] && !d_arready[i];
                if (aw_held[i]) begin held_awaddr[i] = d_awaddr[i]; held_awprot[i] = d_awprot[i]; end
                if (w_held[i]) begin held_wdata[i] = d_wdata[i]; held_wstrb[i] = d_wstrb[i]; end
                if (ar_held[i]) begin held_araddr[i] = d_araddr[i]; held_arprot[i] = d_arprot[i]; end

                if ((d_awvalid[i] || d_wvalid[i]) && (!e_aw || !e_w || wt!=i))
                    $fatal(1, "wrong/premature write target=%0d", i);
                if (d_arvalid[i] && (!e_ar || rt!=i)) $fatal(1, "wrong read target=%0d", i);
                if (d_bready[i] && (!e_aw || !e_w || wt!=i || !seen_aw || !seen_w))
                    $fatal(1, "unselected/premature BREADY target=%0d", i);
                if (d_rready[i] && (!e_ar || rt!=i || !seen_ar))
                    $fatal(1, "unselected/premature RREADY target=%0d", i);
                if (d_awvalid[i] && d_awready[i]) begin
                    if (seen_aw || d_awaddr[i] !== e_awaddr || d_awprot[i] !== e_awprot)
                        $fatal(1, "AW payload/count differs target=%0d", i);
                    seen_aw = 1;
                end
                if (d_wvalid[i] && d_wready[i]) begin
                    if (seen_w || d_wdata[i] !== e_wdata || d_wstrb[i] !== e_wstrb)
                        $fatal(1, "W payload/count differs target=%0d", i);
                    seen_w = 1;
                end
                if (d_arvalid[i] && d_arready[i]) begin
                    if (seen_ar || d_araddr[i] !== e_araddr || d_arprot[i] !== e_arprot)
                        $fatal(1, "AR payload/count differs target=%0d", i);
                    seen_ar = 1;
                end
            end
            if (bvalid) begin
                if (!e_aw || !e_w || bresp !== e_bresp || (wt!=2 && (!seen_aw || !seen_w)))
                    $fatal(1, "unexpected B response case=%0d resp=%b", CASE_ID, bresp);
                if (wt==2 && (seen_aw || seen_w)) $fatal(1, "miss write reached subordinate");
            end
            if (rvalid) begin
                if (!e_ar || rresp !== e_rresp || rdata !== e_rdata || (rt!=2 && !seen_ar))
                    $fatal(1, "unexpected R case=%0d addr=%h data=%h expected=%h resp=%b",
                        CASE_ID, e_araddr, rdata, e_rdata, rresp);
                if (rt==2 && seen_ar) $fatal(1, "miss read reached subordinate");
            end
            if (bvalid && bready) begin
                b_count = b_count + 1; e_aw = 0; e_w = 0;
                seen_aw = 0; seen_w = 0; wt = 2;
            end
            if (rvalid && rready) begin
                r_count = r_count + 1; e_ar = 0; seen_ar = 0; rt = 2;
            end
        end
    end

    // Independent timing oracle: observe only upstream handshakes. The
    // selected downstream VALIDs (or local DECERR) must appear immediately
    // after the edge that accepts the second write channel, without a bubble.
    reg latency_aw_seen = 0, latency_w_seen = 0, latency_pair_seen = 0;
    reg [31:0] latency_address = 0;
    integer latency_target;
    always @(posedge clk) begin
        if (!rst_n) begin
            latency_aw_seen = 0;
            latency_w_seen = 0;
            latency_pair_seen = 0;
        end else begin
            if (awvalid && awready) begin
                latency_aw_seen = 1;
                latency_address = awaddr;
            end
            if (wvalid && wready) latency_w_seen = 1;
            if (bvalid && bready) begin
                latency_aw_seen = 0;
                latency_w_seen = 0;
                latency_pair_seen = 0;
            end
            if (latency_aw_seen && latency_w_seen && !latency_pair_seen) begin
                latency_pair_seen = 1;
                latency_target = reference_target(latency_address);
                #1;
                if (latency_target == 2) begin
                    if (!bvalid || bresp !== 2'b11 || d_awvalid[0] ||
                        d_awvalid[1] || d_wvalid[0] || d_wvalid[1])
                        $fatal(1, "router miss was not paired immediately");
                end else if (!d_awvalid[latency_target] || !d_wvalid[latency_target] ||
                    d_awaddr[latency_target] !== latency_address ||
                    d_awvalid[1-latency_target] || d_wvalid[1-latency_target])
                    $fatal(1, "router introduced a pairing bubble or used a stale AW address");
            end
        end
    end

    task send_aw;
        input [31:0] address;
        input [2:0] prot;
        begin
            @(negedge clk); awaddr = address; awprot = prot; awvalid = 1;
            begin : aw_loop
                forever begin @(posedge clk); if (awready) disable aw_loop; end
            end
            @(negedge clk); awvalid = 0; awaddr = ~address; awprot = ~prot;
        end
    endtask
    task send_w;
        input [31:0] value;
        input [3:0] mask;
        begin
            @(negedge clk); wdata = value; wstrb = mask; wvalid = 1;
            begin : w_loop
                forever begin @(posedge clk); if (wready) disable w_loop; end
            end
            @(negedge clk); wvalid = 0; wdata = ~value; wstrb = ~mask;
        end
    endtask
    task send_ar;
        input [31:0] address;
        input [2:0] prot;
        begin
            @(negedge clk); araddr = address; arprot = prot; arvalid = 1;
            begin : ar_loop
                forever begin @(posedge clk); if (arready) disable ar_loop; end
            end
            @(negedge clk); arvalid = 0; araddr = ~address; arprot = ~prot;
        end
    endtask

    // Release the subordinate request channels in a controlled order.
    // VALID must already exist while both READY inputs are held low.
    task release_write;
        input integer target, order;
        reg [31:0] old_aw, old_w;
        begin
            wait (d_awvalid[target] && d_wvalid[target]);
            repeat (3) @(negedge clk);
            old_aw = slave_aw_count[target]; old_w = slave_w_count[target];
            if (order==0) begin
                allow_aw[target] = 1;
                wait (slave_aw_count[target] == old_aw+1);
                repeat (2) @(negedge clk);
                if (slave_w_count[target] !== old_w) $fatal(1, "W escaped blocked READY");
                allow_w[target] = 1;
            end else if (order==1) begin
                allow_w[target] = 1;
                wait (slave_w_count[target] == old_w+1);
                repeat (2) @(negedge clk);
                if (slave_aw_count[target] !== old_aw) $fatal(1, "AW escaped blocked READY");
                allow_aw[target] = 1;
            end else begin allow_aw[target] = 1; allow_w[target] = 1; end
            wait (slave_aw_count[target] == old_aw+1 && slave_w_count[target] == old_w+1);
        end
    endtask

    task consume_b;
        begin
            wait (bvalid);
            repeat (4) @(negedge clk);
            bready = 1;
            @(posedge clk); #1;
            @(negedge clk); bready = 0; allow_b = 0;
            expected_b_count = expected_b_count + 1;
        end
    endtask
    task consume_r;
        begin
            wait (rvalid);
            repeat (4) @(negedge clk);
            rready = 1;
            @(posedge clk); #1;
            @(negedge clk); rready = 0; allow_r = 0;
            expected_r_count = expected_r_count + 1;
        end
    endtask

    task write_transaction;
        input [31:0] address, value;
        input [3:0] mask;
        input integer up_order, down_order;
        input [1:0] response;
        integer target;
        begin
            target = reference_target(address);
            @(negedge clk);
            allow_aw = 0; allow_w = 0; allow_b = 0;
            planned_bresp = response;
            slave_bresp[0] = response; slave_bresp[1] = response;
            if (up_order==0) begin
                send_aw(address, 3'b101);
                repeat (3) @(negedge clk);
                if (bvalid || d_awvalid[0] || d_awvalid[1] || d_wvalid[0] || d_wvalid[1])
                    $fatal(1, "write issued without W");
                send_w(value, mask);
            end else if (up_order==1) begin
                send_w(value, mask);
                repeat (3) @(negedge clk);
                if (bvalid || d_awvalid[0] || d_awvalid[1] || d_wvalid[0] || d_wvalid[1])
                    $fatal(1, "write issued without AW");
                send_aw(address, 3'b110);
            end else begin
                fork send_aw(address, 3'b011); send_w(value, mask); join
            end
            if (target!=2) begin
                release_write(target, down_order);
                repeat (3) @(negedge clk);
                allow_b[target] = 1;
                expected_applied_writes = expected_applied_writes + 1;
            end
            consume_b;
        end
    endtask

    task read_transaction;
        input [31:0] address, value;
        input [1:0] response;
        integer target;
        reg [31:0] old_ar;
        begin
            target = reference_target(address);
            @(negedge clk);
            allow_ar = 0; allow_r = 0;
            planned_rdata = value; planned_rresp = response;
            slave_rresp[0] = response; slave_rresp[1] = response;
            send_ar(address, 3'b111);
            if (target!=2) begin
                wait (d_arvalid[target]);
                repeat (3) @(negedge clk);
                old_ar = slave_ar_count[target];
                allow_ar[target] = 1;
                wait (slave_ar_count[target] == old_ar+1);
                repeat (3) @(negedge clk);
                allow_r[target] = 1;
            end
            consume_r;
        end
    endtask

    task joint_reset;
        begin
            @(negedge clk); rst_n = 0;
            awvalid = 0; wvalid = 0; arvalid = 0; bready = 0; rready = 0;
            allow_aw = 0; allow_w = 0; allow_ar = 0; allow_b = 0; allow_r = 0;
            repeat (3) @(negedge clk);
            if (bvalid || rvalid || d_awvalid[0] || d_awvalid[1] ||
                d_wvalid[0] || d_wvalid[1] || d_arvalid[0] || d_arvalid[1] ||
                d_bready[0] || d_bready[1] || d_rready[0] || d_rready[1])
                $fatal(1, "reset failed to cancel protocol");
            rst_n = 1;
            repeat (3) @(negedge clk);
            if (bvalid || rvalid) $fatal(1, "old response escaped reset");
        end
    endtask

    integer old_commits;
    reg [31:0] old_aw_count, old_w_count, old_ar_count;
    initial begin
        slave_bresp[0] = 0; slave_bresp[1] = 0;
        slave_rresp[0] = 0; slave_rresp[1] = 0;
        repeat (4) @(negedge clk); rst_n = 1;
        // Target alternation and every upstream/downstream channel order.
        write_transaction(BASE0, 32'h11223344, 4'hf, 0, 1, 0);
        write_transaction(BASE1, 32'hdeadbeef, 4'hf, 1, 0, 0);
        read_transaction(BASE0, 32'h11223344, 0);
        read_transaction(BASE1, 32'hdeadbeef, 0);
        write_transaction(BASE0+4, 32'haabbccdd, 4'h5, 2, 2, 0);
        read_transaction(BASE0+4, 32'ha0bb00dd, 0);
        // Router is range-only: forward unaligned last-byte addresses unchanged.
        write_transaction(BASE0+63, 32'h55000000, 4'h8, 0, 0, 0);
        write_transaction(BASE1+63, 32'h66000000, 4'h8, 1, 1, 0);
        read_transaction(BASE0+63, 32'h5500000f, 0);
        read_transaction(BASE1+63, 32'h6600000f, 0);
        // Every byte outside either window is a local error without slave effects.
        write_transaction(BASE0-1, 32'hf00df00d, 4'hf, 0, 0, 0);
        write_transaction(BASE0+SIZE, 32'hf00df00d, 4'hf, 1, 0, 0);
        write_transaction(BASE1+SIZE, 32'hf00df00d, 4'hf, 2, 0, 0);
        read_transaction(BASE0-1, 0, 0);
        read_transaction(BASE0+SIZE, 0, 0);
        read_transaction(BASE1-1, 0, 0);
        read_transaction(BASE1+SIZE, 0, 0);
        // Selected slave response errors pass through; EXOKAY is not rewritten.
        write_transaction(BASE0+20, 32'h99887766, 4'hf, 2, 1, 2'b10);
        read_transaction(BASE0+20, 32'h99887766, 2'b10);
        write_transaction(BASE1+20, 32'h01020304, 4'h0, 0, 2, 2'b01);
        read_transaction(BASE1+20, 32'hb0000005, 2'b01);
        // Independent read/write transactions are outstanding together.
        fork
            write_transaction(BASE0+8, 32'hcafebabe, 4'hf, 2, 1, 0);
            read_transaction(BASE1+12, 32'hb0000003, 0);
        join
        read_transaction(BASE0+8, 32'hcafebabe, 0);

        // Half-collected upstream requests must not reach either slave.
        planned_bresp = 0;
        allow_aw = 0; allow_w = 0; allow_b = 0;
        send_aw(BASE0+16, 3'b010);
        repeat (3) @(negedge clk);
        if (d_awvalid[0] || d_wvalid[0] || bvalid) $fatal(1, "half AW forwarded");
        joint_reset;
        send_w(32'hffffffff, 4'hf);
        repeat (3) @(negedge clk);
        if (d_awvalid[0] || d_awvalid[1] || d_wvalid[0] || d_wvalid[1] || bvalid)
            $fatal(1, "half W forwarded");
        joint_reset;
        read_transaction(BASE0+16, 32'ha0000004, 0);

        // AW accepted at slave, W still blocked; shared reset cancels both slots.
        planned_bresp = 0; slave_bresp[0] = 0;
        fork send_aw(BASE0+16, 3'b001); send_w(32'h12345678, 4'hf); join
        wait (d_awvalid[0] && d_wvalid[0]);
        old_aw_count = slave_aw_count[0];
        @(negedge clk); allow_aw[0] = 1;
        wait (slave_aw_count[0] == old_aw_count+1);
        repeat (2) @(negedge clk);
        joint_reset;
        // Converse order: W accepted, AW blocked.
        fork send_aw(BASE1+16, 3'b100); send_w(32'h87654321, 4'hf); join
        wait (d_awvalid[1] && d_wvalid[1]);
        old_w_count = slave_w_count[1];
        @(negedge clk); allow_w[1] = 1;
        wait (slave_w_count[1] == old_w_count+1);
        repeat (2) @(negedge clk);
        joint_reset;
        read_transaction(BASE0+16, 32'ha0000004, 0);
        read_transaction(BASE1+16, 32'hb0000004, 0);
        // A write already applied survives reset even if no B has appeared.
        fork send_aw(BASE0+16, 3'b000); send_w(32'h01234567, 4'hf); join
        old_commits = slave_write_count[0];
        release_write(0, 2);
        wait (slave_write_count[0] == old_commits+1);
        expected_applied_writes = expected_applied_writes + 1;
        if (bvalid) $fatal(1, "slave response escaped its delay");
        joint_reset;
        read_transaction(BASE0+16, 32'h01234567, 0);
        // Cancel an upstream response that is already VALID but backpressured.
        fork send_aw(BASE1+16, 3'b101); send_w(32'h76543210, 4'hf); join
        old_commits = slave_write_count[1];
        release_write(1, 1);
        wait (slave_write_count[1] == old_commits+1);
        expected_applied_writes = expected_applied_writes + 1;
        @(negedge clk); allow_b[1] = 1;
        wait (bvalid);
        repeat (3) @(negedge clk);
        joint_reset;
        read_transaction(BASE1+16, 32'h76543210, 0);
        // Cancel a read before R appears, then another while upstream R is held.
        planned_rdata = 32'h11223344; planned_rresp = 0;
        allow_ar = 0; allow_r = 0;
        send_ar(BASE0, 3'b010);
        wait (d_arvalid[0]); old_ar_count = slave_ar_count[0];
        @(negedge clk); allow_ar[0] = 1;
        wait (slave_ar_count[0] == old_ar_count+1);
        repeat (2) @(negedge clk);
        joint_reset;
        read_transaction(BASE1, 32'hdeadbeef, 0);
        planned_rdata = 32'h11223344; planned_rresp = 0;
        allow_ar = 0; allow_r = 0;
        send_ar(BASE0, 3'b101);
        wait (d_arvalid[0]); old_ar_count = slave_ar_count[0];
        @(negedge clk); allow_ar[0] = 1;
        wait (slave_ar_count[0] == old_ar_count+1);
        @(negedge clk); allow_r[0] = 1;
        wait (rvalid);
        repeat (3) @(negedge clk);
        joint_reset;
        read_transaction(BASE1+16, 32'h76543210, 0);
        write_transaction(BASE0+24, 32'h13579bdf, 4'hf, 1, 0, 0);
        read_transaction(BASE0+24, 32'h13579bdf, 0);

        repeat (3) @(negedge clk);
        if (e_aw || e_w || e_ar || b_count!=12 || r_count!=21 ||
            expected_b_count!=12 || expected_r_count!=21 || expected_applied_writes!=11 ||
            b_count!=expected_b_count || r_count!=expected_r_count ||
            slave_write_count[0]+slave_write_count[1] != expected_applied_writes ||
            write_cancels!=6 || read_cancels!=2 || overlap_cycles==0)
            $fatal(1, "case %0d final accounting B=%0d/%0d R=%0d/%0d writes=%0d/%0d cancels=%0d/%0d overlap=%0d",
                CASE_ID, b_count, expected_b_count, r_count, expected_r_count,
                slave_write_count[0]+slave_write_count[1], expected_applied_writes,
                write_cancels, read_cancels, overlap_cycles);
        done = 1;
        $display("AXI 1x2 case %0d PASS: B=%0d R=%0d applied writes=%0d reset cancel W=%0d R=%0d overlap=%0d base1=%h",
            CASE_ID, b_count, r_count, expected_applied_writes, write_cancels, read_cancels, overlap_cycles, BASE1);
    end
endmodule

// A controlled subordinate with its own AW/W slots and memory effects.
// Test gates introduce delays, while its outputs obey AXI response holding.
// These endpoint counts and RAM values are independent of the router state.
module axi_router_fake_slave #(
    parameter [31:0] BASE = 32'h00010000,
    parameter [31:0] INITIAL_WORD = 32'ha0000000
) (
    input wire clk, rst_n,
    input wire allow_aw, allow_w, allow_ar, allow_b, allow_r,
    input wire [1:0] configured_bresp, configured_rresp,
    input wire [31:0] awaddr, wdata, araddr,
    input wire [2:0] awprot, arprot,
    input wire [3:0] wstrb,
    input wire awvalid, wvalid, arvalid,
    output wire awready, wready, arready,
    output wire [1:0] bresp, rresp,
    output wire bvalid, rvalid,
    input wire bready, rready,
    output wire [31:0] rdata,
    output reg [31:0] aw_count = 0, w_count = 0, ar_count = 0, write_count = 0
);
    reg [31:0] mem [0:15];
    reg aw_slot = 0, w_slot = 0, b_slot = 0, r_slot = 0;
    reg [31:0] address_q = 0, data_q = 0, rdata_q = 0;
    reg [3:0] mask_q = 0;
    reg [1:0] bresp_q = 0, rresp_q = 0;
    integer k, lane, index;
    initial for (k=0; k<16; k=k+1) mem[k] = INITIAL_WORD ^ k;
    assign awready = rst_n && allow_aw && !aw_slot && !b_slot;
    assign wready = rst_n && allow_w && !w_slot && !b_slot;
    assign arready = rst_n && allow_ar && !r_slot;
    assign bvalid = rst_n && b_slot && allow_b;
    assign rvalid = rst_n && r_slot && allow_r;
    assign bresp = bresp_q;
    assign rresp = rresp_q;
    assign rdata = rdata_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_slot <= 0; w_slot <= 0; b_slot <= 0; r_slot <= 0;
            address_q <= 0; data_q <= 0; mask_q <= 0;
            rdata_q <= 0; bresp_q <= 0; rresp_q <= 0;
        end else begin
            if (awvalid && awready) begin
                aw_slot <= 1; address_q <= awaddr; aw_count <= aw_count+1;
            end
            if (wvalid && wready) begin
                w_slot <= 1; data_q <= wdata; mask_q <= wstrb; w_count <= w_count+1;
            end
            if (aw_slot && w_slot && !b_slot) begin
                if (!(address_q>=BASE && address_q-BASE<64))
                    $fatal(1, "fake subordinate received out-of-window write %h", address_q);
                index = (address_q-BASE)>>2;
                for (lane=0; lane<4; lane=lane+1)
                    if (mask_q[lane]) mem[index][lane*8 +: 8] <= data_q[lane*8 +: 8];
                write_count <= write_count+1;
                aw_slot <= 0; w_slot <= 0; b_slot <= 1;
                bresp_q <= configured_bresp;
            end
            if (bvalid && bready) b_slot <= 0;
            if (arvalid && arready) begin
                if (!(araddr>=BASE && araddr-BASE<64))
                    $fatal(1, "fake subordinate received out-of-window read %h", araddr);
                rdata_q <= mem[(araddr-BASE)>>2];
                rresp_q <= configured_rresp; r_slot <= 1; ar_count <= ar_count+1;
            end
            if (rvalid && rready) r_slot <= 0;
        end
    end
    // PROT values are transport attributes checked by the upstream scoreboard.
    wire unused_prot = ^awprot ^ ^arprot;
endmodule

