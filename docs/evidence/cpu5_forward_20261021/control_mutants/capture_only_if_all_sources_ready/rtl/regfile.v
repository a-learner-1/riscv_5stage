module regfile (
    input  wire        clk,
    input  wire        we,
    input  wire [4:0]  rs1_addr,
    input  wire [4:0]  rs2_addr,
    input  wire [4:0]  rd_addr,
    input  wire [31:0] rd_data,
    output wire [31:0] rs1_data,
    output wire [31:0] rs2_data
);

    reg [31:0] regs [0:31];

    // Two asynchronous read ports. x0 always reads as zero.
    assign rs1_data = (rs1_addr == 5'd0) ? 32'd0 : regs[rs1_addr];
    assign rs2_data = (rs2_addr == 5'd0) ? 32'd0 : regs[rs2_addr];

    // One synchronous write port. Writes to x0 are ignored.
    always @(posedge clk) begin
        if (we && (rd_addr != 5'd0))
            regs[rd_addr] <= rd_data;
    end

endmodule