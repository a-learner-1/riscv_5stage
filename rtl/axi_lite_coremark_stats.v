// Dedicated CoreMark AXI statistics: START and STOP are separate snapshot banks.
// Trigger reads capture all fields together at the AXI AR handshake; subsequent
// reads return the stored values, without resampling counters during printing.
// All writes return SLVERR. AW and W are accepted independently.
module axi_lite_coremark_stats #(
    parameter [31:0] BASE_ADDR = 32'h30000000,
    parameter integer ENABLE_ICACHE = 1, ENABLE_DCACHE = 1,
    parameter integer ICACHE_SETS = 64, ICACHE_LINE_WORDS = 4,
    parameter integer DCACHE_SETS = 64, DCACHE_LINE_WORDS = 4
) (
    input wire clk, rst_n,
    input wire [63:0] cycle_count, instret_count,
    input wire [31:0] icache_access_count, icache_hit_count, icache_miss_count,
    input wire [31:0] icache_refill_word_count, icache_error_count,
    input wire [31:0] dcache_access_count, dcache_hit_count, dcache_miss_count,
    input wire [31:0] dcache_refill_word_count, dcache_error_count,
    input wire [31:0] dcache_write_count, dcache_bypass_count,
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
    reg got_aw, got_w;
    reg [31:0] start_snapshot [0:15];
    reg [31:0] stop_snapshot [0:15];
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
        end else begin
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
                    end
                    32'h08: s_axi_rdata <= ENABLE_FLAGS;
                    32'h0c: s_axi_rdata <= I_GEOMETRY;
                    32'h10: s_axi_rdata <= D_GEOMETRY;
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
            (ENABLE_DCACHE != 0 && ENABLE_DCACHE != 1))
            $fatal(1, "CoreMark statistics Cache switches must be zero or one");
    end
    // synthesis translate_on
endmodule
