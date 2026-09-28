module instr_mem #(
    parameter integer WORDS = 1024,
    parameter INIT_FILE = "programs/rv32i_regression.hex"
) (
    input  wire [31:0] addr,
    output wire [31:0] instr,
    output wire        access_ok
);
    localparam [31:0] NOP = 32'h00000013;

    reg [31:0] mem [0:WORDS-1];
    wire [29:0] word_index = addr[31:2];
    integer i;

    assign access_ok = (addr[1:0] == 2'b00) && (word_index < WORDS);
    assign instr = access_ok ? mem[word_index] : NOP;

    // Fill unused locations with NOP, then overlay the external program image.
    initial begin
        for (i = 0; i < WORDS; i = i + 1)
            mem[i] = NOP;
        $readmemh(INIT_FILE, mem);
    end
endmodule
