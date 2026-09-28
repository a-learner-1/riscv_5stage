module cpu_top #(
    parameter PROGRAM_FILE = "programs/rv32i_regression.hex",
    parameter integer IMEM_WORDS = 1024
) (
    input  wire        clk,
    input  wire        rst_n,

    output wire [31:0] pc_x,
    output wire [31:0] instr_x,
    output wire        valid_x,

    output reg  [31:0] wb_pc,
    output reg  [4:0]  wb_rd,
    output reg  [31:0] wb_data,
    output reg         wb_we,

    // Performance-monitoring signals.  retire_valid marks a supported,
    // non-squashed instruction at the WB/retirement point.
    output reg         retire_valid,
    output reg  [63:0] cycle_count,
    output reg  [63:0] instret_count
);

    localparam [3:0] ALU_ADD = 4'b000;
    localparam [3:0] ALU_SUB = 4'b001;
    localparam [3:0] ALU_AND = 4'b010;
    localparam [3:0] ALU_OR  = 4'b011;
    localparam [3:0] ALU_XOR = 4'b100;

    localparam [3:0] ALU_SLL = 4'b101;
    localparam [3:0] ALU_SRL = 4'b110;
    localparam [3:0] ALU_SRA = 4'b111;
    localparam [3:0] ALU_SLT  = 4'b1000;
    localparam [3:0] ALU_SLTU = 4'b1001;
    wire [31:0] pc_f;

    wire [4:0] rs1_addr_x;
    wire [4:0] rs2_addr_x;
    wire [4:0] rd_addr_x;
    wire [31:0] imm_x;
    wire [31:0] imm_u_x;
    wire [31:0] imm_b_x;
    wire [31:0] imm_j_x;
    wire [31:0] imm_s_x;
    wire is_lw_x, is_sw_x;
    wire is_lb_x, is_lbu_x, is_lh_x, is_lhu_x, is_sb_x, is_sh_x;
    wire is_load_x, is_store_x;
    wire mem_re_x, mem_we_x, mem_access_ok_x;
    wire [1:0] mem_size_x;
    wire [3:0] mem_wstrb_x;
    wire [31:0] mem_rdata_x;
    wire [31:0] mem_addr_x;
    wire [31:0] mem_wdata_x;
    wire [31:0] load_shifted_x;
    wire [31:0] load_data_x;

    wire is_addi_x;
    wire is_add_x;
    wire is_sub_x;
    wire is_and_x;
    wire is_or_x;
    wire is_xor_x;
    wire is_andi_x;
    wire is_ori_x;
    wire is_xori_x;
    wire is_sll_x;
    wire is_srl_x;
    wire is_sra_x;
    wire is_slli_x;
    wire is_srli_x;
    wire is_srai_x;
    wire is_slt_x, is_sltu_x, is_slti_x, is_sltiu_x;
    wire is_lui_x, is_auipc_x;
    wire is_beq_x, is_bne_x;
    wire is_blt_x, is_bge_x, is_bltu_x, is_bgeu_x;
    wire is_jal_x, is_jalr_x, is_jump_x;
    wire is_branch_x;
    wire branch_taken_x;
    wire [31:0] branch_target_x;
    wire jump_taken_x;
    wire [31:0] jump_target_x;
    wire redirect_x;
    wire [31:0] redirect_pc_x;
    wire use_upper_imm_x;
    wire use_shift_imm_x;
    wire [31:0] shamt_imm_x;

    wire use_imm_x;
    wire uses_rs1_x;
    wire uses_rs2_x;
    wire writes_rd_x;
    wire instr_supported_x;

    wire [31:0] rs1_data_x;
    wire [31:0] rs2_data_x;

    wire forward_rs1_x;
    wire forward_rs2_x;
    wire [31:0] rs1_value_x;
    wire [31:0] rs2_value_x;

    wire [31:0] alu_a_x;
    wire [31:0] alu_b_x;
    wire [3:0]  alu_op_x;
    wire [31:0] alu_result_x;

    if_stage #(
        .PROGRAM_FILE(PROGRAM_FILE),
        .IMEM_WORDS(IMEM_WORDS)
    ) u_if_stage (
        .clk     (clk),
        .rst_n   (rst_n),
        .redirect_x (redirect_x),
        .redirect_pc_x (redirect_pc_x),
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
        .imm_u    (imm_u_x),
        .imm_b    (imm_b_x),
        .imm_j    (imm_j_x),

        .is_addi  (is_addi_x),
        .is_add   (is_add_x),
        .is_sub   (is_sub_x),
        .is_and   (is_and_x),
        .is_or    (is_or_x),
        .is_xor   (is_xor_x),

        .is_andi  (is_andi_x),
        .is_ori   (is_ori_x),
        .is_xori  (is_xori_x),
        .is_sll   (is_sll_x),
        .is_srl   (is_srl_x),
        .is_sra   (is_sra_x),
        .is_slli  (is_slli_x),
        .is_srli  (is_srli_x),
        .is_srai  (is_srai_x),
        .is_slt   (is_slt_x),
        .is_sltu  (is_sltu_x),
        .is_slti  (is_slti_x),
        .is_sltiu (is_sltiu_x),
        .is_lui   (is_lui_x),
        .is_auipc (is_auipc_x),
        .is_beq   (is_beq_x),
        .is_bne   (is_bne_x),
        .is_blt   (is_blt_x),
        .is_bge   (is_bge_x),
        .is_bltu  (is_bltu_x),
        .is_bgeu  (is_bgeu_x),
        .is_jal   (is_jal_x),
        .is_jalr  (is_jalr_x),
        .is_lw (is_lw_x), .is_sw (is_sw_x),
        .is_lb (is_lb_x), .is_lbu (is_lbu_x),
        .is_lh (is_lh_x), .is_lhu (is_lhu_x),
        .is_sb (is_sb_x), .is_sh (is_sh_x),
        .imm_s (imm_s_x)
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

    // Shift immediates use ONLY instr[24:20], not the encoded upper bits.
    assign use_shift_imm_x = is_slli_x | is_srli_x | is_srai_x;
    assign shamt_imm_x = {27'd0, instr_x[24:20]};

    // U-type immediate bits are not register source addresses.
    assign use_upper_imm_x = is_lui_x | is_auipc_x;
    assign is_load_x = is_lb_x | is_lbu_x | is_lh_x | is_lhu_x | is_lw_x;
    assign is_store_x = is_sb_x | is_sh_x | is_sw_x;
    assign is_branch_x = is_beq_x | is_bne_x |
                         is_blt_x | is_bge_x | is_bltu_x | is_bgeu_x;
    assign is_jump_x = is_jal_x | is_jalr_x;

    // All immediate instructions select the immediate operand path.
    assign use_imm_x =
        is_addi_x |
        is_andi_x |
        is_ori_x  |
        is_xori_x |
        use_shift_imm_x |
        is_slti_x | is_sltiu_x |
        use_upper_imm_x | is_load_x | is_store_x;

    // Only these instructions consume a second source register.
    assign uses_rs2_x =
        is_add_x |
        is_sub_x |
        is_and_x |
        is_or_x  |
        is_xor_x |
        is_sll_x |
        is_srl_x |
        is_sra_x |
        is_slt_x | is_sltu_x |
        is_branch_x | is_store_x;

    assign uses_rs1_x = ((use_imm_x | uses_rs2_x) && !use_upper_imm_x)
                        | is_jalr_x;
    assign writes_rd_x = ((use_imm_x | uses_rs2_x) && !is_branch_x && !is_store_x)
                         | is_jump_x;

    // Keep retirement independent of register writeback: stores and branches
    // are real instructions even though they do not write a GPR.  Restrict the
    // signal to the RV32I subset implemented by this core so an unsupported
    // word or an invalid fetch cannot be reported as retired.
    assign instr_supported_x =
        is_addi_x | is_add_x | is_sub_x |
        is_and_x | is_or_x | is_xor_x |
        is_andi_x | is_ori_x | is_xori_x |
        is_sll_x | is_srl_x | is_sra_x |
        is_slli_x | is_srli_x | is_srai_x |
        is_slt_x | is_sltu_x | is_slti_x | is_sltiu_x |
        is_lui_x | is_auipc_x |
        is_branch_x | is_jump_x | is_load_x | is_store_x;

    // WB -> EX forwarding for rs1.
    assign forward_rs1_x =
        uses_rs1_x &&
        wb_we &&
        (wb_rd != 5'd0) &&
        (wb_rd == rs1_addr_x);

    assign rs1_value_x = forward_rs1_x ? wb_data : rs1_data_x;

    assign alu_a_x =
        is_lui_x   ? 32'd0 :
        is_auipc_x ? pc_x  :
        rs1_value_x;

    // I-type immediate bits must not trigger rs2 forwarding.
    assign forward_rs2_x =
        uses_rs2_x &&
        wb_we &&
        (wb_rd != 5'd0) &&
        (wb_rd == rs2_addr_x);

    assign rs2_value_x =
        forward_rs2_x ? wb_data : rs2_data_x;

    // Resolve all six RV32I branches in EX using forwarded operands.
    assign branch_taken_x = valid_x &&
        ((is_beq_x && (rs1_value_x == rs2_value_x)) ||
         (is_bne_x && (rs1_value_x != rs2_value_x)) ||
         (is_blt_x && ($signed(rs1_value_x) < $signed(rs2_value_x))) ||
         (is_bge_x && ($signed(rs1_value_x) >= $signed(rs2_value_x))) ||
         (is_bltu_x && (rs1_value_x < rs2_value_x)) ||
         (is_bgeu_x && (rs1_value_x >= rs2_value_x)));
    assign branch_target_x = pc_x + imm_b_x;
    assign jump_taken_x = valid_x && is_jump_x;
    assign jump_target_x = is_jal_x ? (pc_x + imm_j_x) :
                           ((rs1_value_x + imm_x) & 32'hfffffffe);
    assign redirect_x = branch_taken_x | jump_taken_x;
    assign redirect_pc_x = jump_taken_x ? jump_target_x : branch_target_x;

    assign alu_b_x =
        is_store_x     ? imm_s_x :
        use_upper_imm_x ? imm_u_x :
        use_shift_imm_x ? shamt_imm_x :
        use_imm_x       ? imm_x       : rs2_value_x;

    // Register and immediate versions share the same ALU operation.
    assign alu_op_x =
        (is_slt_x | is_slti_x)     ? ALU_SLT  :
        (is_sltu_x | is_sltiu_x)   ? ALU_SLTU :
        (is_sll_x | is_slli_x)   ? ALU_SLL :
        (is_srl_x | is_srli_x)   ? ALU_SRL :
        (is_sra_x | is_srai_x)   ? ALU_SRA :
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

    // This teaching RAM has asynchronous reads and synchronous writes.
    // A future synchronous BRAM needs a different response/stall protocol.
    assign mem_addr_x = alu_result_x;
    assign mem_size_x = (is_lb_x | is_lbu_x | is_sb_x) ? 2'd0 :
                        (is_lh_x | is_lhu_x | is_sh_x) ? 2'd1 : 2'd2;
    assign mem_wstrb_x = is_sb_x ? (4'b0001 << mem_addr_x[1:0]) :
                         is_sh_x ? (4'b0011 << mem_addr_x[1:0]) :
                         is_sw_x ? 4'b1111 : 4'b0000;
    assign mem_wdata_x = rs2_value_x << {mem_addr_x[1:0], 3'b000};
    assign mem_re_x = rst_n && valid_x && is_load_x;
    assign mem_we_x = rst_n && valid_x && is_store_x;
    data_mem u_data_mem (
        .clk(clk), .re(mem_re_x), .we(mem_we_x),
        .addr(mem_addr_x), .size(mem_size_x),
        .wdata(mem_wdata_x), .wstrb(mem_wstrb_x),
        .rdata(mem_rdata_x), .access_ok(mem_access_ok_x)
    );

    // The RAM returns the containing word. Select the addressed byte/halfword,
    // then apply the signed or unsigned RV32I extension rule.
    assign load_shifted_x = mem_rdata_x >> {mem_addr_x[1:0], 3'b000};
    assign load_data_x =
        is_lb_x  ? {{24{load_shifted_x[7]}},  load_shifted_x[7:0]}  :
        is_lbu_x ? {24'd0, load_shifted_x[7:0]}                    :
        is_lh_x  ? {{16{load_shifted_x[15]}}, load_shifted_x[15:0]} :
        is_lhu_x ? {16'd0, load_shifted_x[15:0]}                   :
                   mem_rdata_x;

    // Unsupported accesses stop simulation instead of silently aliasing RAM.
    // synthesis translate_off
    always @(posedge clk) begin
        if ((mem_re_x || mem_we_x) && mem_access_ok_x !== 1'b1)
            $fatal(1, "Unsupported load/store address pc=%h addr=%h size=%0d",
                   pc_x, mem_addr_x, mem_size_x);
    end
    // synthesis translate_on

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
            wb_data <= is_load_x ? load_data_x :
                       is_jump_x ? (pc_x + 32'd4) : alu_result_x;

            wb_we <= valid_x &&
                     writes_rd_x &&
                     (!is_load_x || mem_access_ok_x) &&
                     (rd_addr_x != 5'd0);
        end
    end

    // Performance counters start when the first supported instruction reaches
    // EX.  cycle_count then includes every cycle through the retirement of the
    // tohost store, including any future stall or cache-miss cycles.
    reg counting_started;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            retire_valid    <= 1'b0;
            cycle_count     <= 64'd0;
            instret_count   <= 64'd0;
            counting_started <= 1'b0;
        end else begin
            // This register follows the same EX -> WB boundary as wb_pc/data.
            retire_valid <= valid_x && instr_supported_x;

            if (!counting_started) begin
                if (valid_x && instr_supported_x) begin
                    counting_started <= 1'b1;
                    cycle_count <= 64'd1;
                end
            end else begin
                cycle_count <= cycle_count + 64'd1;
            end

            if (retire_valid)
                instret_count <= instret_count + 64'd1;
        end
    end

endmodule
