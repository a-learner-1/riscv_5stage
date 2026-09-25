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

    wire [31:0] pc_f;

    wire [4:0]  rs1_addr_x;
    wire [4:0]  rs2_addr_x;
    wire [4:0]  rd_addr_x;
    wire [31:0] imm_x;
    wire        is_addi_x;
    wire        is_add_x;

    wire [31:0] rs1_data_x;
    wire [31:0] rs2_data_x;

    wire        forward_rs1_x;
    wire        forward_rs2_x;
    wire [31:0] rs2_value_x;
    wire [31:0] alu_a_x;
    wire [31:0] alu_b_x;
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
        .is_add   (is_add_x)
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

    // WB -> EX forwarding for the first source.
    assign forward_rs1_x = wb_we &&
                           (wb_rd != 5'd0) &&
                           (wb_rd == rs1_addr_x);

    assign alu_a_x = forward_rs1_x ? wb_data : rs1_data_x;

    // Only ADD uses rs2 in the current instruction subset.
    assign forward_rs2_x = is_add_x &&
                           wb_we &&
                           (wb_rd != 5'd0) &&
                           (wb_rd == rs2_addr_x);

    assign rs2_value_x = forward_rs2_x ? wb_data : rs2_data_x;

    // ADDI uses the immediate; ADD uses the second register value.
    assign alu_b_x = is_addi_x ? imm_x : rs2_value_x;

    alu u_alu (
        .a      (alu_a_x),
        .b      (alu_b_x),
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
            wb_we   <= valid_x &&
                       (is_addi_x || is_add_x) &&
                       (rd_addr_x != 5'd0);
        end
    end

endmodule