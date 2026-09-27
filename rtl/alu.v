module alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [2:0]  alu_op,
    output reg  [31:0] result
);

    localparam [2:0] ALU_ADD = 3'b000;
    localparam [2:0] ALU_SUB = 3'b001;
    localparam [2:0] ALU_AND = 3'b010;
    localparam [2:0] ALU_OR  = 3'b011;
    localparam [2:0] ALU_XOR = 3'b100;

    localparam [2:0] ALU_SLL = 3'b101;
    localparam [2:0] ALU_SRL = 3'b110;
    localparam [2:0] ALU_SRA = 3'b111;
    wire [4:0] shamt;
    assign shamt = b[4:0];
    always @(*) begin
        case (alu_op)
            ALU_ADD: result = a + b;
            ALU_SUB: result = a - b;
            ALU_AND: result = a & b;
            ALU_OR:  result = a | b;
            ALU_XOR: result = a ^ b;
            ALU_SLL: result = a << shamt;
            ALU_SRL: result = a >> shamt;
            ALU_SRA: result = $signed(a) >>> shamt;
            default: result = 32'd0;
        endcase
    end

endmodule


