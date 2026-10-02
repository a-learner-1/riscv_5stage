module cpu_top #(
    parameter PROGRAM_FILE = "programs/rv32i_regression.hex",
    parameter DATA_FILE = "",
    parameter integer IMEM_WORDS = 8192,
    parameter integer DMEM_WORDS = 4096,
    parameter [31:0] DMEM_BASE_ADDR = 32'h00000000,
    parameter integer UART_CLOCK_HZ = 100000000,
    parameter integer UART_BAUD = 115200,
    parameter integer UART_RX_FIFO_DEPTH = 16,
    parameter integer SIM_CONSOLE_ECHO = 1,
    parameter integer EXTERNAL_DMEM = 0,
    parameter integer DMEM_REQ_WAIT_CYCLES = 0,
    parameter integer DMEM_RSP_WAIT_CYCLES = 0,
    parameter integer EXTERNAL_IMEM = 0,
    parameter integer IMEM_REQ_WAIT_CYCLES = 0,
    parameter integer IMEM_RSP_WAIT_CYCLES = 0,
    // Opt in explicitly. Existing boards retain their fault-stop behavior.
    parameter integer ENABLE_TRAPS = 0,
    // Timer interrupts require the M-mode exception environment above.
    parameter integer ENABLE_TIMER_IRQ = 0
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
    output reg [63:0] instret_count,
    output wire       uart_tx,
    input  wire       uart_rx,
    input  wire [7:0] gpio_in,
    output wire [7:0] gpio_out,
    output wire [7:0] gpio_oe,

    // External data RAM bus; ignored completely when EXTERNAL_DMEM=0.
    // MMIO always stays local. Only one transaction may be outstanding.
    output wire        dmem_req_valid,
    input  wire        dmem_req_ready,
    output wire        dmem_req_write,
    output wire [31:0] dmem_req_addr,
    output wire [1:0]  dmem_req_size,
    output wire [31:0] dmem_req_wdata,
    output wire [3:0]  dmem_req_wstrb,
    input  wire        dmem_rsp_valid,
    output wire        dmem_rsp_ready,
    input  wire [31:0] dmem_rsp_rdata,
    input  wire        dmem_rsp_error,
    output reg         dmem_fault,

    // External instruction bus; ignored when EXTERNAL_IMEM=0.
    // In-order, one outstanding request; endpoint shares CPU reset.
    output wire        imem_req_valid,
    input  wire        imem_req_ready,
    output wire [31:0] imem_req_addr,
    input  wire        imem_rsp_valid,
    output wire        imem_rsp_ready,
    input  wire [31:0] imem_rsp_rdata,
    input  wire        imem_rsp_error,
    output wire        imem_fault,
    output wire [31:0] imem_fault_pc,
    // One-cycle trap-entry pulse and the most recent trap descriptor
    // (synchronous exception or optional machine timer interrupt).
    output reg         trap_valid,
    output reg  [31:0] trap_pc,
    output reg  [31:0] trap_cause,
    output reg  [31:0] trap_tval
);

    localparam [31:0] MMIO_CYCLE_ADDR   = 32'h2000_0000;
    localparam [31:0] MMIO_INSTRET_ADDR = 32'h2000_0004;
    localparam [31:0] MMIO_PUTCHAR_ADDR = 32'h2000_0010;
    localparam [31:0] MMIO_UART_STATUS_ADDR = 32'h2000_0014;
    localparam integer TIMER_IRQ_ENABLED =
        (ENABLE_TRAPS != 0) && (ENABLE_TIMER_IRQ != 0);

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

    wire        mmio_region_x;
    wire        mmio_cycle_addr_x;
    wire        mmio_instret_addr_x;
    wire        mmio_counter_addr_x;
    wire        mmio_load_ok_x;
    wire        mmio_putchar_write_x;
    wire        mmio_uart_status_addr_x;
    wire        uart_busy;
    wire        uart_write_accept_x;
    wire        uart_rx_read_hit_x;
    wire        uart_rx_write_hit_x;
    wire        mmio_uart_rx_write_x;
    wire [31:0] uart_rx_read_data_x;
    wire        gpio_read_hit_x;
    wire        gpio_write_hit_x;
    wire        mmio_gpio_write_x;
    wire [31:0] gpio_read_data_x;
    wire        timer_read_hit_x;
    wire        timer_write_hit_x;
    wire        mmio_timer_store_ok_x;
    wire        mmio_timer_write_x;
    wire [31:0] timer_read_data_x;
    wire [63:0] timer_mtime;
    wire [63:0] timer_mtimecmp;
    wire        timer_mtip;
    wire [31:0] mmio_read_data_x;
    wire [31:0] load_raw_data_x;

    // Accepted UART character event retained for the existing MMIO monitors.
    reg         mmio_putchar_valid;
    reg [7:0]   mmio_putchar_data;

    wire [31:0] load_shifted_x;
    wire [31:0] load_data_x;

    wire load_issue_x;
    wire stall_x;

    // A memory descriptor is captured on its FIRST EX edge, including
    // operands forwarded from WB. It must not change while ready is low.
    reg        mem_active;
    reg        req_sent;
    reg        mem_write_q;
    reg        mem_mmio_q;
    reg [31:0] mem_pc_q;
    reg [4:0]  mem_rd_q;
    reg [2:0]  mem_funct3_q;
    reg [31:0] mem_addr_q;
    reg [1:0]  mem_size_q;
    reg [3:0]  mem_wstrb_q;
    reg [31:0] mem_wdata_q;
    reg [31:0] mem_rs2_q;

    wire        mem_start_x;
    wire        mem_req_valid;
    wire        mem_req_ready;
    wire        mem_req_fire;
    wire        mem_req_write;
    wire        mem_req_mmio;
    wire        mem_req_access_ok;
    wire [31:0] mem_store_raw_x;
    wire        mmio_store_ok_x;
    wire        mmio_putchar_addr_ok_x;
    wire        mmio_gpio_store_ok_x;
    wire        mmio_uart_rx_store_ok_x;
    wire        mem_external_x;
    wire        local_req_ready;
    wire        local_rsp_valid;
    wire [31:0] local_rsp_rdata;
    wire        local_rsp_error;
    wire        mem_rsp_valid;
    wire        mem_rsp_ready;
    wire        mem_rsp_fire;
    wire [31:0] mem_rsp_rdata;
    wire        mem_rsp_error;
    wire        mem_rsp_success;
    wire        retire_to_wb;

    // Compatibility monitors: accepted load and accepted-load response wait.
    reg        load_pending;
    reg [31:0] load_pc_q;
    reg [4:0]  load_rd_q;
    reg [1:0]  load_addr_lsb_q;
    reg [2:0]  load_funct3_q;
    reg        load_mmio_q;
    reg [31:0] load_mmio_data_q;

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

    wire is_fence_x;
    wire is_ecall_x;
    wire is_ebreak_x;
    wire is_mret_x;
    wire is_csr_x;
    wire system_enabled_x;
    wire csr_write_intent_x;
    wire csr_commit_x;
    wire mret_commit_x;
    wire [11:0] csr_addr_x;
    wire [31:0] csr_operand_x;
    reg  [31:0] csr_read_data_x;
    wire [31:0] csr_write_data_x;
    reg         csr_known_x;
    reg         csr_read_only_x;
    wire        csr_legal_x;

    // Minimal M-mode trap CSRs, plus optional MTIE/MTIP for the local timer.
    // There is no external interrupt input, delegation, U/S mode, PMP,
    // or counter CSR implementation in this step.
    // MPP is WARL M (3); mstatus implements only MIE and MPIE besides MPP.
    reg [31:0] csr_mstatus;
    reg [31:0] csr_mtvec;
    reg [31:0] csr_mscratch;
    reg [31:0] csr_mepc;
    reg [31:0] csr_mcause;
    reg [31:0] csr_mtval;
    reg [31:0] csr_mie;

    wire        control_misaligned_x;
    wire        data_misaligned_x;
    wire        illegal_instruction_x;
    wire        ex_exception_x;
    wire [31:0] ex_exception_cause_x;
    wire [31:0] ex_exception_tval_x;
    wire        data_exception;
    wire        fetch_exception;
    wire        sync_trap_event;
    wire        irq_pending;
    wire        irq_event;
    // Architectural boundary after all previously completed instructions;
    // unlike pc_f, this never tracks a speculative fetch or held request.
    reg  [31:0] arch_next_pc;
    wire        trap_event;
    wire [31:0] trap_event_pc;
    wire [31:0] trap_event_cause;
    wire [31:0] trap_event_tval;
    wire        normal_redirect_x;

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
        .IMEM_WORDS(IMEM_WORDS),
        .EXTERNAL_IMEM(EXTERNAL_IMEM),
        .IMEM_REQ_WAIT_CYCLES(IMEM_REQ_WAIT_CYCLES),
        .IMEM_RSP_WAIT_CYCLES(IMEM_RSP_WAIT_CYCLES),
        .ENABLE_TRAPS(ENABLE_TRAPS)
    ) u_if_stage (
        .clk           (clk),
        .rst_n         (rst_n),
        .redirect_x    (redirect_x),
        .redirect_pc_x (redirect_pc_x),
        .stall_x       (stall_x),
        .pc_f          (pc_f),
        .pc_x          (pc_x),
        .instr_x       (instr_x),
        .valid_x       (valid_x),
        .imem_req_valid(imem_req_valid), .imem_req_ready(imem_req_ready),
        .imem_req_addr(imem_req_addr), .imem_rsp_valid(imem_rsp_valid),
        .imem_rsp_ready(imem_rsp_ready), .imem_rsp_rdata(imem_rsp_rdata),
        .imem_rsp_error(imem_rsp_error),
        .imem_fault(imem_fault), .imem_fault_pc(imem_fault_pc)
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
        .is_sh    (is_sh_x),
        .is_fence (is_fence_x),
        .is_ecall (is_ecall_x),
        .is_ebreak(is_ebreak_x),
        .is_mret  (is_mret_x),
        .is_csr   (is_csr_x)
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
         is_jalr_x |
         ((ENABLE_TRAPS != 0) && is_csr_x && !instr_x[14]));

    assign writes_rd_x =
        (((use_imm_x | uses_rs2_x) &&
          !is_branch_x &&
          !is_store_x) |
         is_jump_x |
         ((ENABLE_TRAPS != 0) && is_csr_x));

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
        is_store_x |
        system_enabled_x;

    assign system_enabled_x = (ENABLE_TRAPS != 0) &&
        (is_fence_x || is_ecall_x || is_ebreak_x || is_mret_x || is_csr_x);

    assign csr_addr_x = instr_x[31:20];
    assign csr_operand_x = instr_x[14] ? {27'd0, instr_x[19:15]} : rs1_value_x;
    // CSRRS/CSRRC suppress the write only for the encoded x0/zimm=0, even
    // when a nonzero source register happens to contain zero. CSRRW always
    // writes; rd=x0 suppresses the architectural read/result (no CSR here
    // has a read side effect, and normal WB masks x0).
    assign csr_write_intent_x = is_csr_x &&
        ((instr_x[13:12] == 2'b01) || (instr_x[19:15] != 5'd0));
    assign csr_write_data_x = (instr_x[13:12] == 2'b01) ? csr_operand_x :
                             (instr_x[13:12] == 2'b10) ?
                                 (csr_read_data_x | csr_operand_x) :
                                 (csr_read_data_x & ~csr_operand_x);
    assign csr_legal_x = csr_known_x &&
                         !(csr_read_only_x && csr_write_intent_x);

    always @* begin
        csr_known_x = 1'b1;
        csr_read_only_x = 1'b0;
        csr_read_data_x = 32'd0;
        case (csr_addr_x)
            12'h300: csr_read_data_x = csr_mstatus;
            12'h301: begin
                // Fixed RV32I WARL value. Writes are legal and ignored;
                // Zicsr and M privilege are not ISA extension letter bits.
                csr_read_data_x = 32'h40000100;
            end
            12'h304: begin
                csr_known_x = (TIMER_IRQ_ENABLED != 0);
                csr_read_data_x = csr_mie;
            end
            12'h305: csr_read_data_x = csr_mtvec;
            12'h340: csr_read_data_x = csr_mscratch;
            12'h341: csr_read_data_x = csr_mepc;
            12'h342: csr_read_data_x = csr_mcause;
            12'h343: csr_read_data_x = csr_mtval;
            12'h344: begin
                csr_known_x = (TIMER_IRQ_ENABLED != 0);
                csr_read_data_x = timer_mtip ? 32'h00000080 : 32'd0;
                // Hardware-owned MTIP. CSR writes are legal but ignored.
            end
            12'hf11, 12'hf12, 12'hf13, 12'hf14, 12'hf15: begin
                csr_read_data_x = 32'd0;
                csr_read_only_x = 1'b1;
            end
            default: csr_known_x = 1'b0;
        endcase
    end

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

    assign normal_redirect_x =
        !dmem_fault && !mem_active &&
        (branch_taken_x | jump_taken_x);

    // IALIGN=32: only a taken branch/jump checks its destination. JALR
    // clears bit 0 first. The exception belongs to the control instruction,
    // so its link register must not be written on a misaligned target.
    assign control_misaligned_x =
        (jump_taken_x && (jump_target_x[1:0] != 2'b00)) ||
        (branch_taken_x && (branch_target_x[1:0] != 2'b00));
    assign data_misaligned_x = (is_load_x || is_store_x) &&
        (((mem_size_x == 2'd1) && mem_addr_x[0]) ||
         ((mem_size_x == 2'd2) && (mem_addr_x[1:0] != 2'b00)));
    assign illegal_instruction_x = !instr_supported_x ||
                                    (is_csr_x && !csr_legal_x);
    assign ex_exception_x = (ENABLE_TRAPS != 0) && rst_n &&
        !dmem_fault && !mem_active && valid_x &&
        (illegal_instruction_x || is_ecall_x || is_ebreak_x ||
         control_misaligned_x || data_misaligned_x);
    assign ex_exception_cause_x = illegal_instruction_x ? 32'd2 :
                                 is_ecall_x ? 32'd11 :
                                 is_ebreak_x ? 32'd3 :
                                 control_misaligned_x ? 32'd0 :
                                 is_store_x ? 32'd6 : 32'd4;
    assign ex_exception_tval_x = illegal_instruction_x ? instr_x :
                                is_ecall_x ? 32'd0 :
                                is_ebreak_x ? pc_x :
                                control_misaligned_x ?
                                    (jump_taken_x ? jump_target_x : branch_target_x) :
                                mem_addr_x;

    // A data response is for the older captured instruction. A frontend
    // error is acknowledged only after the older EX slot has drained. This
    // extra edge also makes an older mtvec write visible to the fetch trap.
    assign data_exception = (ENABLE_TRAPS != 0) && mem_rsp_fire && mem_rsp_error;
    assign fetch_exception = (ENABLE_TRAPS != 0) && rst_n && imem_fault &&
                              !dmem_fault && !mem_active && !valid_x;
    assign sync_trap_event = data_exception || ex_exception_x || fetch_exception;
    assign irq_pending = (TIMER_IRQ_ENABLED != 0) && timer_mtip &&
                          csr_mie[7] && csr_mstatus[3];
    // Once a memory descriptor has started, even an unaccepted request or
    // held response must drain. Its STORE/MMIO effect is never replayed.
    // Only recognized synchronous exceptions outrank this interrupt. A raw
    // younger IF response not yet in EX can be discarded as stale by redirect;
    // MRET refetches the architectural next PC and redetects any access fault.
    assign irq_event = rst_n && irq_pending && !dmem_fault && !mem_active &&
                       !sync_trap_event;
    assign trap_event = sync_trap_event || irq_event;
    assign trap_event_pc = data_exception ? mem_pc_q :
                           ex_exception_x ? pc_x :
                           fetch_exception ? imem_fault_pc :
                           valid_x ? pc_x : arch_next_pc;
    assign trap_event_cause = data_exception ? (mem_write_q ? 32'd7 : 32'd5) :
                              ex_exception_x ? ex_exception_cause_x :
                              fetch_exception ?
                                  ((imem_fault_pc[1:0] != 2'b00) ? 32'd0 : 32'd1) :
                              32'h80000007;
    assign trap_event_tval = data_exception ? mem_addr_q :
                             ex_exception_x ? ex_exception_tval_x :
                             fetch_exception ? imem_fault_pc : 32'd0;
    assign mret_commit_x = (ENABLE_TRAPS != 0) && rst_n && valid_x &&
                           !dmem_fault && !mem_active && is_mret_x && !trap_event;
    assign csr_commit_x = (ENABLE_TRAPS != 0) && rst_n && valid_x &&
                          !dmem_fault && !mem_active && is_csr_x &&
                          csr_legal_x && csr_write_intent_x && !trap_event;

    assign redirect_x = trap_event || mret_commit_x ||
                         (normal_redirect_x && !ex_exception_x);
    assign redirect_pc_x = trap_event ? csr_mtvec :
                           mret_commit_x ? csr_mepc :
                           jump_taken_x ? jump_target_x : branch_target_x;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            csr_mstatus <= 32'h00001800;
            csr_mtvec <= 32'd0;
            csr_mscratch <= 32'd0;
            csr_mepc <= 32'd0;
            csr_mcause <= 32'd0;
            csr_mtval <= 32'd0;
            csr_mie <= 32'd0;
            trap_valid <= 1'b0;
            trap_pc <= 32'd0;
            trap_cause <= 32'd0;
            trap_tval <= 32'd0;
        end else begin
            trap_valid <= trap_event;
            if (trap_event) begin
                trap_pc <= trap_event_pc;
                trap_cause <= trap_event_cause;
                trap_tval <= trap_event_tval;
                csr_mepc <= {trap_event_pc[31:2], 2'b00};
                csr_mcause <= trap_event_cause;
                csr_mtval <= trap_event_tval;
                csr_mstatus <= 32'h00001800 |
                               (csr_mstatus[3] ? 32'h00000080 : 32'd0);
            end else if (mret_commit_x) begin
                csr_mstatus <= 32'h00001880 |
                               (csr_mstatus[7] ? 32'h00000008 : 32'd0);
            end else if (csr_commit_x) begin
                case (csr_addr_x)
                    12'h300: csr_mstatus <= 32'h00001800 |
                                           (csr_write_data_x & 32'h00000088);
                    12'h304: csr_mie <= csr_write_data_x & 32'h00000080;
                    // Only direct mtvec and IALIGN=32 addresses are WARL.
                    12'h305: csr_mtvec <= {csr_write_data_x[31:2], 2'b00};
                    12'h340: csr_mscratch <= csr_write_data_x;
                    12'h341: csr_mepc <= {csr_write_data_x[31:2], 2'b00};
                    12'h342: csr_mcause <= csr_write_data_x;
                    12'h343: csr_mtval <= csr_write_data_x;
                    // Fixed misa and hardware-owned mip writes have no effect.
                    default: begin end
                endcase
            end
        end
    end

    // This tracker advances only at architectural completion, including a
    // successfully drained memory response. It is valid even when IF waits
    // for request acceptance/response and no EX instruction is available.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            arch_next_pc <= 32'd0;
        else if (trap_event)
            arch_next_pc <= csr_mtvec;
        else if (mem_rsp_success)
            arch_next_pc <= mem_pc_q + 32'd4;
        else if (retire_to_wb) begin
            if (mret_commit_x)
                arch_next_pc <= csr_mepc;
            else if (jump_taken_x)
                arch_next_pc <= jump_target_x;
            else if (branch_taken_x)
                arch_next_pc <= branch_target_x;
            else
                arch_next_pc <= pc_x + 32'd4;
        end
    end

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
    assign mem_addr_x = mem_active ? mem_addr_q : alu_result_x;

    assign mem_size_x =
        mem_active ? mem_size_q :
        (is_lb_x | is_lbu_x | is_sb_x) ? 2'd0 :
        (is_lh_x | is_lhu_x | is_sh_x) ? 2'd1 :
                                         2'd2;

    assign mem_wstrb_x =
        mem_active ? mem_wstrb_q :
        is_sb_x ? (4'b0001 << mem_addr_x[1:0]) :
        is_sh_x ? (4'b0011 << mem_addr_x[1:0]) :
        is_sw_x ? 4'b1111 :
                  4'b0000;

    assign mem_wdata_x =
        mem_active ? mem_wdata_q :
        (rs2_value_x << {mem_addr_x[1:0], 3'b000});

    assign mem_store_raw_x = mem_active ? mem_rs2_q : rs2_value_x;

    /*
     * Memory-mapped I/O region used by bare-metal software.
     *
     *   0x2000_0000: cycle counter, low 32 bits, read-only
     *   0x2000_0004: retired-instruction counter, low 32 bits, read-only
     *   0x2000_0010: UART data, write-only (low byte)
     *   0x2000_0014: UART status, read-only (bit 0: busy)
     *   0x2000_0018: UART RX data, aligned LW pops one byte (empty -> 0)
     *   0x2000_001c: UART RX status, aligned LW; SW W1C error bits 2/3
     *   0x2000_0020: GPIO output latch, read/write
     *   0x2000_0024: synchronized GPIO input, read-only
     *   0x2000_0028: GPIO output-enable mask, read/write
     *   0x2000_002c/0030/0034: output SET/CLEAR/TOGGLE, write-only
     *   0x2000_0040/0044: optional mtime low/high, read/write
     *   0x2000_0048/004c: optional mtimecmp low/high, read/write
     * GPIO registers accept aligned LW/SW only.
     * Timer registers accept aligned LW/SW only when TIMER_IRQ_ENABLED.
     */
    assign mmio_region_x =
        (mem_addr_x[31:16] == 16'h2000);

    assign mmio_cycle_addr_x =
        (mem_addr_x == MMIO_CYCLE_ADDR);

    assign mmio_instret_addr_x =
        (mem_addr_x == MMIO_INSTRET_ADDR);

    assign mmio_counter_addr_x =
        mmio_cycle_addr_x |
        mmio_instret_addr_x;

    assign mmio_uart_status_addr_x =
        (mem_addr_x == MMIO_UART_STATUS_ADDR);

    // Counters are exposed as aligned 32-bit registers.  CoreMark only
    // needs the low word because elapsed time is computed by subtraction.
    assign mmio_load_ok_x =
        (mmio_counter_addr_x || mmio_uart_status_addr_x ||
         uart_rx_read_hit_x || gpio_read_hit_x || timer_read_hit_x) &&
        (mem_size_x == 2'd2) &&
        (mem_addr_x[1:0] == 2'b00);

    assign mmio_read_data_x =
        mmio_cycle_addr_x   ? cycle_count[31:0] :
        mmio_instret_addr_x ? instret_count[31:0] :
        mmio_uart_status_addr_x ? {31'd0, uart_busy} :
        uart_rx_read_hit_x  ? uart_rx_read_data_x :
        gpio_read_hit_x     ? gpio_read_data_x :
        timer_read_hit_x    ? timer_read_data_x : 32'd0;

    // Accept SB, SH and SW at the character register and use the low byte.
    assign mmio_putchar_addr_ok_x =
        (mem_addr_x == MMIO_PUTCHAR_ADDR) &&
        (mem_size_x != 2'd3);

    assign mmio_gpio_store_ok_x = gpio_write_hit_x &&
        (mem_size_x == 2'd2) && (mem_addr_x[1:0] == 2'b00);

    assign mmio_uart_rx_store_ok_x = uart_rx_write_hit_x &&
        (mem_size_x == 2'd2) && (mem_addr_x[1:0] == 2'b00);

    assign mmio_timer_store_ok_x = timer_write_hit_x &&
        (mem_size_x == 2'd2) && (mem_addr_x[1:0] == 2'b00);

    assign mmio_store_ok_x = mmio_putchar_addr_ok_x ||
        mmio_gpio_store_ok_x || mmio_uart_rx_store_ok_x || mmio_timer_store_ok_x;

    // Peripheral side effects occur ONCE, at request acceptance, even when
    // the CPU remains stalled waiting for a delayed completion response.
    assign mmio_putchar_write_x = mem_req_fire && mem_req_write &&
        mem_req_mmio && mmio_putchar_addr_ok_x;

    assign uart_write_accept_x = mmio_putchar_write_x && !uart_busy;

    assign mmio_gpio_write_x = mem_req_fire && mem_req_write &&
        mem_req_mmio && mmio_gpio_store_ok_x;

    assign mmio_uart_rx_write_x = mem_req_fire && mem_req_write &&
        mem_req_mmio && mmio_uart_rx_store_ok_x;

    assign mmio_timer_write_x = mem_req_fire && mem_req_write &&
        mem_req_mmio && mmio_timer_store_ok_x;

    // Capture the pre-pop head in load_mmio_data_q on the issue edge.
    // A held LOAD has load_pending=1 on the next edge and cannot pop again.
    uart_rx_mmio #(
        .CLOCK_HZ(UART_CLOCK_HZ), .BAUD(UART_BAUD),
        .FIFO_DEPTH(UART_RX_FIFO_DEPTH)
    ) u_uart_rx_mmio (
        .clk(clk), .rst_n(rst_n), .rx(uart_rx), .addr(mem_addr_x),
        .read_enable(load_issue_x && mmio_load_ok_x),
        .write_enable(mmio_uart_rx_write_x), .write_data(mem_store_raw_x),
        .read_data(uart_rx_read_data_x),
        .read_hit(uart_rx_read_hit_x), .write_hit(uart_rx_write_hit_x)
    );

    // Keep the peripheral independent of the pipeline implementation.
    // Output enable is exposed separately; a board wrapper implements IOB
    // tristates or uses the mask to gate dedicated LED output pins.
    gpio_mmio u_gpio (
        .clk(clk), .rst_n(rst_n),
        .addr(mem_addr_x), .write_enable(mmio_gpio_write_x),
        .write_data(mem_store_raw_x), .read_data(gpio_read_data_x),
        .read_hit(gpio_read_hit_x), .write_hit(gpio_write_hit_x),
        .gpio_in(gpio_in), .gpio_out(gpio_out), .gpio_oe(gpio_oe)
    );

    generate
        if (TIMER_IRQ_ENABLED != 0) begin : g_machine_timer
            machine_timer u_timer (
                .clk(clk), .rst_n(rst_n), .addr(mem_addr_x),
                .write_enable(mmio_timer_write_x), .write_data(mem_store_raw_x),
                .read_data(timer_read_data_x), .read_hit(timer_read_hit_x),
                .write_hit(timer_write_hit_x), .mtime(timer_mtime),
                .mtimecmp(timer_mtimecmp), .mtip(timer_mtip)
            );
        end else begin : g_no_machine_timer
            // A disabled generate branch has no timer module dependency;
            // existing standalone compile scripts remain compatible.
            assign timer_read_data_x = 32'd0;
            assign timer_read_hit_x = 1'b0;
            assign timer_write_hit_x = 1'b0;
            assign timer_mtime = 64'd0;
            assign timer_mtimecmp = 64'hffffffffffffffff;
            assign timer_mtip = 1'b0;
        end
    endgenerate

    // Request and byte reach the UART in the same cycle as the MMIO store.
    // There is no delayed request whose pending state could be missed by
    // a following status read.
    uart_tx #(
        .CLOCK_HZ(UART_CLOCK_HZ),
        .BAUD(UART_BAUD)
    ) u_uart_tx (
        .clk(clk),
        .rst_n(rst_n),
        .valid(mmio_putchar_write_x),
        .data(mem_store_raw_x[7:0]),
        .tx(uart_tx),
        .busy(uart_busy),
        .done()
    );

    // Unified request/response handshake. A new memory instruction can
    // present its request in its first EX cycle. The first edge captures
    // the descriptor whether or not the endpoint is ready on that edge.
    assign mem_start_x = rst_n && !dmem_fault && !mem_active && valid_x &&
                         (is_load_x || is_store_x) && !ex_exception_x && !irq_event;
    assign mem_req_valid = rst_n && !dmem_fault && !req_sent &&
                           (mem_active || mem_start_x);
    assign mem_req_write = mem_active ? mem_write_q : is_store_x;
    assign mem_req_mmio = mem_active ? mem_mmio_q : mmio_region_x;
    assign mem_external_x = (EXTERNAL_DMEM != 0) && !mem_req_mmio;
    assign mem_req_ready = mem_external_x ? dmem_req_ready : local_req_ready;
    assign mem_req_fire = mem_req_valid && mem_req_ready;

    // These are pure address/size predicates, not side-effect pulses.
    // External RAM legality is decided by its error response, not by the
    // internal teaching RAM's address range.
    assign mem_req_access_ok = mem_req_mmio ?
        (mem_req_write ? (mmio_store_ok_x &&
            (!mmio_putchar_addr_ok_x || !uart_busy)) : mmio_load_ok_x) :
        mem_access_ok_x;

    assign dmem_req_valid = (EXTERNAL_DMEM != 0) && mem_req_valid &&
                            !mem_req_mmio;
    assign dmem_req_write = mem_req_write;
    assign dmem_req_addr = mem_addr_x;
    assign dmem_req_size = mem_size_x;
    assign dmem_req_wdata = mem_wdata_x;
    assign dmem_req_wstrb = mem_wstrb_x;

    // req_sent is updated only at an acceptance edge; it prevents consuming
    // an unsolicited or combinational same-edge external response.
    assign mem_rsp_ready = rst_n && !dmem_fault && mem_active && req_sent;
    assign mem_rsp_valid = mem_external_x ? dmem_rsp_valid : local_rsp_valid;
    assign mem_rsp_rdata = mem_external_x ? dmem_rsp_rdata : local_rsp_rdata;
    assign mem_rsp_error = mem_external_x ? dmem_rsp_error : local_rsp_error;
    assign mem_rsp_fire = mem_rsp_valid && mem_rsp_ready;
    assign mem_rsp_success = mem_rsp_fire && !mem_rsp_error;
    assign dmem_rsp_ready = (EXTERNAL_DMEM != 0) && !mem_req_mmio &&
                            mem_rsp_ready;

    assign load_issue_x = mem_req_fire && !mem_req_write;
    // Both LOAD and STORE wait for completion before the next EX advances.
    // Legacy errors halt; trap-mode errors drain and redirect on this edge.
    // FENCE can only enter EX after the older data response completed, so
    // its conservative full ordering requires no additional bus request.
    assign stall_x = dmem_fault ||
                     ((mem_active || mem_start_x) && !mem_rsp_success);
    assign mem_re_x = load_issue_x && !mem_req_mmio &&
                      (EXTERNAL_DMEM == 0);
    assign mem_we_x = mem_req_fire && mem_req_write && !mem_req_mmio &&
                      (EXTERNAL_DMEM == 0);

    data_bus_adapter #(
        .REQ_WAIT_CYCLES(DMEM_REQ_WAIT_CYCLES),
        .RSP_WAIT_CYCLES(DMEM_RSP_WAIT_CYCLES)
    ) u_data_bus_adapter (
        .clk(clk), .rst_n(rst_n),
        .req_valid(mem_req_valid && !mem_external_x),
        .req_ready(local_req_ready), .req_write(mem_req_write),
        .req_mmio(mem_req_mmio), .req_access_ok(mem_req_access_ok),
        .mmio_rdata(mmio_read_data_x), .ram_rdata(mem_rdata_x),
        .rsp_valid(local_rsp_valid),
        .rsp_ready(mem_rsp_ready && !mem_external_x),
        .rsp_rdata(local_rsp_rdata), .rsp_error(local_rsp_error)
    );

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

    // Single-outstanding transaction state and immutable descriptor.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_active      <= 1'b0;
            req_sent        <= 1'b0;
            mem_write_q     <= 1'b0;
            mem_mmio_q      <= 1'b0;
            mem_pc_q        <= 32'd0;
            mem_rd_q        <= 5'd0;
            mem_funct3_q    <= 3'd0;
            mem_addr_q      <= 32'd0;
            mem_size_q      <= 2'd0;
            mem_wstrb_q     <= 4'd0;
            mem_wdata_q     <= 32'd0;
            mem_rs2_q       <= 32'd0;
            dmem_fault      <= 1'b0;
            load_pending    <= 1'b0;
            load_pc_q       <= 32'd0;
            load_rd_q       <= 5'd0;
            load_addr_lsb_q <= 2'd0;
            load_funct3_q   <= 3'd0;
            load_mmio_q     <= 1'b0;
            load_mmio_data_q <= 32'd0;
        end else begin
            if (mem_start_x) begin
                mem_active   <= 1'b1;
                mem_write_q  <= is_store_x;
                mem_mmio_q   <= mmio_region_x;
                mem_pc_q     <= pc_x;
                mem_rd_q     <= rd_addr_x;
                mem_funct3_q <= instr_x[14:12];
                mem_addr_q   <= mem_addr_x;
                mem_size_q   <= mem_size_x;
                mem_wstrb_q  <= mem_wstrb_x;
                mem_wdata_q  <= mem_wdata_x;
                mem_rs2_q    <= rs2_value_x;
                // Old load metadata names are retained for existing waves.
                load_pc_q       <= pc_x;
                load_rd_q       <= rd_addr_x;
                load_addr_lsb_q <= mem_addr_x[1:0];
                load_funct3_q   <= instr_x[14:12];
                load_mmio_q     <= mmio_region_x;
            end
            if (mem_req_fire) begin
                req_sent <= 1'b1;
                load_pending <= !mem_req_write;
                load_mmio_data_q <= mmio_read_data_x;
            end
            if (mem_rsp_fire) begin
                mem_active <= 1'b0;
                req_sent <= 1'b0;
                load_pending <= 1'b0;
                load_mmio_q  <= 1'b0;
                if (mem_rsp_error && (ENABLE_TRAPS == 0))
                    dmem_fault <= 1'b1;
            end
        end
    end

    // Display software output in ModelSim without creating hardware logic.
    // synthesis translate_off
    always @(posedge clk) begin
        if (SIM_CONSOLE_ECHO && uart_write_accept_x)
            $write("%c", mem_store_raw_x[7:0]);
    end
    // synthesis translate_on

    /*
     * One-cycle pulse for each accepted write to MMIO_PUTCHAR_ADDR.
     * Software must poll the busy bit before issuing a new character.
     * The testbench
     * checks this byte.  The real serial output is the uart_tx port.
     */
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mmio_putchar_valid <= 1'b0;
            mmio_putchar_data  <= 8'd0;
        end else begin
            mmio_putchar_valid <= uart_write_accept_x;

            if (uart_write_accept_x)
                mmio_putchar_data <= mem_store_raw_x[7:0];
        end
    end

    /*
     * ?????????
     */
    assign load_raw_data_x = mem_rsp_rdata;

    assign load_shifted_x =
        load_raw_data_x >>
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

            load_raw_data_x;

    /*
     * ?????????????
     */
    // synthesis translate_off
    always @(posedge clk) begin
        if ((ENABLE_TRAPS == 0) && mmio_putchar_write_x && uart_busy)
            $fatal(1, "UART write while busy pc=%h: poll 0x20000014 first", pc_x);

        if ((ENABLE_TRAPS == 0) && load_issue_x &&
            !mem_req_mmio && (EXTERNAL_DMEM == 0) &&
            mem_access_ok_x !== 1'b1) begin
            $fatal(
                1,
                "Unsupported load address pc=%h addr=%h size=%0d",
                pc_x,
                mem_addr_x,
                mem_size_x
            );
        end

        if ((ENABLE_TRAPS == 0) && load_issue_x &&
            mem_req_mmio &&
            !mmio_load_ok_x) begin
            $fatal(
                1,
                "Unsupported MMIO load pc=%h addr=%h size=%0d",
                pc_x,
                mem_addr_x,
                mem_size_x
            );
        end

        if ((ENABLE_TRAPS == 0) && mem_req_fire && mem_req_write &&
            !mem_req_mmio && (EXTERNAL_DMEM == 0) &&
            mem_access_ok_x !== 1'b1) begin
            $fatal(
                1,
                "Unsupported store address pc=%h addr=%h size=%0d",
                pc_x,
                mem_addr_x,
                mem_size_x
            );
        end

        if ((ENABLE_TRAPS == 0) && mem_req_fire && mem_req_write &&
            mem_req_mmio && !mmio_store_ok_x) begin
            $fatal(
                1,
                "Unsupported MMIO store pc=%h addr=%h size=%0d",
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
        end else if (mem_rsp_success) begin
            wb_pc   <= mem_pc_q;
            wb_rd   <= mem_rd_q;
            wb_data <= load_data_x;
            wb_we   <= !mem_write_q && (mem_rd_q != 5'd0);
        end else if (!dmem_fault && !mem_active && valid_x && !trap_event &&
                     !is_load_x && !is_store_x) begin
            wb_pc <= pc_x;
            wb_rd <= rd_addr_x;

            wb_data <=
                ((ENABLE_TRAPS != 0) && is_csr_x) ? csr_read_data_x :
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

    assign retire_to_wb =
        mem_rsp_success ||
        (
            !dmem_fault &&
            valid_x &&
            !mem_active &&
            !trap_event &&
            !is_load_x &&
            !is_store_x &&
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
