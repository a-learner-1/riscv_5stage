module data_mem (
    input wire clk,
    input wire re,
    input wire we,
    input wire [31:0] addr,
    input wire [31:0] wdata,
    output wire [31:0] rdata,
    output wire access_ok
);
    // 1 KiB: byte addresses 0..1023, aligned word starts 0..1020.
    // Contents are unspecified until written. No full-array reset is required.
    reg [31:0] mem [0:255];
    assign access_ok = (addr[31:10] == 22'd0) && (addr[1:0] == 2'b00);
    assign rdata = (re && access_ok) ? mem[addr[9:2]] : 32'd0;
    always @(posedge clk) begin
        if (we && access_ok)
            mem[addr[9:2]] <= wdata;
    end
endmodule
