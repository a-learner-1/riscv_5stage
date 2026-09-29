module data_mem #(
    parameter integer WORDS = 4096,
    parameter [31:0] BASE_ADDR = 32'h00000000,
    parameter INIT_FILE = ""
) (
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
    // Parameterized little-endian RAM. Reads return the containing 32-bit word.
    // The initialization file contains words relative to BASE_ADDR.
    reg [31:0] mem [0:WORDS-1];
    wire [31:0] byte_offset = addr - BASE_ADDR;
    wire [29:0] word_index = byte_offset[31:2];
    wire in_range = (addr >= BASE_ADDR) && (word_index < WORDS);
    wire aligned = (size == 2'd0) ||
                   ((size == 2'd1) && (addr[0] == 1'b0)) ||
                   ((size == 2'd2) && (addr[1:0] == 2'b00));
    assign access_ok = in_range && aligned && (size != 2'd3);
    assign rdata = (re && access_ok) ? mem[word_index] : 32'd0;

    integer i;
    initial begin
        for (i = 0; i < WORDS; i = i + 1)
            mem[i] = 32'd0;
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    always @(posedge clk) begin
        if (we && access_ok) begin
            if (wstrb[0]) mem[word_index][7:0]   <= wdata[7:0];
            if (wstrb[1]) mem[word_index][15:8]  <= wdata[15:8];
            if (wstrb[2]) mem[word_index][23:16] <= wdata[23:16];
            if (wstrb[3]) mem[word_index][31:24] <= wdata[31:24];
        end
    end
endmodule
