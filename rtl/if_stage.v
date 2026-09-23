module if_stage (
    input  wire        clk,
    input  wire        rst_n,
    output reg  [31:0] pc_f,
    output reg  [31:0] pc_x,
    output reg  [31:0] instr_x,
    output reg         valid_x
);

    reg [31:0] instr_f;

    // ????????? ROM?????????????? 0?4?8?
    always @(*) begin
        case (pc_f)
            32'd0:   instr_f = 32'h00500093; // addi x1, x0, 5
            32'd4:   instr_f = 32'h00300113; // addi x2, x0, 3
            default: instr_f = 32'h00000013; // NOP
        endcase
    end

    // PC ??????????? PC ????? IF/EX ????
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_f    <= 32'd0;
            pc_x    <= 32'd0;
            instr_x <= 32'h00000013;
            valid_x <= 1'b0;
        end else begin
            pc_x    <= pc_f;
            instr_x <= instr_f;
            valid_x <= 1'b1;
            pc_f    <= pc_f + 32'd4;
        end
    end

endmodule
