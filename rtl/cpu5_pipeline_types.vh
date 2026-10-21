// Module-local SystemVerilog types. Include once INSIDE each module that has
// SEQ_BITS and EPOCH_BITS parameters; deliberately no compilation-unit guard.
typedef struct packed {
    logic [31:0] pc, instr, pred_next_pc;
    logic pred_taken, pred_hit, fetch_error;
    logic [31:0] fetch_tval;
    logic [SEQ_BITS-1:0] seq;
    logic [EPOCH_BITS-1:0] epoch;
} cpu5_ifid_t;

typedef struct packed {
    logic [31:0] pc, instr;
    logic [4:0] rs1, rs2, rd;
    logic uses_rs1, uses_rs2, writes_rd;
    logic [31:0] rs1_value, rs2_value, imm, imm_s, imm_b, imm_j;
    logic [2:0] funct3;
    logic [3:0] alu_op;
    logic is_load, is_store, is_branch, is_jal, is_jalr;
    logic is_m, is_csr, is_mret, is_fence;
    logic [11:0] csr_addr;
    logic csr_write_intent;
    logic [31:0] pred_next_pc;
    logic pred_taken, pred_hit;
    logic exception_valid;
    logic [31:0] exception_cause, exception_tval;
    logic [SEQ_BITS-1:0] seq;
    logic [EPOCH_BITS-1:0] epoch;
} cpu5_idex_t;

typedef struct packed {
    logic [31:0] pc, instr;
    logic [SEQ_BITS-1:0] seq;
    logic [4:0] rd;
    logic writes_rd;
    logic [31:0] alu_result, link_pc4, actual_next_pc, pred_next_pc;
    logic branch_taken, pred_taken, pred_hit;
    logic [31:0] branch_target;
    logic is_branch, is_jal, is_jalr;
    logic is_load, is_store;
    logic [31:0] mem_addr;
    logic [1:0] mem_size;
    logic [3:0] mem_wstrb;
    logic [31:0] mem_wdata, store_raw;
    logic [2:0] mem_funct3, mem_class, req_state;
    logic mem_order_barrier, commit_eligible;
    logic [31:0] rsp_data;
    logic rsp_error, result_ready, exception_valid;
    logic [31:0] exception_cause, exception_tval;
    logic is_m;
    logic [31:0] m_result;
    logic m_done;
    logic [SEQ_BITS-1:0] m_owner_seq;
    logic m_owner_killed;
    logic is_csr, is_mret;
    logic [11:0] csr_addr;
    logic csr_write_intent;
    logic [31:0] csr_operand;
    logic fence_op;
    logic [EPOCH_BITS-1:0] epoch;
} cpu5_exmem_t;

typedef struct packed {
    logic [31:0] pc, instr;
    logic [SEQ_BITS-1:0] seq;
    logic [4:0] rd;
    logic writes_rd;
    logic [31:0] result;
    logic [2:0] wb_kind;
    logic [31:0] actual_next_pc;
} cpu5_memwb_t;
