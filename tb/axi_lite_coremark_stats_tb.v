`timescale 1ns/1ps

// Future self-check only: this testbench has not been compiled or simulated.
module axi_lite_coremark_stats_case #(
    parameter integer CACHE_ENABLE = 1,
    parameter integer I_SETS = 32,
    parameter integer D_SETS = 64
) (
    input wire clk,
    output reg done = 0
);
    localparam [31:0] BASE = 32'h30000000;
    localparam [31:0] SNAP_ID = 32'h434d4158;
    localparam [31:0] FLAGS = CACHE_ENABLE ? 32'd3 : 32'd0;
    localparam [31:0] I_GEOMETRY = (32'd2 << 24) | (I_SETS << 16) | 32'd16;
    localparam [31:0] D_GEOMETRY = (32'd2 << 24) | (D_SETS << 16) | 32'd16;

    reg rst_n = 0;
    // The register order is the documented 16-word START/STOP bank layout.
    reg [31:0] live [0:15];
    reg [31:0] expected_start [0:15];
    reg [31:0] expected_stop [0:15];
    reg [31:0] awaddr = 0, wdata = 0, araddr = 0;
    reg [3:0] wstrb = 0;
    reg awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    wire awready, wready, bvalid, arready, rvalid;
    wire [1:0] bresp, rresp;
    wire [31:0] rdata;
    integer k;

    axi_lite_coremark_stats #(
        .ENABLE_ICACHE(CACHE_ENABLE), .ENABLE_DCACHE(CACHE_ENABLE),
        .ICACHE_SETS(I_SETS), .DCACHE_SETS(D_SETS)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .cycle_count({live[1], live[0]}), .instret_count({live[3], live[2]}),
        .icache_access_count(live[4]), .icache_hit_count(live[5]),
        .icache_miss_count(live[6]), .icache_refill_word_count(live[7]),
        .icache_error_count(live[8]),
        .dcache_access_count(live[9]), .dcache_hit_count(live[10]),
        .dcache_miss_count(live[11]), .dcache_refill_word_count(live[12]),
        .dcache_error_count(live[13]), .dcache_write_count(live[14]),
        .dcache_bypass_count(live[15]),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'd0),
        .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'd0),
        .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp),
        .s_axi_rvalid(rvalid), .s_axi_rready(rready)
    );

    task set_live(input [31:0] seed);
        integer i;
        begin
            for (i = 0; i < 16; i = i + 1)
                live[i] = seed + i * 32'h01020304;
        end
    endtask

    task advance_live;
        integer i;
        begin
            for (i = 0; i < 16; i = i + 1)
                live[i] = live[i] + 32'h00100001 + i;
        end
    endtask

    task remember_bank(input integer stop_bank);
        integer i;
        begin
            for (i = 0; i < 16; i = i + 1) begin
                if (stop_bank) expected_stop[i] = live[i];
                else expected_start[i] = live[i];
            end
        end
    endtask

    task check_response(input [31:0] value, input [1:0] response);
        begin
            if (!rvalid || rdata !== value || rresp !== response)
                $fatal(1, "CoreMark stats cache=%0d AR=%h data=%h expected=%h resp=%b expected=%b",
                       CACHE_ENABLE, araddr, rdata, value, rresp, response);
        end
    endtask

    task read_word(input [31:0] offset, input [31:0] value, input [1:0] response);
        begin
            @(negedge clk);
            araddr = BASE + offset;
            arvalid = 1;
            rready = 0;
            @(posedge clk);
            while (!arready) @(posedge clk);
            @(negedge clk);
            arvalid = 0;
            // Move every live input while the completed response is stalled.
            repeat (3) begin
                check_response(value, response);
                if (arready) $fatal(1, "CoreMark stats accepted AR over a stalled R");
                advance_live;
                @(negedge clk);
            end
            check_response(value, response);
            rready = 1;
            @(posedge clk);
            @(negedge clk);
            rready = 0;
            if (rvalid) $fatal(1, "CoreMark stats R response was not consumed");
        end
    endtask

    task trigger_snapshot(input integer stop_bank);
        begin
            // Inputs remain unchanged until the request handshake has occurred.
            remember_bank(stop_bank);
            read_word(stop_bank ? 32'h04 : 32'h00, SNAP_ID, 2'b00);
        end
    endtask

    task read_bank(input integer stop_bank);
        integer i;
        begin
            for (i = 0; i < 16; i = i + 1)
                read_word((stop_bank ? 32'h80 : 32'h40) + i * 4,
                          stop_bank ? expected_stop[i] : expected_start[i], 2'b00);
        end
    endtask

    // Adjacent accepted AR requests exercise independent sampling clocks and
    // consuming one R while accepting the next AR on the same rising edge.
    task adjacent_start_stop;
        begin
            @(negedge clk);
            set_live(32'h11000000);
            live[0] = 32'hfffffffe;
            live[1] = 32'h12345678;
            live[2] = 32'hffffffff;
            live[3] = 32'h87654321;
            remember_bank(0);
            araddr = BASE;
            arvalid = 1;
            rready = 1;
            @(posedge clk);
            if (!arready) $fatal(1, "CoreMark stats START AR was unexpectedly blocked");
            @(negedge clk);
            check_response(SNAP_ID, 2'b00);
            set_live(32'h22000000);
            live[0] = 32'h00000003;
            live[1] = 32'h12345679;
            live[2] = 32'h00000005;
            live[3] = 32'h87654322;
            remember_bank(1);
            araddr = BASE + 4;
            @(posedge clk);
            if (!arready || !rvalid)
                $fatal(1, "CoreMark stats failed simultaneous R consume and STOP AR");
            @(negedge clk);
            arvalid = 0;
            rready = 0;
            repeat (4) begin
                check_response(SNAP_ID, 2'b00);
                advance_live;
                @(negedge clk);
            end
            rready = 1;
            @(posedge clk);
            @(negedge clk);
            rready = 0;
        end
    endtask

    // A held AR trigger may sample only when the earlier R is consumed.
    task blocked_stop_trigger;
        begin
            @(negedge clk);
            araddr = BASE + 8;
            arvalid = 1;
            rready = 0;
            @(posedge clk);
            if (!arready) $fatal(1, "CoreMark stats flag read was unexpectedly blocked");
            @(negedge clk);
            araddr = BASE + 4;
            repeat (4) begin
                check_response(FLAGS, 2'b00);
                if (arready) $fatal(1, "CoreMark stats STOP AR sampled before ready");
                advance_live;
                @(negedge clk);
            end
            remember_bank(1);
            rready = 1;
            @(posedge clk);
            if (!arready) $fatal(1, "CoreMark stats STOP AR remained blocked after R ready");
            @(negedge clk);
            arvalid = 0;
            rready = 0;
            repeat (3) begin
                check_response(SNAP_ID, 2'b00);
                advance_live;
                @(negedge clk);
            end
            rready = 1;
            @(posedge clk);
            @(negedge clk);
            rready = 0;
        end
    endtask

    task send_aw;
        begin
            @(negedge clk);
            awvalid = 1;
            @(posedge clk);
            while (!awready) @(posedge clk);
            @(negedge clk);
            awvalid = 0;
        end
    endtask

    task send_w;
        begin
            @(negedge clk);
            wvalid = 1;
            @(posedge clk);
            while (!wready) @(posedge clk);
            @(negedge clk);
            wvalid = 0;
        end
    endtask

    task consume_write_error;
        begin
            wait (bvalid);
            repeat (4) begin
                @(negedge clk);
                if (!bvalid || bresp !== 2'b10 || awready || wready)
                    $fatal(1, "CoreMark stats lost held SLVERR or accepted another write");
            end
            bready = 1;
            @(posedge clk);
            @(negedge clk);
            bready = 0;
            if (bvalid) $fatal(1, "CoreMark stats B response was not consumed");
        end
    endtask

    task write_error(input [31:0] offset, input integer order);
        begin
            @(negedge clk);
            awaddr = BASE + offset;
            wdata = offset ^ 32'ha55a69c3;
            wstrb = order == 0 ? 4'hf : order == 1 ? offset[3:0] : 4'h0;
            if (order == 0) begin
                send_aw;
                repeat (3) @(negedge clk);
                if (bvalid) $fatal(1, "CoreMark stats responded without W");
                send_w;
            end else if (order == 1) begin
                send_w;
                repeat (3) @(negedge clk);
                if (bvalid) $fatal(1, "CoreMark stats responded without AW");
                send_aw;
            end else begin
                fork
                    send_aw;
                    send_w;
                join
            end
            consume_write_error;
        end
    endtask

    task assert_reset_state;
        begin
            #1;
            if (bvalid || rvalid || awready || wready || arready)
                $fatal(1, "CoreMark stats reset left a transaction or a ready signal live");
        end
    endtask

    task clear_expected_banks;
        integer i;
        begin
            for (i = 0; i < 16; i = i + 1) begin
                expected_start[i] = 0;
                expected_stop[i] = 0;
            end
        end
    endtask

    initial begin
        set_live(32'h01000000);
        clear_expected_banks;
        repeat (3) @(negedge clk);
        rst_n = 1;
        read_word(8, FLAGS, 0);
        read_word(12, I_GEOMETRY, 0);
        read_word(16, D_GEOMETRY, 0);
        read_bank(0);
        read_bank(1);

        adjacent_start_stop;
        read_bank(0);
        read_bank(1);
        // A new START bank cannot destroy the previous STOP bank.
        set_live(32'h33000000);
        trigger_snapshot(0);
        read_bank(0);
        read_bank(1);
        blocked_stop_trigger;
        read_bank(0);
        read_bank(1);

        // Invalid and unaligned reads must not trigger either snapshot bank.
        read_word(1, 0, 2'b10);
        read_word(5, 0, 2'b10);
        read_word(9, 0, 2'b10);
        read_word(32'h14, 0, 2'b10);
        read_word(32'h3c, 0, 2'b10);
        read_word(32'h41, 0, 2'b10);
        read_word(32'h7e, 0, 2'b10);
        read_word(32'hbe, 0, 2'b10);
        read_word(32'hc0, 0, 2'b10);
        read_word(32'hfffffffc, 0, 2'b10);
        read_bank(0);
        read_bank(1);

        // Every implemented register remains read-only, including triggers.
        write_error(0, 0);
        write_error(4, 1);
        write_error(8, 2);
        write_error(12, 0);
        write_error(16, 1);
        for (k = 0; k < 16; k = k + 1) begin
            write_error(32'h40 + k * 4, k % 3);
            write_error(32'h80 + k * 4, (k + 1) % 3);
        end
        write_error(1, 2);
        write_error(32'h14, 0);
        write_error(32'hfffffffc, 1);
        read_bank(0);
        read_bank(1);

        // Reset a captured AW and a held R. The old AW must not pair with a
        // post-reset W, and both snapshot banks must return to zero.
        send_aw;
        @(negedge clk);
        araddr = BASE + 8;
        arvalid = 1;
        rready = 0;
        @(posedge clk);
        if (!arready) $fatal(1, "CoreMark stats reset setup AR failed");
        @(negedge clk);
        arvalid = 0;
        if (!rvalid) $fatal(1, "CoreMark stats reset setup lacked held R");
        rst_n = 0;
        assert_reset_state;
        repeat (3) @(negedge clk);
        rst_n = 1;
        clear_expected_banks;
        read_bank(0);
        read_bank(1);
        read_word(8, FLAGS, 0);
        read_word(12, I_GEOMETRY, 0);
        read_word(16, D_GEOMETRY, 0);
        send_w;
        repeat (3) @(negedge clk);
        if (bvalid) $fatal(1, "CoreMark stats retained pre-reset AW");
        send_aw;
        consume_write_error;

        // Reset must also discard a held B response.
        fork
            send_aw;
            send_w;
        join
        wait (bvalid);
        @(negedge clk);
        rst_n = 0;
        assert_reset_state;
        repeat (3) @(negedge clk);
        rst_n = 1;
        write_error(4, 1);
        read_bank(0);
        read_bank(1);

        done = 1;
        $display("COREMARK AXI STATS CASE PASS cache=%0d: independent banks, 64-bit counters, all 12 Cache fields, flags/geometry, AXI backpressure/errors/reset",
                 CACHE_ENABLE);
    end
endmodule

module axi_lite_coremark_stats_tb;
    reg clk = 0;
    reg test_pass = 0;
    wire off_done, on_done;
    always #5 clk = ~clk;
    axi_lite_coremark_stats_case #(
        .CACHE_ENABLE(0), .I_SETS(64), .D_SETS(128)
    ) cache_off (.clk(clk), .done(off_done));
    axi_lite_coremark_stats_case #(
        .CACHE_ENABLE(1), .I_SETS(32), .D_SETS(64)
    ) cache_on (.clk(clk), .done(on_done));
    initial begin
        wait (off_done && on_done);
        test_pass = 1;
        $display("COREMARK AXI STATS TESTS PASS");
        $stop;
    end
    initial begin
        #200000;
        $fatal(1, "CoreMark AXI statistics test timeout");
    end
endmodule
