// Read ID to snapshot all counters together. Later reads return that snapshot,
// so executing the sampling code cannot make access/hit/miss inconsistent.
// Read-only AXI4-Lite; AW and W are collected independently, writes SLVERR.
module axi_lite_icache_stats #(
    parameter [31:0] BASE_ADDR=32'h30000000,
    parameter integer SETS=64, LINE_WORDS=4
) (
    input wire clk,rst_n,
    input wire [31:0] access_count,hit_count,miss_count,refill_word_count,error_count,
    input wire [31:0] s_axi_awaddr, input wire [2:0] s_axi_awprot,
    input wire s_axi_awvalid, output wire s_axi_awready,
    input wire [31:0] s_axi_wdata, input wire [3:0] s_axi_wstrb,
    input wire s_axi_wvalid, output wire s_axi_wready,
    output reg [1:0] s_axi_bresp, output reg s_axi_bvalid, input wire s_axi_bready,
    input wire [31:0] s_axi_araddr, input wire [2:0] s_axi_arprot,
    input wire s_axi_arvalid, output wire s_axi_arready,
    output reg [31:0] s_axi_rdata, output reg [1:0] s_axi_rresp,
    output reg s_axi_rvalid, input wire s_axi_rready
);
    localparam [31:0] GEOMETRY=(32'd2<<24)|(SETS<<16)|(LINE_WORDS*4);
    reg got_aw,got_w;
    reg [31:0] snap_access,snap_hit,snap_miss,snap_words,snap_error;
    wire [31:0] offset=s_axi_araddr-BASE_ADDR;
    assign s_axi_awready=rst_n && !got_aw && !s_axi_bvalid;
    assign s_axi_wready=rst_n && !got_w && !s_axi_bvalid;
    assign s_axi_arready=rst_n && (!s_axi_rvalid || s_axi_rready);
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            got_aw<=0;got_w<=0;s_axi_bvalid<=0;s_axi_bresp<=0;
            s_axi_rvalid<=0;s_axi_rdata<=0;s_axi_rresp<=0;
            snap_access<=0;snap_hit<=0;snap_miss<=0;snap_words<=0;snap_error<=0;
        end else begin
            if(s_axi_awvalid && s_axi_awready) got_aw<=1;
            if(s_axi_wvalid && s_axi_wready) got_w<=1;
            if(got_aw && got_w && !s_axi_bvalid) begin
                got_aw<=0;got_w<=0;s_axi_bvalid<=1;s_axi_bresp<=2'b10;
            end
            if(s_axi_bvalid && s_axi_bready) s_axi_bvalid<=0;
            if(s_axi_rvalid && s_axi_rready) s_axi_rvalid<=0;
            if(s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid<=1;s_axi_rresp<=0;
                case(offset)
                    32'h00: begin
                        s_axi_rdata<=32'h49433241;
                        snap_access<=access_count;snap_hit<=hit_count;snap_miss<=miss_count;
                        snap_words<=refill_word_count;snap_error<=error_count;
                    end
                    32'h04: s_axi_rdata<=GEOMETRY;
                    32'h08: s_axi_rdata<=snap_access;
                    32'h0c: s_axi_rdata<=snap_hit;
                    32'h10: s_axi_rdata<=snap_miss;
                    32'h14: s_axi_rdata<=snap_words;
                    32'h18: s_axi_rdata<=snap_error;
                    default: begin s_axi_rdata<=0;s_axi_rresp<=2'b10;end
                endcase
            end
        end
    end
endmodule
