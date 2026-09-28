module data_mem (
    input wire clk,
    input wire re,
    input wire we,
    input wire [31:0] addr,
    input wire [1:0] size,
    input wire [31:0] wdata,
    input wire [3:0] wstrb,
    output wire [31:0] rdata,
    output wire access_ok
);
    // 1 KiB little-endian RAM. Reads return the containing 32-bit word.
    // Contents are unspecified until written. No full-array reset is required.
    reg [31:0] mem [0:255];
    wire in_range = (addr[31:10] == 22'd0);
    wire aligned = (size == 2'd0) ||
                   ((size == 2'd1) && (addr[0] == 1'b0)) ||
                   ((size == 2'd2) && (addr[1:0] == 2'b00));
    assign access_ok = in_range && aligned && (size != 2'd3);
    assign rdata = (re && access_ok) ? mem[addr[9:2]] : 32'd0;
    always @(posedge clk) begin
        if (we && access_ok) begin
            if (wstrb[0]) mem[addr[9:2]][7:0]   <= wdata[7:0];
            if (wstrb[1]) mem[addr[9:2]][15:8]  <= wdata[15:8];
            if (wstrb[2]) mem[addr[9:2]][23:16] <= wdata[23:16];
            if (wstrb[3]) mem[addr[9:2]][31:24] <= wdata[31:24];
        end
    end
endmodule
