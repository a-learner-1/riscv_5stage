module cpu_top (
    input  wire        clk,
    input  wire        rst_n,

    output wire [31:0] pc_x,
    output wire [31:0] instr_x,
    output wire        valid_x,

    output reg  [31:0] wb_pc,
    output reg  [4:0]  wb_rd,
    output reg  [31:0] wb_data,
    output reg         wb_we
);

    // Must match the operation encoding in alu.v.
    localparam [2:0] ALU_ADD = 3'b000;
    localparam [2:0] ALU_SUB = 3'b001;
    localparam [2:0] ALU_AND = 3'b010;
    localparam [2:0] ALU_OR  = 3'b011;
    localparam [2:0] ALU_XOR = 3'b100;

    wire [31:0] pc_f;

    wire [4:0]  rs1_addr_x;
    wire [4:0]  rs2_addr_x;
    wire [4:0]  rd_addr_x;
    wire [31:0] imm_x;

    wire is_addi_x;
    wire is_add_x;
    wire is_sub_x;
    wire is_and_x;
    wire is_or_x;
    wire is_xor_x;

    wire uses_rs2_x;
    wire writes_rd_x;

    wire [31:0] rs1_data_x;
    wire [31:0] rs2_data_x;

    wire        forward_rs1_x;
    wire        forward_rs2_x;
    wire [31:0] rs2_value_x;

    wire [31:0] alu_a_x;
    wire [31:0] alu_b_x;
    wire [2:0]  alu_op_x;
    wire [31:0] alu_result_x;

    // IF stage and IF/EX pipeline registers.
    if_stage u_if_stage (
        .clk     (clk),
        .rst_n   (rst_n),
        .pc_f    (pc_f),
        .pc_x    (pc_x),
        .instr_x (instr_x),
        .valid_x (valid_x)
    );

    // EX stage: instruction decoding.
    decoder u_decoder (
        .instr    (instr_x),
        .rs1_addr (rs1_addr_x),
        .rs2_addr (rs2_addr_x),
        .rd_addr  (rd_addr_x),
        .imm_i    (imm_x),
        .is_addi  (is_addi_x),
        .is_add   (is_add_x),
        .is_sub   (is_sub_x),
        .is_and   (is_and_x),
        .is_or    (is_or_x),
        .is_xor   (is_xor_x)
    );

    // Register file: two read ports and one write port.
    regfile u_regfile (
        .clk      (clk),
        .we       (wb_we),
        .rs1_addr (rs1_addr_x),
        .rs2_addr (rs2_addr_x),
        .rd_addr  (wb_rd),
        .rd_data  (wb_data),
        .rs1_data (rs1_data_x),
        .rs2_data (rs2_data_x)
    );

    // These R-type instructions consume both source registers.
    assign uses_rs2_x =
        is_add_x |
        is_sub_x |
        is_and_x |
        is_or_x  |
        is_xor_x;

    // All currently supported instructions produce an rd result.
    assign writes_rd_x = is_addi_x | uses_rs2_x;

    // WB -> EX forwarding for rs1.
    assign forward_rs1_x =
        wb_we &&
        (wb_rd != 5'd0) &&
        (wb_rd == rs1_addr_x);

    assign alu_a_x =
        forward_rs1_x ? wb_data : rs1_data_x;

    // WB -> EX forwarding for rs2.
    // ADDI does not use rs2, so its immediate bits cannot trigger this.
    assign forward_rs2_x =
        uses_rs2_x &&
        wb_we &&
        (wb_rd != 5'd0) &&
        (wb_rd == rs2_addr_x);

    assign rs2_value_x =
        forward_rs2_x ? wb_data : rs2_data_x;

    // ADDI uses an immediate; R-type instructions use rs2.
    assign alu_b_x =
        is_addi_x ? imm_x : rs2_value_x;

    // Select the ALU operation.
    assign alu_op_x =
        is_sub_x ? ALU_SUB :
        is_and_x ? ALU_AND :
        is_or_x  ? ALU_OR  :
        is_xor_x ? ALU_XOR :
                   ALU_ADD;

    alu u_alu (
        .a      (alu_a_x),
        .b      (alu_b_x),
        .alu_op (alu_op_x),
        .result (alu_result_x)
    );

    // EX/WB pipeline registers.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_pc   <= 32'd0;
            wb_rd   <= 5'd0;
            wb_data <= 32'd0;
            wb_we   <= 1'b0;
        end else begin
            wb_pc   <= pc_x;
            wb_rd   <= rd_addr_x;
            wb_data <= alu_result_x;

            wb_we <= valid_x &&
                     writes_rd_x &&
                     (rd_addr_x != 5'd0);
        end
    end

endmodule