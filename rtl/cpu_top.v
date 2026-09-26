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

    localparam [2:0] ALU_ADD = 3'b000;
    localparam [2:0] ALU_SUB = 3'b001;
    localparam [2:0] ALU_AND = 3'b010;
    localparam [2:0] ALU_OR  = 3'b011;
    localparam [2:0] ALU_XOR = 3'b100;

    wire [31:0] pc_f;

    wire [4:0] rs1_addr_x;
    wire [4:0] rs2_addr_x;
    wire [4:0] rd_addr_x;
    wire [31:0] imm_x;

    wire is_addi_x;
    wire is_add_x;
    wire is_sub_x;
    wire is_and_x;
    wire is_or_x;
    wire is_xor_x;
    wire is_andi_x;
    wire is_ori_x;
    wire is_xori_x;

    wire use_imm_x;
    wire uses_rs2_x;
    wire writes_rd_x;

    wire [31:0] rs1_data_x;
    wire [31:0] rs2_data_x;

    wire forward_rs1_x;
    wire forward_rs2_x;
    wire [31:0] rs2_value_x;

    wire [31:0] alu_a_x;
    wire [31:0] alu_b_x;
    wire [2:0]  alu_op_x;
    wire [31:0] alu_result_x;

    if_stage u_if_stage (
        .clk     (clk),
        .rst_n   (rst_n),
        .pc_f    (pc_f),
        .pc_x    (pc_x),
        .instr_x (instr_x),
        .valid_x (valid_x)
    );

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
        .is_xor   (is_xor_x),

        .is_andi  (is_andi_x),
        .is_ori   (is_ori_x),
        .is_xori  (is_xori_x)
    );

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

    // These instructions use a sign-extended immediate.
    assign use_imm_x =
        is_addi_x |
        is_andi_x |
        is_ori_x  |
        is_xori_x;

    // Only these instructions consume a second source register.
    assign uses_rs2_x =
        is_add_x |
        is_sub_x |
        is_and_x |
        is_or_x  |
        is_xor_x;

    assign writes_rd_x = use_imm_x | uses_rs2_x;

    // WB -> EX forwarding for rs1.
    assign forward_rs1_x =
        wb_we &&
        (wb_rd != 5'd0) &&
        (wb_rd == rs1_addr_x);

    assign alu_a_x =
        forward_rs1_x ? wb_data : rs1_data_x;

    // I-type immediate bits must not trigger rs2 forwarding.
    assign forward_rs2_x =
        uses_rs2_x &&
        wb_we &&
        (wb_rd != 5'd0) &&
        (wb_rd == rs2_addr_x);

    assign rs2_value_x =
        forward_rs2_x ? wb_data : rs2_data_x;

    assign alu_b_x =
        use_imm_x ? imm_x : rs2_value_x;

    // Register and immediate versions share the same ALU operation.
    assign alu_op_x =
        is_sub_x                 ? ALU_SUB :
        (is_and_x | is_andi_x)    ? ALU_AND :
        (is_or_x  | is_ori_x)     ? ALU_OR  :
        (is_xor_x | is_xori_x)    ? ALU_XOR :
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