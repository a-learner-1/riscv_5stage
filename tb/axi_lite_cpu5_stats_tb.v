`timescale 1ns/1ps

// Statistics unit self-check: synthetic registered cycle events are intentional.
// Real CPU classification and event/cycle alignment require the CPU integration test.
module axi_lite_cpu5_stats_case #(
    parameter integer CASE_ID=0,BACKEND_ID=0,
    parameter [31:0] BASE=32'h30000000,
    parameter integer CACHE_ENABLE = 1,
    parameter integer BP_ENABLE = 0,
    parameter integer BTB_ENTRIES = 64,
    parameter integer I_SETS = 32,
    parameter integer D_SETS = 64
) (
    input wire clk,
    output reg done = 0
);
    localparam [31:0] SNAP_ID = 32'h434d4158;
    localparam [31:0] FLAGS = CACHE_ENABLE ? 32'd3 : 32'd0;
    localparam [31:0] BP_CONFIG = (BTB_ENTRIES << 16) | BP_ENABLE;
    localparam [31:0] I_GEOMETRY = (32'd2 << 24) | (I_SETS << 16) | 32'd16;
    localparam [31:0] D_GEOMETRY = (32'd2 << 24) | (D_SETS << 16) | 32'd16;

    reg rst_n = 0;
    // Original 16 words retain their addresses. Seven BP words use the new
    // START c0..d8 / STOP e0..f8 ranges, captured by the same trigger edge.
    reg [31:0] live [0:22];
    reg [31:0] expected_start [0:42];
    reg [31:0] expected_stop [0:42];
    reg [9:0] perf_cycle_events = 0;
    reg profile_drive_enable = 1;
    integer profile_step = 0;
    reg [63:0] model_profile [0:9];
    integer profile_i;
    reg [31:0] awaddr = 0, wdata = 0, araddr = 0;
    reg [3:0] wstrb = 0;
    reg awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    wire awready, wready, bvalid, arready, rvalid;
    wire [1:0] bresp, rresp;
    wire [31:0] rdata;
    integer k;

    // Include silent pre-start-like cycles and all ten exclusive categories.
    // Nonblocking drive changes after the negative edge; capture checks sample
    // the value actually accepted at the following positive edge.
    always @(negedge clk) begin
        if (!rst_n) begin
            perf_cycle_events <= 0;
            profile_step <= 0;
        end else if (profile_drive_enable) begin
            perf_cycle_events <= profile_step == 10 ? 10'd0 : (10'b0000000001 << profile_step);
            profile_step <= profile_step == 10 ? 0 : profile_step + 1;
        end
    end

    // Independent software-style scoreboard, including trigger-edge events.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (profile_i = 0; profile_i < 10; profile_i = profile_i + 1)
                model_profile[profile_i] <= 0;
        end else begin
            if (arvalid && arready && araddr == BASE) remember_bank(0);
            if (arvalid && arready && araddr == BASE + 4) remember_bank(1);
            for (profile_i = 0; profile_i < 10; profile_i = profile_i + 1)
                if (perf_cycle_events[profile_i])
                    model_profile[profile_i] <= model_profile[profile_i] + 1;
        end
    end

    axi_lite_cpu5_stats #(
        .BASE_ADDR(BASE),.DATA_BACKEND_ID(BACKEND_ID),.ENABLE_ICACHE(CACHE_ENABLE), .ENABLE_DCACHE(CACHE_ENABLE),
        .ENABLE_BRANCH_PRED(BP_ENABLE), .BTB_ENTRIES(BTB_ENTRIES),
        .ICACHE_SETS(I_SETS), .DCACHE_SETS(D_SETS)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .cycle_count({live[1], live[0]}), .instret_count({live[3], live[2]}),
        .perf_cycle_events(perf_cycle_events),
        .icache_access_count(live[4]), .icache_hit_count(live[5]),
        .icache_miss_count(live[6]), .icache_refill_word_count(live[7]),
        .icache_error_count(live[8]),
        .dcache_access_count(live[9]), .dcache_hit_count(live[10]),
        .dcache_miss_count(live[11]), .dcache_refill_word_count(live[12]),
        .dcache_error_count(live[13]), .dcache_write_count(live[14]),
        .dcache_bypass_count(live[15]),
        .bp_lookup_count(live[16]), .bp_hit_count(live[17]),
        .bp_taken_count(live[18]), .bp_resolved_count(live[19]),
        .bp_mispredict_count(live[20]), .bp_direction_error_count(live[21]),
        .bp_target_error_count(live[22]),
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

    integer reads=0,writes=0,start_triggers=0,stop_triggers=0,edge_checks=0,summary_fd,trace_fd;
    integer monitor_i,cycles=0,carry_checks=0,wrap_checks=0;
    initial begin
        trace_fd=$fopen($sformatf("build/cpu5_s16_stats_endpoint/case%0d_edges.csv",CASE_ID),"w");
        $fwrite(trace_fd,"cycle,arvalid,arready,araddr,rvalid,rready,rdata,rresp,awvalid,awready,wvalid,wready,bvalid,bready,bresp,events\n");
    end
    always @(posedge clk)if(rst_n&&!done)begin
        cycles=cycles+1;
        for(monitor_i=0;monitor_i<10;monitor_i=monitor_i+1)begin
            if(dut.profile_count[monitor_i]!==model_profile[monitor_i])$fatal(1,"CPU5 Stats profile count oracle index=%0d",monitor_i);
            edge_checks=edge_checks+1;
        end
        if(arvalid&&arready)begin
            reads=reads+1;if(araddr==BASE)start_triggers=start_triggers+1;if(araddr==BASE+4)stop_triggers=stop_triggers+1;
        end
        if(wvalid&&wready)writes=writes+1;
        $fwrite(trace_fd,"%0d,%0d,%0d,%08h,%0d,%0d,%08h,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%03h\n",cycles,arvalid,arready,araddr,rvalid,rready,rdata,rresp,awvalid,awready,wvalid,wready,bvalid,bready,bresp,perf_cycle_events);
    end
    // This offset oracle is intentionally explicit and independent of RTL decode.
    function [31:0] profile_word_offset(input integer stop_bank,input integer word_index);
        begin
            if(word_index<12)profile_word_offset=(stop_bank?32'h140:32'h100)+word_index*4;
            else profile_word_offset=(stop_bank?32'h1c0:32'h180)+(word_index-12)*4;
        end
    endfunction

    task set_live(input [31:0] seed);
        integer i;
        begin
            for (i = 0; i < 23; i = i + 1)
                live[i] = seed + i * 32'h01020304;
        end
    endtask

    task advance_live;
        integer i;
        begin
            for (i = 0; i < 23; i = i + 1)
                live[i] = live[i] + 32'h00100001 + i;
        end
    endtask

    task remember_bank(input integer stop_bank);
        integer i;
        reg [63:0] value;
        begin
            for (i = 0; i < 23; i = i + 1) begin
                // Nonzero synthetic BP inputs intentionally remain live when
                // disabled: the device itself must gate its snapshot banks.
                if (stop_bank) expected_stop[i] = (i >= 16 && !BP_ENABLE) ? 0 : live[i];
                else expected_start[i] = (i >= 16 && !BP_ENABLE) ? 0 : live[i];
            end
            for (i = 0; i < 10; i = i + 1) begin
                value = model_profile[i];
                if (perf_cycle_events[i]) value = value + 1;
                if (stop_bank) begin
                    expected_stop[23 + i * 2] = value[31:0];
                    expected_stop[24 + i * 2] = value[63:32];
                end else begin
                    expected_start[23 + i * 2] = value[31:0];
                    expected_start[24 + i * 2] = value[63:32];
                end
            end
        end
    endtask

    task check_response(input [31:0] value, input [1:0] response);
        begin
            if (!rvalid || rdata !== value || rresp !== response)
                $fatal(1, "CPU5 Stats cache=%0d BP=%0d AR=%h data=%h expected=%h resp=%b expected=%b",
                       CACHE_ENABLE, BP_ENABLE, araddr, rdata, value, rresp, response);
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
                if (arready) $fatal(1, "CPU5 Stats accepted AR over a stalled R");
                advance_live;
                @(negedge clk);
            end
            check_response(value, response);
            rready = 1;
            @(posedge clk);
            @(negedge clk);
            rready = 0;
            if (rvalid) $fatal(1, "CPU5 Stats R response was not consumed");
        end
    endtask

    task trigger_snapshot(input integer stop_bank);
        begin
            // Inputs remain unchanged until the request handshake has occurred.
            read_word(stop_bank ? 32'h04 : 32'h00, SNAP_ID, 2'b00);
        end
    endtask

    task read_bank(input integer stop_bank);
        integer i;
        begin
            for (i = 0; i < 16; i = i + 1)
                read_word((stop_bank ? 32'h80 : 32'h40) + i * 4,
                          stop_bank ? expected_stop[i] : expected_start[i], 2'b00);
            for (i = 16; i < 23; i = i + 1)
                read_word((stop_bank ? 32'he0 : 32'hc0) + (i - 16) * 4,
                          stop_bank ? expected_stop[i] : expected_start[i], 2'b00);
            for (i = 23; i < 43; i = i + 1)
                read_word(profile_word_offset(stop_bank,i-23),
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
            araddr = BASE;
            arvalid = 1;
            rready = 1;
            @(posedge clk);
            if (!arready) $fatal(1, "CPU5 Stats START AR was unexpectedly blocked");
            @(negedge clk);
            check_response(SNAP_ID, 2'b00);
            set_live(32'h22000000);
            live[0] = 32'h00000003;
            live[1] = 32'h12345679;
            live[2] = 32'h00000005;
            live[3] = 32'h87654322;
            araddr = BASE + 4;
            @(posedge clk);
            if (!arready || !rvalid)
                $fatal(1, "CPU5 Stats failed simultaneous R consume and STOP AR");
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
            if (!arready) $fatal(1, "CPU5 Stats flag read was unexpectedly blocked");
            @(negedge clk);
            araddr = BASE + 4;
            repeat (4) begin
                check_response(FLAGS, 2'b00);
                if (arready) $fatal(1, "CPU5 Stats STOP AR sampled before ready");
                advance_live;
                @(negedge clk);
            end
            rready = 1;
            @(posedge clk);
            if (!arready) $fatal(1, "CPU5 Stats STOP AR remained blocked after R ready");
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
                    $fatal(1, "CPU5 Stats lost held SLVERR or accepted another write");
            end
            bready = 1;
            @(posedge clk);
            @(negedge clk);
            bready = 0;
            if (bvalid) $fatal(1, "CPU5 Stats B response was not consumed");
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
                if (bvalid) $fatal(1, "CPU5 Stats responded without W");
                send_w;
            end else if (order == 1) begin
                send_w;
                repeat (3) @(negedge clk);
                if (bvalid) $fatal(1, "CPU5 Stats responded without AW");
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


    // Deliberate bounded counter seeds exercise the actual 64-bit adder;
    // no force/deposit or replacement of response logic is used.
    task profile_carry_and_rollover;
        reg [63:0] start_value,stop_value,seed;
        integer field;
        begin
            @(negedge clk);profile_drive_enable=0;#1;
            for(field=0;field<10;field=field+1)begin
                @(negedge clk);
                seed=64'h12345678ffffffff+(64'h100000000*field);
                perf_cycle_events=10'b1<<field;
                dut.profile_count[field]=seed;model_profile[field]=seed;
                araddr=BASE;arvalid=1;rready=1;
                @(posedge clk);if(!arready)$fatal(1,"CPU5 Stats carry START blocked");
                @(negedge clk);check_response(SNAP_ID,0);
                start_value={expected_start[24+field*2],expected_start[23+field*2]};
                if(start_value!==seed+64'd1||dut.cycle_start_snapshot[field]!==start_value)
                    $fatal(1,"CPU5 Stats low-word carry trigger alignment");
                araddr=BASE+4;
                @(posedge clk);if(!arready||!rvalid)$fatal(1,"CPU5 Stats adjacent STOP blocked");
                @(negedge clk);check_response(SNAP_ID,0);
                stop_value={expected_stop[24+field*2],expected_stop[23+field*2]};
                if(stop_value-start_value!==64'd1||dut.cycle_stop_snapshot[field]!==stop_value)
                    $fatal(1,"CPU5 Stats adjacent START STOP event lost");
                carry_checks=carry_checks+1;arvalid=0;rready=1;
                @(posedge clk);@(negedge clk);rready=0;
                dut.profile_count[field]=64'hffffffffffffffff;model_profile[field]=64'hffffffffffffffff;
                araddr=BASE;arvalid=1;
                @(posedge clk);if(!arready)$fatal(1,"CPU5 Stats rollover START blocked");
                @(negedge clk);arvalid=0;check_response(SNAP_ID,0);
                if(dut.cycle_start_snapshot[field]!==0||expected_start[23+field*2]!==0||expected_start[24+field*2]!==0)
                    $fatal(1,"CPU5 Stats full-width rollover trigger alignment");
                repeat(4)begin
                    if(dut.cycle_start_snapshot[field]!==0)$fatal(1,"CPU5 Stats bank changed under R backpressure");
                    @(negedge clk);
                end
                wrap_checks=wrap_checks+1;rready=1;@(posedge clk);@(negedge clk);rready=0;perf_cycle_events=0;
                read_bank(0);read_bank(1);
            end
            profile_drive_enable=1;
        end
    endtask

    task assert_reset_state;
        begin
            #1;
            if (bvalid || rvalid || awready || wready || arready)
                $fatal(1, "CPU5 Stats reset left a transaction or a ready signal live");
            for (k = 0; k < 10; k = k + 1)
                if (dut.profile_count[k] !== 0)
                    $fatal(1, "CPU5 Stats reset retained cycle profile index=%0d", k);
        end
    endtask

    task clear_expected_banks;
        integer i;
        begin
            for (i = 0; i < 43; i = i + 1) begin
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
        read_word(20, BP_CONFIG, 0);
        read_word(24, 32'd4, 0);
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
        read_word(32'h15, 0, 2'b10);
        read_word(32'h19, 0, 2'b10);
        read_word(32'h1c,BACKEND_ID,2'b00);
        read_word(32'h3c, 0, 2'b10);
        read_word(32'h41, 0, 2'b10);
        read_word(32'h7e, 0, 2'b10);
        read_word(32'hbe, 0, 2'b10);
        read_word(32'hc1, 0, 2'b10);
        read_word(32'hd9, 0, 2'b10);
        read_word(32'hdc, 0, 2'b10);
        read_word(32'he1, 0, 2'b10);
        read_word(32'hf9, 0, 2'b10);
        read_word(32'hfc, 0, 2'b10);
        read_word(32'h101, 0, 2'b10);
        read_word(32'h130, 0, 2'b10);
        read_word(32'h13c, 0, 2'b10);
        read_word(32'h141, 0, 2'b10);
        read_word(32'h170, 0, 2'b10);
        read_word(32'h1fc, 0, 2'b10);
        read_word(32'h134,0,2'b10);read_word(32'h138,0,2'b10);
        read_word(32'h174,0,2'b10);read_word(32'h178,0,2'b10);read_word(32'h17c,0,2'b10);
        read_word(32'h181,0,2'b10);read_word(32'h19d,0,2'b10);
        read_word(32'h1a0,0,2'b10);read_word(32'h1bc,0,2'b10);read_word(32'h1c1,0,2'b10);read_word(32'h1e0,0,2'b10);
        read_word(32'h200, 0, 2'b10);
        read_word(32'hfffffffc, 0, 2'b10);
        read_bank(0);
        read_bank(1);

        // Every implemented register remains read-only, including triggers.
        write_error(0, 0);
        write_error(4, 1);
        write_error(8, 2);
        write_error(12, 0);
        write_error(16, 1);
        write_error(20, 2);
        write_error(24, 0);
        for (k = 0; k < 16; k = k + 1) begin
            write_error(32'h40 + k * 4, k % 3);
            write_error(32'h80 + k * 4, (k + 1) % 3);
        end
        for (k = 0; k < 7; k = k + 1) begin
            write_error(32'hc0 + k * 4, k % 3);
            write_error(32'he0 + k * 4, (k + 1) % 3);
        end
        for (k = 0; k < 20; k = k + 1) begin
            write_error(profile_word_offset(0,k),k%3);
            write_error(profile_word_offset(1,k),(k+1)%3);
        end
        write_error(1, 2);
        write_error(32'h1c, 0);
        write_error(32'hfffffffc, 1);
        read_bank(0);
        read_bank(1);

        profile_carry_and_rollover;

        // Reset a captured AW and a held R. The old AW must not pair with a
        // post-reset W, and both snapshot banks must return to zero.
        send_aw;
        @(negedge clk);
        araddr = BASE + 8;
        arvalid = 1;
        rready = 0;
        @(posedge clk);
        if (!arready) $fatal(1, "CPU5 Stats reset setup AR failed");
        @(negedge clk);
        arvalid = 0;
        if (!rvalid) $fatal(1, "CPU5 Stats reset setup lacked held R");
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
        read_word(20, BP_CONFIG, 0);
        read_word(24, 32'd4, 0);
        send_w;
        repeat (3) @(negedge clk);
        if (bvalid) $fatal(1, "CPU5 Stats retained pre-reset AW");
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

        if(carry_checks!=10||wrap_checks!=10||start_triggers<=1||stop_triggers<=0)$fatal(1,"CPU5 Stats incomplete unit coverage");
        summary_fd=$fopen($sformatf("build/cpu5_s16_stats_endpoint/case%0d_summary.json",CASE_ID),"w");
        $fwrite(summary_fd,"{\"status\":\"PASS\",\"case\":%0d,\"cache\":%0d,\"bp\":%0d,\"reads\":%0d,\"writes\":%0d,\"start_triggers\":%0d,\"stop_triggers\":%0d,\"carry_checks\":%0d,\"wrap_checks\":%0d,\"edge_checks\":%0d}\n",CASE_ID,CACHE_ENABLE,BP_ENABLE,reads,writes,start_triggers,stop_triggers,carry_checks,wrap_checks,edge_checks);
        $fclose(summary_fd);$fclose(trace_fd);done = 1;
        $display("CPU5 AXI STATS CASE PASS cache=%0d BP=%0d: same-edge 43-field snapshots, ten 64-bit profiles/carry/rollover, disabled BP gating, schema/config, AXI backpressure/errors/reset",
                 CACHE_ENABLE, BP_ENABLE);
    end
endmodule

module axi_lite_cpu5_stats_tb;
    reg clk = 0;
    reg test_pass = 0;
    wire off_done, on_done, btb_done;
    always #5 clk = ~clk;
    axi_lite_cpu5_stats_case #(
        .CASE_ID(0),.CACHE_ENABLE(0), .I_SETS(64), .D_SETS(128)
    ) cache_off (.clk(clk), .done(off_done));
    axi_lite_cpu5_stats_case #(
        .CASE_ID(1),.CACHE_ENABLE(1), .I_SETS(32), .D_SETS(64)
    ) cache_on (.clk(clk), .done(on_done));
    axi_lite_cpu5_stats_case #(
        .CASE_ID(2),.BACKEND_ID(1),.CACHE_ENABLE(1), .BP_ENABLE(1), .BTB_ENTRIES(64), .I_SETS(64), .D_SETS(32)
    ) cache_on_btb (.clk(clk), .done(btb_done));
    initial begin
        wait (off_done && on_done && btb_done);
        test_pass = 1;
        $display("CPU5 AXI STATS TESTS PASS");
        $stop;
    end
    initial begin
        #200000;
        $fatal(1, "CoreMark AXI statistics test timeout");
    end
endmodule

module cpu5_stats_base_guard_tb;
    reg clk=0;wire done;always #5 clk=~clk;
    axi_lite_cpu5_stats_case #(.BASE(32'h30000001)) u(clk,done);
endmodule
module cpu5_stats_boolean_guard_tb;
    reg clk=0;wire done;always #5 clk=~clk;
    axi_lite_cpu5_stats_case #(.CACHE_ENABLE(2)) u(clk,done);
endmodule

// Prove all sixteen new words remain SLVERR on the unchanged old schema3.
module cpu5_stats_legacy_holes_tb;
    reg clk=0,rst_n=0;always #5 clk=~clk;
    localparam [31:0] BASE=32'h30000000;
    reg [31:0] live[0:22];reg [5:0] perf_cycle_events=0;
    reg [31:0] awaddr=0,wdata=0,araddr=0;reg [3:0] wstrb=0;
    reg awvalid=0,wvalid=0,bready=0,arvalid=0,rready=0;
    wire awready,wready,bvalid,arready,rvalid;wire [31:0] rdata;wire [1:0] bresp,rresp;
    integer i,bank,word,checks=0;reg test_pass=0;reg [31:0] offset;
    axi_lite_coremark_stats dut (
        .clk(clk), .rst_n(rst_n),
        .cycle_count({live[1], live[0]}), .instret_count({live[3], live[2]}),
        .perf_cycle_events(perf_cycle_events),
        .icache_access_count(live[4]), .icache_hit_count(live[5]),
        .icache_miss_count(live[6]), .icache_refill_word_count(live[7]),
        .icache_error_count(live[8]),
        .dcache_access_count(live[9]), .dcache_hit_count(live[10]),
        .dcache_miss_count(live[11]), .dcache_refill_word_count(live[12]),
        .dcache_error_count(live[13]), .dcache_write_count(live[14]),
        .dcache_bypass_count(live[15]),
        .bp_lookup_count(live[16]), .bp_hit_count(live[17]),
        .bp_taken_count(live[18]), .bp_resolved_count(live[19]),
        .bp_mispredict_count(live[20]), .bp_direction_error_count(live[21]),
        .bp_target_error_count(live[22]),
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
    initial begin
        for(i=0;i<23;i=i+1)live[i]=0;
        repeat(3)@(negedge clk);rst_n=1;
        for(bank=0;bank<2;bank=bank+1)begin
            for(word=0;word<8;word=word+1)begin
                @(negedge clk);offset=(bank?32'h1c0:32'h180)+word*4;araddr=BASE+offset;arvalid=1;rready=0;
                @(posedge clk);if(!arready)$fatal(1,"CPU5 legacy reserved setup blocked");
                @(negedge clk);arvalid=0;
                if(!rvalid||rdata!==0||rresp!==2'b10)$fatal(1,"CPU5 legacy new-word reserved SLVERR offset=%h",offset);
                rready=1;checks=checks+1;@(posedge clk);@(negedge clk);rready=0;
            end
        end
        test_pass=1;$display("CPU5 LEGACY RESERVED WORDS PASS checks=%0d",checks);$stop;
    end
    initial begin #50000;$fatal(1,"CPU5 legacy reserved probe timeout");end
endmodule
