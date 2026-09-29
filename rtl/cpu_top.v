module cpu_top #(
    parameter PROGRAM_FILE = "programs/rv32i_regression.hex",
    parameter DATA_FILE = "",
    parameter integer IMEM_WORDS = 8192,
    parameter integer DMEM_WORDS = 4096,
    parameter [31:0] DMEM_BASE_ADDR = 32'h00000000
) (
    input wire clk,
    input wire rst_n,

    output wire [31:0] pc_x,
    output wire [31:0] instr_x,
    output wire        valid_x,

    output reg [31:0] wb_pc,
    output reg [4:0]  wb_rd,
    output reg [31:0] wb_data,
    output reg        wb_we,

    output reg        retire_valid,
    output reg [63:0] cycle_count,
    output reg [63:0] instret_count
);

    localparam [3:0] ALU_ADD  = 4'b0000;
    localparam [3:0] ALU_SUB  = 4'b0001;
    localparam [3:0] ALU_AND  = 4'b0010;
    localparam [3:0] ALU_OR   = 4'b0011;
    localparam [3:0] ALU_XOR  = 4'b0100;
    localparam [3:0] ALU_SLL  = 4'b0101;
    localparam [3:0] ALU_SRL  = 4'b0110;
    localparam [3:0] ALU_SRA  = 4'b0111;
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

    wire is_lw_x;
    wire is_sw_x;
    wire is_lb_x;
    wire is_lbu_x;
    wire is_lh_x;
    wire is_lhu_x;
    wire is_sb_x;
    wire is_sh_x;

    wire is_load_x;
    wire is_store_x;

    wire        mem_re_x;
    wire        mem_we_x;
    wire        mem_access_ok_x;
    wire [1:0]  mem_size_x;
    wire [3:0]  mem_wstrb_x;
    wire [31:0] mem_rdata_x;
    wire [31:0] mem_addr_x;
    wire [31:0] mem_wdata_x;

    wire [31:0] load_shifted_x;
    wire [31:0] load_data_x;

    wire load_issue_x;
    wire stall_x;

    // ??RAM??????????
    reg        load_pending;
    reg [31:0] load_pc_q;
    reg [4:0]  load_rd_q;
    reg [1:0]  load_addr_lsb_q;
    reg [2:0]  load_funct3_q;

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

    wire is_slt_x;
    wire is_sltu_x;
    wire is_slti_x;
    wire is_sltiu_x;

    wire is_lui_x;
    wire is_auipc_x;

    wire is_beq_x;
    wire is_bne_x;
    wire is_blt_x;
    wire is_bge_x;
    wire is_bltu_x;
    wire is_bgeu_x;

    wire is_jal_x;
    wire is_jalr_x;
    wire is_jump_x;

    wire        is_branch_x;
    wire        branch_taken_x;
    wire [31:0] branch_target_x;

    wire        jump_taken_x;
    wire [31:0] jump_target_x;

    wire        redirect_x;
    wire [31:0] redirect_pc_x;

    wire        use_upper_imm_x;
    wire        use_shift_imm_x;
    wire [31:0] shamt_imm_x;

    wire use_imm_x;
    wire uses_rs1_x;
    wire uses_rs2_x;
    wire writes_rd_x;
    wire instr_supported_x;

    wire [31:0] rs1_data_x;
    wire [31:0] rs2_data_x;

    wire        forward_rs1_x;
    wire        forward_rs2_x;
    wire [31:0] rs1_value_x;
    wire [31:0] rs2_value_x;

    wire [31:0] alu_a_x;
    wire [31:0] alu_b_x;
    wire [3:0]  alu_op_x;
    wire [31:0] alu_result_x;

    /*
     * IF?
     */
    if_stage #(
        .PROGRAM_FILE(PROGRAM_FILE),
        .IMEM_WORDS(IMEM_WORDS)
    ) u_if_stage (
        .clk           (clk),
        .rst_n         (rst_n),
        .redirect_x    (redirect_x),
        .redirect_pc_x (redirect_pc_x),
        .stall_x       (stall_x),
        .pc_f          (pc_f),
        .pc_x          (pc_x),
        .instr_x       (instr_x),
        .valid_x       (valid_x)
    );

    /*
     * ????
     */
    decoder u_decoder (
        .instr    (instr_x),

        .rs1_addr (rs1_addr_x),
        .rs2_addr (rs2_addr_x),
        .rd_addr  (rd_addr_x),

        .imm_i    (imm_x),
        .imm_u    (imm_u_x),
        .imm_b    (imm_b_x),
        .imm_j    (imm_j_x),
        .imm_s    (imm_s_x),

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

        .is_lw    (is_lw_x),
        .is_sw    (is_sw_x),
        .is_lb    (is_lb_x),
        .is_lbu   (is_lbu_x),
        .is_lh    (is_lh_x),
        .is_lhu   (is_lhu_x),
        .is_sb    (is_sb_x),
        .is_sh    (is_sh_x)
    );

    /*
     * ??????
     */
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

    /*
     * ????????
     */
    assign use_shift_imm_x =
        is_slli_x |
        is_srli_x |
        is_srai_x;

    assign shamt_imm_x =
        {27'd0, instr_x[24:20]};

    assign use_upper_imm_x =
        is_lui_x |
        is_auipc_x;

    assign is_load_x =
        is_lb_x  |
        is_lbu_x |
        is_lh_x  |
        is_lhu_x |
        is_lw_x;

    assign is_store_x =
        is_sb_x |
        is_sh_x |
        is_sw_x;

    assign is_branch_x =
        is_beq_x  |
        is_bne_x  |
        is_blt_x  |
        is_bge_x  |
        is_bltu_x |
        is_bgeu_x;

    assign is_jump_x =
        is_jal_x |
        is_jalr_x;

    assign use_imm_x =
        is_addi_x |
        is_andi_x |
        is_ori_x  |
        is_xori_x |
        use_shift_imm_x |
        is_slti_x |
        is_sltiu_x |
        use_upper_imm_x |
        is_load_x |
        is_store_x;

    assign uses_rs2_x =
        is_add_x |
        is_sub_x |
        is_and_x |
        is_or_x  |
        is_xor_x |
        is_sll_x |
        is_srl_x |
        is_sra_x |
        is_slt_x |
        is_sltu_x |
        is_branch_x |
        is_store_x;

    assign uses_rs1_x =
        (((use_imm_x | uses_rs2_x) && !use_upper_imm_x) |
         is_jalr_x);

    assign writes_rd_x =
        (((use_imm_x | uses_rs2_x) &&
          !is_branch_x &&
          !is_store_x) |
         is_jump_x);

    assign instr_supported_x =
        is_addi_x |
        is_add_x |
        is_sub_x |

        is_and_x |
        is_or_x |
        is_xor_x |

        is_andi_x |
        is_ori_x |
        is_xori_x |

        is_sll_x |
        is_srl_x |
        is_sra_x |

        is_slli_x |
        is_srli_x |
        is_srai_x |

        is_slt_x |
        is_sltu_x |
        is_slti_x |
        is_sltiu_x |

        is_lui_x |
        is_auipc_x |

        is_branch_x |
        is_jump_x |
        is_load_x |
        is_store_x;

    /*
     * WB -> EX ????
     */
    assign forward_rs1_x =
        uses_rs1_x &&
        wb_we &&
        (wb_rd != 5'd0) &&
        (wb_rd == rs1_addr_x);

    assign rs1_value_x =
        forward_rs1_x ?
        wb_data :
        rs1_data_x;

    assign forward_rs2_x =
        uses_rs2_x &&
        wb_we &&
        (wb_rd != 5'd0) &&
        (wb_rd == rs2_addr_x);

    assign rs2_value_x =
        forward_rs2_x ?
        wb_data :
        rs2_data_x;

    /*
     * ?????
     */
    assign branch_taken_x =
        valid_x &&
        (
            (is_beq_x  && (rs1_value_x == rs2_value_x)) ||
            (is_bne_x  && (rs1_value_x != rs2_value_x)) ||
            (is_blt_x  && ($signed(rs1_value_x) <
                           $signed(rs2_value_x))) ||
            (is_bge_x  && ($signed(rs1_value_x) >=
                           $signed(rs2_value_x))) ||
            (is_bltu_x && (rs1_value_x < rs2_value_x)) ||
            (is_bgeu_x && (rs1_value_x >= rs2_value_x))
        );

    assign branch_target_x =
        pc_x + imm_b_x;

    assign jump_taken_x =
        valid_x && is_jump_x;

    assign jump_target_x =
        is_jal_x ?
        (pc_x + imm_j_x) :
        ((rs1_value_x + imm_x) & 32'hffff_fffe);

    assign redirect_x =
        branch_taken_x |
        jump_taken_x;

    assign redirect_pc_x =
        jump_taken_x ?
        jump_target_x :
        branch_target_x;

    /*
     * ALU????
     */
    assign alu_a_x =
        is_lui_x   ? 32'd0 :
        is_auipc_x ? pc_x :
                     rs1_value_x;

    assign alu_b_x =
        is_store_x      ? imm_s_x :
        use_upper_imm_x ? imm_u_x :
        use_shift_imm_x ? shamt_imm_x :
        use_imm_x       ? imm_x :
                          rs2_value_x;

    assign alu_op_x =
        (is_slt_x  | is_slti_x)  ? ALU_SLT :
        (is_sltu_x | is_sltiu_x) ? ALU_SLTU :
        (is_sll_x  | is_slli_x)  ? ALU_SLL :
        (is_srl_x  | is_srli_x)  ? ALU_SRL :
        (is_sra_x  | is_srai_x)  ? ALU_SRA :
        is_sub_x                  ? ALU_SUB :
        (is_and_x  | is_andi_x)  ? ALU_AND :
        (is_or_x   | is_ori_x)   ? ALU_OR :
        (is_xor_x  | is_xori_x)  ? ALU_XOR :
                                    ALU_ADD;

    alu u_alu (
        .a      (alu_a_x),
        .b      (alu_b_x),
        .alu_op (alu_op_x),
        .result (alu_result_x)
    );

    /*
     * ???????
     */
    assign mem_addr_x = alu_result_x;

    assign mem_size_x =
        (is_lb_x | is_lbu_x | is_sb_x) ? 2'd0 :
        (is_lh_x | is_lhu_x | is_sh_x) ? 2'd1 :
                                         2'd2;

    assign mem_wstrb_x =
        is_sb_x ? (4'b0001 << mem_addr_x[1:0]) :
        is_sh_x ? (4'b0011 << mem_addr_x[1:0]) :
        is_sw_x ? 4'b1111 :
                  4'b0000;

    assign mem_wdata_x =
        rs2_value_x << {mem_addr_x[1:0], 3'b000};

    /*
     * ????????????
     *
     * ??????
     *   load_issue_x=1?RAM?????IF/EX???
     *
     * ??????
     *   load_pending=1?RAM???????WB??????
     */
    assign load_issue_x =
        rst_n &&
        valid_x &&
        is_load_x &&
        !load_pending;

    assign stall_x = load_issue_x;

    assign mem_re_x = load_issue_x;

    assign mem_we_x =
        rst_n &&
        valid_x &&
        is_store_x;

    data_mem #(
        .WORDS(DMEM_WORDS),
        .BASE_ADDR(DMEM_BASE_ADDR),
        .INIT_FILE(DATA_FILE)
    ) u_data_mem (
        .clk       (clk),
        .re        (mem_re_x),
        .we        (mem_we_x),
        .addr      (mem_addr_x),
        .size      (mem_size_x),
        .wdata     (mem_wdata_x),
        .wstrb     (mem_wstrb_x),
        .rdata     (mem_rdata_x),
        .access_ok (mem_access_ok_x)
    );

    /*
     * ?????????
     *
     * ????RAM??????????????????instr_x
     * ??LB/LH/LW??????funct3?rd????????
     */
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_pending    <= 1'b0;
            load_pc_q       <= 32'd0;
            load_rd_q       <= 5'd0;
            load_addr_lsb_q <= 2'd0;
            load_funct3_q   <= 3'd0;
        end else begin
            if (load_issue_x) begin
                load_pending    <= 1'b1;
                load_pc_q       <= pc_x;
                load_rd_q       <= rd_addr_x;
                load_addr_lsb_q <= mem_addr_x[1:0];
                load_funct3_q   <= instr_x[14:12];
            end else if (load_pending) begin
                load_pending <= 1'b0;
            end
        end
    end

    /*
     * ?????????
     */
    assign load_shifted_x =
        mem_rdata_x >>
        {load_addr_lsb_q, 3'b000};

    assign load_data_x =
        (load_funct3_q == 3'b000) ?
            {{24{load_shifted_x[7]}},
             load_shifted_x[7:0]} :

        (load_funct3_q == 3'b100) ?
            {24'd0, load_shifted_x[7:0]} :

        (load_funct3_q == 3'b001) ?
            {{16{load_shifted_x[15]}},
             load_shifted_x[15:0]} :

        (load_funct3_q == 3'b101) ?
            {16'd0, load_shifted_x[15:0]} :

            mem_rdata_x;

    /*
     * ?????????????
     */
    // synthesis translate_off
    always @(posedge clk) begin
        if ((mem_re_x || mem_we_x) &&
            mem_access_ok_x !== 1'b1) begin
            $fatal(
                1,
                "Unsupported load/store address pc=%h addr=%h size=%0d",
                pc_x,
                mem_addr_x,
                mem_size_x
            );
        end
    end
    // synthesis translate_on

    /*
     * EX/WB??????
     */
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_pc   <= 32'd0;
            wb_rd   <= 5'd0;
            wb_data <= 32'd0;
            wb_we   <= 1'b0;
        end else if (load_pending) begin
            // ??RAM???????
            wb_pc   <= load_pc_q;
            wb_rd   <= load_rd_q;
            wb_data <= load_data_x;
            wb_we   <= (load_rd_q != 5'd0);
        end else if (valid_x && !is_load_x) begin
            // ??ALU????????????
            wb_pc <= pc_x;
            wb_rd <= rd_addr_x;

            wb_data <=
                is_jump_x ?
                (pc_x + 32'd4) :
                alu_result_x;

            wb_we <=
                writes_rd_x &&
                (rd_addr_x != 5'd0);
        end else begin
            // ?????????????
            wb_we <= 1'b0;
        end
    end

    /*
     * ?????
     *
     * ??????WB????
     * ????????RAM????????
     */
    reg counting_started;
    wire retire_to_wb;

    assign retire_to_wb =
        load_pending ||
        (
            valid_x &&
            !load_pending &&
            !is_load_x &&
            instr_supported_x
        );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            retire_valid     <= 1'b0;
            cycle_count      <= 64'd0;
            instret_count    <= 64'd0;
            counting_started <= 1'b0;
        end else begin
            retire_valid <= retire_to_wb;

            if (!counting_started) begin
                if (valid_x && instr_supported_x) begin
                    counting_started <= 1'b1;
                    cycle_count      <= 64'd1;
                end
            end else begin
                cycle_count <= cycle_count + 64'd1;
            end

            if (retire_valid)
                instret_count <= instret_count + 64'd1;
        end
    end

endmodule
