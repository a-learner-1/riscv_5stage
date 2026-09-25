module alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    output wire [31:0] result
);

    // Add-only ALU for the first ADDI implementation.
    assign result = a + b;

endmodule
