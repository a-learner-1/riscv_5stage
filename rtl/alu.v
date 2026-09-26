module alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire        sub,
    output wire [31:0] result
);

    // sub = 0: addition
    // sub = 1: subtraction
    assign result = sub ? (a - b) : (a + b);

endmodule
