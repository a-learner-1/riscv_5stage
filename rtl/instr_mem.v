module instr_mem #(
    parameter integer WORDS = 1024,
    parameter INIT_FILE = "programs/rv32i_regression.hex"
) (
    input  wire        clk,
    input  wire        en,
    input  wire [31:0] addr,
    output reg  [31:0] instr,
    output reg         access_ok
);
    localparam [31:0] NOP = 32'h00000013;

    reg [31:0] mem [0:WORDS-1];
    wire [29:0] word_index = addr[31:2];
    integer i;

    wire request_ok = (addr[1:0] == 2'b00) && (word_index < WORDS);

    // Fill unused locations with NOP, then overlay the external program image.
    initial begin
        for (i = 0; i < WORDS; i = i + 1)
            mem[i] = NOP;
        $readmemh(INIT_FILE, mem);
    end

    // One-cycle synchronous read suitable for FPGA block RAM inference.
    // When en is low, keep the previous response stable.
    always @(posedge clk) begin
        if (en) begin
            access_ok <= request_ok;
            instr <= request_ok ? mem[word_index] : NOP;
        end
    end
endmodule


