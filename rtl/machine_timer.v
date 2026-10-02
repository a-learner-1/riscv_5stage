// Platform timer clocked by clk: one mtime tick per input clock cycle.
// The four CPU-local MMIO words are sampled by the CPU request endpoint.
module machine_timer (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] addr,
    input  wire        write_enable,
    input  wire [31:0] write_data,
    output wire [31:0] read_data,
    output wire        read_hit,
    output wire        write_hit,
    output reg  [63:0] mtime,
    output reg  [63:0] mtimecmp,
    output wire        mtip
);
    localparam [31:0] MTIME_LO_ADDR    = 32'h20000040;
    localparam [31:0] MTIME_HI_ADDR    = 32'h20000044;
    localparam [31:0] MTIMECMP_LO_ADDR = 32'h20000048;
    localparam [31:0] MTIMECMP_HI_ADDR = 32'h2000004c;

    assign read_hit = (addr == MTIME_LO_ADDR) || (addr == MTIME_HI_ADDR) ||
                      (addr == MTIMECMP_LO_ADDR) || (addr == MTIMECMP_HI_ADDR);
    assign write_hit = read_hit;
    assign read_data = (addr == MTIME_LO_ADDR) ? mtime[31:0] :
                       (addr == MTIME_HI_ADDR) ? mtime[63:32] :
                       (addr == MTIMECMP_LO_ADDR) ? mtimecmp[31:0] :
                       (addr == MTIMECMP_HI_ADDR) ? mtimecmp[63:32] : 32'd0;
    // MTIP is a level; software clears it by moving mtimecmp above mtime.
    assign mtip = (mtime >= mtimecmp);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mtime <= 64'd0;
            mtimecmp <= 64'hffffffffffffffff;
        end else begin
            // A write replaces this whole increment edge and preserves the
            // other half from the pre-edge value (including at carry/wrap).
            if (write_enable && (addr == MTIME_LO_ADDR))
                mtime <= {mtime[63:32], write_data};
            else if (write_enable && (addr == MTIME_HI_ADDR))
                mtime <= {write_data, mtime[31:0]};
            else
                mtime <= mtime + 64'd1;

            if (write_enable && (addr == MTIMECMP_LO_ADDR))
                mtimecmp <= {mtimecmp[63:32], write_data};
            else if (write_enable && (addr == MTIMECMP_HI_ADDR))
                mtimecmp <= {write_data, mtimecmp[31:0]};
        end
    end
endmodule
