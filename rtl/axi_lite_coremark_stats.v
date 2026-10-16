// Dedicated CoreMark AXI statistics: START and STOP are separate snapshot banks.
// Trigger reads capture all fields together at the AXI AR handshake; subsequent
// reads return the stored values, without resampling counters during printing.
// Schema 3 adds six 64-bit cycle-profile banks; all schema-2 offsets survive.
// perf_cycle_events is registered by the CPU: bit 0 work/other, 1 fetch wait,
// 2 external data-read wait, 3 external data-write wait, 4 local MMIO wait,
// 5 redirect recovery. Exactly one bit accompanies each counted CPU cycle.
// The event arrives one clock after cycle_count increments. Capturing NEXT
// profile counts aligns a START/STOP edge with that edge's cycle_count input.
// All writes return SLVERR. AW and W are accepted independently.
module axi_lite_coremark_stats #(
    parameter [31:0] BASE_ADDR = 32'h30000000,
    parameter integer ENABLE_ICACHE = 1, ENABLE_DCACHE = 1,
    parameter integer ENABLE_BRANCH_PRED = 0, BTB_ENTRIES = 64,
    parameter integer ICACHE_SETS = 64, ICACHE_LINE_WORDS = 4,
    parameter integer DCACHE_SETS = 64, DCACHE_LINE_WORDS = 4
) (
    input wire clk, rst_n,
    input wire [63:0] cycle_count, instret_count,
    input wire [5:0] perf_cycle_events,
    input wire [31:0] icache_access_count, icache_hit_count, icache_miss_count,
    input wire [31:0] icache_refill_word_count, icache_error_count,
    input wire [31:0] dcache_access_count, dcache_hit_count, dcache_miss_count,
    input wire [31:0] dcache_refill_word_count, dcache_error_count,
    input wire [31:0] dcache_write_count, dcache_bypass_count,
    input wire [31:0] bp_lookup_count, bp_hit_count, bp_taken_count,
    input wire [31:0] bp_resolved_count, bp_mispredict_count,
    input wire [31:0] bp_direction_error_count, bp_target_error_count,
    input wire [31:0] s_axi_awaddr,
    input wire [2:0] s_axi_awprot,
    input wire s_axi_awvalid,
    output wire s_axi_awready,
    input wire [31:0] s_axi_wdata,
    input wire [3:0] s_axi_wstrb,
    input wire s_axi_wvalid,
    output wire s_axi_wready,
    output reg [1:0] s_axi_bresp,
    output reg s_axi_bvalid,
    input wire s_axi_bready,
    input wire [31:0] s_axi_araddr,
    input wire [2:0] s_axi_arprot,
    input wire s_axi_arvalid,
    output wire s_axi_arready,
    output reg [31:0] s_axi_rdata,
    output reg [1:0] s_axi_rresp,
    output reg s_axi_rvalid,
    input wire s_axi_rready
);
    localparam [31:0] ID = 32'h434d4158;
    localparam [31:0] ENABLE_FLAGS =
        (ENABLE_ICACHE != 0 ? 32'h1 : 32'h0) |
        (ENABLE_DCACHE != 0 ? 32'h2 : 32'h0);
    localparam [31:0] I_GEOMETRY =
        (32'd2 << 24) | (ICACHE_SETS << 16) | (ICACHE_LINE_WORDS * 4);
    localparam [31:0] D_GEOMETRY =
        (32'd2 << 24) | (DCACHE_SETS << 16) | (DCACHE_LINE_WORDS * 4);
    localparam [31:0] PREDICTOR_CONFIG =
        (BTB_ENTRIES << 16) | (ENABLE_BRANCH_PRED != 0 ? 32'd1 : 32'd0);
    reg got_aw, got_w;
    reg [31:0] start_snapshot [0:15];
    reg [31:0] stop_snapshot [0:15];
    reg [31:0] bp_start_snapshot [0:6];
    reg [31:0] bp_stop_snapshot [0:6];
    reg [63:0] profile_count [0:5];
    reg [63:0] cycle_start_snapshot [0:5];
    reg [63:0] cycle_stop_snapshot [0:5];
    wire [63:0] profile_next [0:5];
    genvar profile_index;
    generate
        for (profile_index = 0; profile_index < 6; profile_index = profile_index + 1) begin : g_profile_next
            // Reuse this increment for both counting and same-edge snapshots.
            // The CPU supplies a registered event, keeping its control path
            // away from the wide counter increment and capture logic.
            assign profile_next[profile_index] = profile_count[profile_index] +
                (perf_cycle_events[profile_index] ? 64'd1 : 64'd0);
        end
    endgenerate
    wire [31:0] offset = s_axi_araddr - BASE_ADDR;
    integer index;

    assign s_axi_awready = rst_n && !got_aw && !s_axi_bvalid;
    assign s_axi_wready = rst_n && !got_w && !s_axi_bvalid;
    assign s_axi_arready = rst_n && (!s_axi_rvalid || s_axi_rready);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            got_aw <= 0;
            got_w <= 0;
            s_axi_bvalid <= 0;
            s_axi_bresp <= 0;
            s_axi_rvalid <= 0;
            s_axi_rdata <= 0;
            s_axi_rresp <= 0;
            for (index = 0; index < 16; index = index + 1) begin
                start_snapshot[index] <= 0;
                stop_snapshot[index] <= 0;
            end
            for (index = 0; index < 7; index = index + 1) begin
                bp_start_snapshot[index] <= 0;
                bp_stop_snapshot[index] <= 0;
            end
            for (index = 0; index < 6; index = index + 1) begin
                profile_count[index] <= 0;
                cycle_start_snapshot[index] <= 0;
                cycle_stop_snapshot[index] <= 0;
            end
        end else begin
            for (index = 0; index < 6; index = index + 1)
                profile_count[index] <= profile_next[index];
            if (s_axi_awvalid && s_axi_awready) got_aw <= 1;
            if (s_axi_wvalid && s_axi_wready) got_w <= 1;
            if (got_aw && got_w && !s_axi_bvalid) begin
                got_aw <= 0;
                got_w <= 0;
                s_axi_bvalid <= 1;
                s_axi_bresp <= 2'b10;
            end
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 0;
            if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 0;

            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid <= 1;
                s_axi_rresp <= 0;
                case (offset)
                    32'h00: begin
                        s_axi_rdata <= ID;
                        start_snapshot[0] <= cycle_count[31:0];
                        start_snapshot[1] <= cycle_count[63:32];
                        start_snapshot[2] <= instret_count[31:0];
                        start_snapshot[3] <= instret_count[63:32];
                        start_snapshot[4] <= icache_access_count;
                        start_snapshot[5] <= icache_hit_count;
                        start_snapshot[6] <= icache_miss_count;
                        start_snapshot[7] <= icache_refill_word_count;
                        start_snapshot[8] <= icache_error_count;
                        start_snapshot[9] <= dcache_access_count;
                        start_snapshot[10] <= dcache_hit_count;
                        start_snapshot[11] <= dcache_miss_count;
                        start_snapshot[12] <= dcache_refill_word_count;
                        start_snapshot[13] <= dcache_error_count;
                        start_snapshot[14] <= dcache_write_count;
                        start_snapshot[15] <= dcache_bypass_count;
                        bp_start_snapshot[0] <= ENABLE_BRANCH_PRED != 0 ? bp_lookup_count : 32'd0;
                        bp_start_snapshot[1] <= ENABLE_BRANCH_PRED != 0 ? bp_hit_count : 32'd0;
                        bp_start_snapshot[2] <= ENABLE_BRANCH_PRED != 0 ? bp_taken_count : 32'd0;
                        bp_start_snapshot[3] <= ENABLE_BRANCH_PRED != 0 ? bp_resolved_count : 32'd0;
                        bp_start_snapshot[4] <= ENABLE_BRANCH_PRED != 0 ? bp_mispredict_count : 32'd0;
                        bp_start_snapshot[5] <= ENABLE_BRANCH_PRED != 0 ? bp_direction_error_count : 32'd0;
                        bp_start_snapshot[6] <= ENABLE_BRANCH_PRED != 0 ? bp_target_error_count : 32'd0;
                        for (index = 0; index < 6; index = index + 1)
                            cycle_start_snapshot[index] <= profile_next[index];
                    end
                    32'h04: begin
                        s_axi_rdata <= ID;
                        stop_snapshot[0] <= cycle_count[31:0];
                        stop_snapshot[1] <= cycle_count[63:32];
                        stop_snapshot[2] <= instret_count[31:0];
                        stop_snapshot[3] <= instret_count[63:32];
                        stop_snapshot[4] <= icache_access_count;
                        stop_snapshot[5] <= icache_hit_count;
                        stop_snapshot[6] <= icache_miss_count;
                        stop_snapshot[7] <= icache_refill_word_count;
                        stop_snapshot[8] <= icache_error_count;
                        stop_snapshot[9] <= dcache_access_count;
                        stop_snapshot[10] <= dcache_hit_count;
                        stop_snapshot[11] <= dcache_miss_count;
                        stop_snapshot[12] <= dcache_refill_word_count;
                        stop_snapshot[13] <= dcache_error_count;
                        stop_snapshot[14] <= dcache_write_count;
                        stop_snapshot[15] <= dcache_bypass_count;
                        bp_stop_snapshot[0] <= ENABLE_BRANCH_PRED != 0 ? bp_lookup_count : 32'd0;
                        bp_stop_snapshot[1] <= ENABLE_BRANCH_PRED != 0 ? bp_hit_count : 32'd0;
                        bp_stop_snapshot[2] <= ENABLE_BRANCH_PRED != 0 ? bp_taken_count : 32'd0;
                        bp_stop_snapshot[3] <= ENABLE_BRANCH_PRED != 0 ? bp_resolved_count : 32'd0;
                        bp_stop_snapshot[4] <= ENABLE_BRANCH_PRED != 0 ? bp_mispredict_count : 32'd0;
                        bp_stop_snapshot[5] <= ENABLE_BRANCH_PRED != 0 ? bp_direction_error_count : 32'd0;
                        bp_stop_snapshot[6] <= ENABLE_BRANCH_PRED != 0 ? bp_target_error_count : 32'd0;
                        for (index = 0; index < 6; index = index + 1)
                            cycle_stop_snapshot[index] <= profile_next[index];
                    end
                    32'h08: s_axi_rdata <= ENABLE_FLAGS;
                    32'h0c: s_axi_rdata <= I_GEOMETRY;
                    32'h10: s_axi_rdata <= D_GEOMETRY;
                    32'h14: s_axi_rdata <= PREDICTOR_CONFIG;
                    32'h18: s_axi_rdata <= 32'd3;
                    32'h40: s_axi_rdata <= start_snapshot[0];
                    32'h44: s_axi_rdata <= start_snapshot[1];
                    32'h48: s_axi_rdata <= start_snapshot[2];
                    32'h4c: s_axi_rdata <= start_snapshot[3];
                    32'h50: s_axi_rdata <= start_snapshot[4];
                    32'h54: s_axi_rdata <= start_snapshot[5];
                    32'h58: s_axi_rdata <= start_snapshot[6];
                    32'h5c: s_axi_rdata <= start_snapshot[7];
                    32'h60: s_axi_rdata <= start_snapshot[8];
                    32'h64: s_axi_rdata <= start_snapshot[9];
                    32'h68: s_axi_rdata <= start_snapshot[10];
                    32'h6c: s_axi_rdata <= start_snapshot[11];
                    32'h70: s_axi_rdata <= start_snapshot[12];
                    32'h74: s_axi_rdata <= start_snapshot[13];
                    32'h78: s_axi_rdata <= start_snapshot[14];
                    32'h7c: s_axi_rdata <= start_snapshot[15];
                    32'h80: s_axi_rdata <= stop_snapshot[0];
                    32'h84: s_axi_rdata <= stop_snapshot[1];
                    32'h88: s_axi_rdata <= stop_snapshot[2];
                    32'h8c: s_axi_rdata <= stop_snapshot[3];
                    32'h90: s_axi_rdata <= stop_snapshot[4];
                    32'h94: s_axi_rdata <= stop_snapshot[5];
                    32'h98: s_axi_rdata <= stop_snapshot[6];
                    32'h9c: s_axi_rdata <= stop_snapshot[7];
                    32'ha0: s_axi_rdata <= stop_snapshot[8];
                    32'ha4: s_axi_rdata <= stop_snapshot[9];
                    32'ha8: s_axi_rdata <= stop_snapshot[10];
                    32'hac: s_axi_rdata <= stop_snapshot[11];
                    32'hb0: s_axi_rdata <= stop_snapshot[12];
                    32'hb4: s_axi_rdata <= stop_snapshot[13];
                    32'hb8: s_axi_rdata <= stop_snapshot[14];
                    32'hbc: s_axi_rdata <= stop_snapshot[15];
                    32'hc0: s_axi_rdata <= bp_start_snapshot[0];
                    32'hc4: s_axi_rdata <= bp_start_snapshot[1];
                    32'hc8: s_axi_rdata <= bp_start_snapshot[2];
                    32'hcc: s_axi_rdata <= bp_start_snapshot[3];
                    32'hd0: s_axi_rdata <= bp_start_snapshot[4];
                    32'hd4: s_axi_rdata <= bp_start_snapshot[5];
                    32'hd8: s_axi_rdata <= bp_start_snapshot[6];
                    32'he0: s_axi_rdata <= bp_stop_snapshot[0];
                    32'he4: s_axi_rdata <= bp_stop_snapshot[1];
                    32'he8: s_axi_rdata <= bp_stop_snapshot[2];
                    32'hec: s_axi_rdata <= bp_stop_snapshot[3];
                    32'hf0: s_axi_rdata <= bp_stop_snapshot[4];
                    32'hf4: s_axi_rdata <= bp_stop_snapshot[5];
                    32'hf8: s_axi_rdata <= bp_stop_snapshot[6];
                    32'h100: s_axi_rdata <= cycle_start_snapshot[0][31:0];
                    32'h104: s_axi_rdata <= cycle_start_snapshot[0][63:32];
                    32'h108: s_axi_rdata <= cycle_start_snapshot[1][31:0];
                    32'h10c: s_axi_rdata <= cycle_start_snapshot[1][63:32];
                    32'h110: s_axi_rdata <= cycle_start_snapshot[2][31:0];
                    32'h114: s_axi_rdata <= cycle_start_snapshot[2][63:32];
                    32'h118: s_axi_rdata <= cycle_start_snapshot[3][31:0];
                    32'h11c: s_axi_rdata <= cycle_start_snapshot[3][63:32];
                    32'h120: s_axi_rdata <= cycle_start_snapshot[4][31:0];
                    32'h124: s_axi_rdata <= cycle_start_snapshot[4][63:32];
                    32'h128: s_axi_rdata <= cycle_start_snapshot[5][31:0];
                    32'h12c: s_axi_rdata <= cycle_start_snapshot[5][63:32];
                    32'h140: s_axi_rdata <= cycle_stop_snapshot[0][31:0];
                    32'h144: s_axi_rdata <= cycle_stop_snapshot[0][63:32];
                    32'h148: s_axi_rdata <= cycle_stop_snapshot[1][31:0];
                    32'h14c: s_axi_rdata <= cycle_stop_snapshot[1][63:32];
                    32'h150: s_axi_rdata <= cycle_stop_snapshot[2][31:0];
                    32'h154: s_axi_rdata <= cycle_stop_snapshot[2][63:32];
                    32'h158: s_axi_rdata <= cycle_stop_snapshot[3][31:0];
                    32'h15c: s_axi_rdata <= cycle_stop_snapshot[3][63:32];
                    32'h160: s_axi_rdata <= cycle_stop_snapshot[4][31:0];
                    32'h164: s_axi_rdata <= cycle_stop_snapshot[4][63:32];
                    32'h168: s_axi_rdata <= cycle_stop_snapshot[5][31:0];
                    32'h16c: s_axi_rdata <= cycle_stop_snapshot[5][63:32];
                    default: begin
                        s_axi_rdata <= 0;
                        s_axi_rresp <= 2'b10;
                    end
                endcase
            end
        end
    end
    // synthesis translate_off
    initial begin
        if (BASE_ADDR[1:0] != 0)
            $fatal(1, "CoreMark statistics base must be word aligned");
        if ((ENABLE_ICACHE != 0 && ENABLE_ICACHE != 1) ||
            (ENABLE_DCACHE != 0 && ENABLE_DCACHE != 1) ||
            (ENABLE_BRANCH_PRED != 0 && ENABLE_BRANCH_PRED != 1))
            $fatal(1, "CoreMark statistics Cache/predictor switches must be zero or one");
        if (BTB_ENTRIES < 1 || BTB_ENTRIES > 1024 ||
            (BTB_ENTRIES & (BTB_ENTRIES - 1)) != 0)
            $fatal(1, "CoreMark statistics require power-of-two BTB_ENTRIES in 1..1024");
    end
    // synthesis translate_on
endmodule
