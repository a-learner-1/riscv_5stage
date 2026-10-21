// §10 initial scaffold, METADATA ONLY. This is not a runnable ISA CPU.
// All architecture side effects and counters are disabled. No board/project
// references this module. Use cpu_top for the verified three-stage product.
module cpu5_top #(
    parameter PROGRAM_FILE="programs/rv32i_regression.hex", DATA_FILE="",
    parameter integer IMEM_WORDS=8192, DMEM_WORDS=4096,
    parameter [31:0] DMEM_BASE_ADDR=32'h10000,
    parameter integer UART_CLOCK_HZ=50000000, UART_BAUD=115200,
    parameter integer UART_RX_FIFO_DEPTH=16, SIM_CONSOLE_ECHO=0,
    parameter integer EXTERNAL_DMEM=1, DMEM_REQ_WAIT_CYCLES=0,
    parameter integer DMEM_RSP_WAIT_CYCLES=0, EXTERNAL_IMEM=1,
    parameter integer IMEM_REQ_WAIT_CYCLES=0, IMEM_RSP_WAIT_CYCLES=0,
    parameter integer ENABLE_TRAPS=1, ENABLE_TIMER_IRQ=0,
    parameter integer ENABLE_BRANCH_PRED=0, BTB_ENTRIES=64,
    parameter integer ENABLE_EXTERNAL_IRQ=0, ENABLE_SOFTWARE_IRQ=0, ENABLE_M=1,
    // Provisional EX selection; no branch executor exists in this scaffold.
    // Keep both values elaboratable; final selection requires CPU5 A/B.
    parameter integer BRANCH_RESOLVE_IN_ID=0,
    parameter integer SEQ_BITS=64, EPOCH_BITS=8, SKELETON_ONLY=1
)(
    input wire clk,rst_n,
    output wire [31:0] pc_x,instr_x, output wire valid_x,
    output wire [31:0] wb_pc, output wire [4:0] wb_rd,
    output wire [31:0] wb_data, output wire wb_we,retire_valid,
    output wire [63:0] cycle_count,instret_count,
    output wire uart_tx, input wire uart_rx, input wire [7:0] gpio_in,
    output wire [7:0] gpio_out,gpio_oe,
    output wire dmem_req_valid, input wire dmem_req_ready,
    output wire dmem_req_write, output wire [31:0] dmem_req_addr,
    output wire [1:0] dmem_req_size, output wire [31:0] dmem_req_wdata,
    output wire [3:0] dmem_req_wstrb,
    input wire dmem_rsp_valid, output wire dmem_rsp_ready,
    input wire [31:0] dmem_rsp_rdata, input wire dmem_rsp_error,
    output wire dmem_fault,
    output wire imem_req_valid, input wire imem_req_ready,
    output wire [31:0] imem_req_addr,
    input wire imem_rsp_valid, output wire imem_rsp_ready,
    input wire [31:0] imem_rsp_rdata, input wire imem_rsp_error,
    output wire imem_fault, output wire [31:0] imem_fault_pc,
    output wire trap_valid, output wire [31:0] trap_pc,trap_cause,trap_tval,
    output wire [31:0] bp_lookup_count,bp_hit_count,bp_taken_count,
    output wire [31:0] bp_resolved_count,bp_mispredict_count,
    output wire [31:0] bp_direction_error_count,bp_target_error_count,
    input wire irq_external,
    // New width is explicit. Classification hardware is NOT IMPLEMENTED.
    output wire [9:0] perf_cycle_events
);
    `include "rtl/cpu5_pipeline_types.vh"
    wire ifid_valid_q,ifid_ready;
    cpu5_ifid_t ifid_q;
    wire debug_wb_valid;
    wire [31:0] debug_wb_pc,debug_wb_instr;
    wire [SEQ_BITS-1:0] debug_wb_seq;
    wire [EPOCH_BITS-1:0] debug_ex_epoch;
    wire unused_redirect_ready,unused_bp_ready,unused_bp_update;

    // IF/ID is the original IF's output register, plus adapter sidebands.
    // No extra IF/ID capture edge is inserted here.
    cpu5_if_adapter #(.PROGRAM_FILE(PROGRAM_FILE),.IMEM_WORDS(IMEM_WORDS),
        .ENABLE_BRANCH_PRED(ENABLE_BRANCH_PRED),.BTB_ENTRIES(BTB_ENTRIES),
        .SEQ_BITS(SEQ_BITS),.EPOCH_BITS(EPOCH_BITS)) u_if_adapter(
        .clk(clk),.rst_n(rst_n),.id_ready(ifid_ready),
        .redirect_valid(1'b0),.redirect_ready(unused_redirect_ready),
        .redirect_pc(32'd0),.redirect_kill_ifid(1'b0),
        .ifid_valid(ifid_valid_q),.ifid_pc(ifid_q.pc),.ifid_instr(ifid_q.instr),
        .ifid_pred_next_pc(ifid_q.pred_next_pc),.ifid_pred_taken(ifid_q.pred_taken),
        .ifid_pred_hit(ifid_q.pred_hit),.ifid_fetch_error(ifid_q.fetch_error),
        .ifid_fetch_tval(ifid_q.fetch_tval),.ifid_seq(ifid_q.seq),.ifid_epoch(ifid_q.epoch),
        .imem_req_valid(imem_req_valid),.imem_req_ready(imem_req_ready),
        .imem_req_addr(imem_req_addr),.imem_rsp_valid(imem_rsp_valid),
        .imem_rsp_ready(imem_rsp_ready),.imem_rsp_rdata(imem_rsp_rdata),.imem_rsp_error(imem_rsp_error),
        .imem_fault(imem_fault),.imem_fault_pc(imem_fault_pc),
        .bp_commit_valid(1'b0),.bp_commit_ready(unused_bp_ready),.bp_commit_seq({SEQ_BITS{1'b0}}),
        .bp_commit_pc(32'd0),.bp_commit_target(32'd0),.bp_commit_taken(1'b0),
        .bp_commit_is_branch(1'b0),.bp_commit_is_jal(1'b0),.bp_update_fire(unused_bp_update),
        .bp_lookup_count(bp_lookup_count),.bp_hit_count(bp_hit_count),.bp_taken_count(bp_taken_count));

    cpu5_pipeline_skeleton #(.SEQ_BITS(SEQ_BITS),.EPOCH_BITS(EPOCH_BITS)) u_pipeline(
        .clk(clk),.rst_n(rst_n),.in_valid(ifid_valid_q),.in_ready(ifid_ready),
        .in_pc(ifid_q.pc),.in_instr(ifid_q.instr),.in_pred_next_pc(ifid_q.pred_next_pc),
        .in_pred_taken(ifid_q.pred_taken),.in_pred_hit(ifid_q.pred_hit),
        .in_fetch_error(ifid_q.fetch_error),.in_fetch_tval(ifid_q.fetch_tval),
        .in_seq(ifid_q.seq),.in_epoch(ifid_q.epoch),
        .id_enable(1'b1),.ex_enable(1'b1),.mem_enable(1'b1),.wb_ready(1'b1),
        .flush_valid(1'b0),.flush_cut_seq({SEQ_BITS{1'b0}}),
        .debug_wb_valid(debug_wb_valid),.debug_wb_pc(debug_wb_pc),
        .debug_wb_instr(debug_wb_instr),.debug_wb_seq(debug_wb_seq),
        .debug_ex_valid(valid_x),.debug_ex_pc(pc_x),.debug_ex_instr(instr_x),
        .debug_ex_epoch(debug_ex_epoch));

    // No decoder, regfile, ALU, D/M owner or commit controller is implemented.
    // The integrated hazard instance is present for interface elaboration only;
    // its real truth table is tested independently before ISA wiring begins.
    wire [31:0] placeholder_rs1,placeholder_rs2;
    wire [2:0] placeholder_fwd1,placeholder_fwd2;
    wire placeholder_stall,unused_stall1,unused_stall2,unused_ex1,unused_ex2,unused_ex;
    cpu5_hazard #(.CHECK_EX_PRODUCER(BRANCH_RESOLVE_IN_ID)) u_hazard(
        .consumer_valid(1'b0),.uses_rs1(1'b0),.uses_rs2(1'b0),.rs1(5'd0),.rs2(5'd0),
        .rf_rs1_value(32'd0),.rf_rs2_value(32'd0),
        .ex_valid(1'b0),.ex_writes_rd(1'b0),.ex_rd(5'd0),.ex_result_ready(1'b0),
        .mem_valid(1'b0),.mem_writes_rd(1'b0),.mem_rd(5'd0),.mem_result_ready(1'b0),.mem_result_value(32'd0),
        .wb_valid(1'b0),.wb_writes_rd(1'b0),.wb_rd(5'd0),.wb_result_ready(1'b0),.wb_result_value(32'd0),
        .rs1_value(placeholder_rs1),.rs2_value(placeholder_rs2),.fwd1(placeholder_fwd1),.fwd2(placeholder_fwd2),
        .stall1(unused_stall1),.stall2(unused_stall2),.stall(placeholder_stall),
        .ex_block1(unused_ex1),.ex_block2(unused_ex2),.ex_block(unused_ex));
    assign {wb_pc,wb_rd,wb_data,wb_we,retire_valid}=0;
    assign {cycle_count,instret_count,perf_cycle_events}=0;
    assign {dmem_req_valid,dmem_req_write,dmem_req_addr,dmem_req_size,
            dmem_req_wdata,dmem_req_wstrb,dmem_rsp_ready,dmem_fault}=0;
    assign {trap_valid,trap_pc,trap_cause,trap_tval}=0;
    assign {bp_resolved_count,bp_mispredict_count,bp_direction_error_count,bp_target_error_count}=0;
    assign uart_tx=1'b1;
    assign gpio_out=8'd0; assign gpio_oe=8'd0;
    // synthesis translate_off
    initial begin
        if(SKELETON_ONLY!=1 || EXTERNAL_IMEM!=1 || SEQ_BITS!=64 ||
           (BRANCH_RESOLVE_IN_ID!=0 && BRANCH_RESOLVE_IN_ID!=1))
            $fatal(1,"cpu5_top is metadata-only, external-I scaffold; ISA execution NOT IMPLEMENTED");
    end
    // synthesis translate_on
endmodule
