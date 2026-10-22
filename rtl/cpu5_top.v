// SKELETON_ONLY=1 preserves the metadata-only scaffold. =0 enables stage3A-1:
// 21 ALU instructions, MEM retirement/GPR WB; ENABLE_FORWARDING=1 adds 3A-2.
// ENABLE_CONTROL_FLOW adds branches/JAL/JALR; ENABLE_RAM adds ordinary RAM.
// M/CSR/Trap/IRQ remain absent from this isolated CPU5 experiment.
// No board/project references this module; cpu_top is the verified product.
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
    // ID/EX resolution is a real switch when control flow is enabled.
    parameter integer BRANCH_RESOLVE_IN_ID=0,
    parameter integer SEQ_BITS=64, EPOCH_BITS=8, SKELETON_ONLY=1,
    // Opt-in 3A-2 EX/MEM and MEM/WB forwarding; zero preserves the 3A-1 reference.
    parameter integer ENABLE_FORWARDING=0,ENABLE_CONTROL_FLOW=0,ENABLE_RAM=0
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
    wire skeleton_ready,skeleton_ex_valid;
    wire [31:0] skeleton_ex_pc,skeleton_ex_instr;
    wire alu_ready,alu_ex_valid,alu_wb_we,alu_retire_valid;
    wire [31:0] alu_ex_pc,alu_ex_instr,alu_wb_pc,alu_wb_data;
    wire [4:0] alu_wb_rd;
    wire [63:0] alu_cycle_count,alu_instret_count;
    wire alu_redirect,alu_redirect_kill,alu_bp_valid,alu_bp_taken,alu_bp_branch,alu_bp_jal;
    wire [31:0] alu_redirect_pc,alu_bp_pc,alu_bp_target;
    wire [SEQ_BITS-1:0] alu_redirect_seq,alu_bp_seq;
    wire [31:0] alu_bp_resolved,alu_bp_mismatch,alu_bp_direrr,alu_bp_tgterr;
    assign ifid_ready=SKELETON_ONLY!=0?skeleton_ready:alu_ready;
    assign valid_x=SKELETON_ONLY!=0?skeleton_ex_valid:alu_ex_valid;
    assign pc_x=SKELETON_ONLY!=0?skeleton_ex_pc:alu_ex_pc;
    assign instr_x=SKELETON_ONLY!=0?skeleton_ex_instr:alu_ex_instr;

    // IF/ID is the original IF's output register, plus adapter sidebands.
    // No extra IF/ID capture edge is inserted here.
    cpu5_if_adapter #(.PROGRAM_FILE(PROGRAM_FILE),.IMEM_WORDS(IMEM_WORDS),
        .ENABLE_BRANCH_PRED(ENABLE_BRANCH_PRED),.BTB_ENTRIES(BTB_ENTRIES),
        .SEQ_BITS(SEQ_BITS),.EPOCH_BITS(EPOCH_BITS)) u_if_adapter(
        .clk(clk),.rst_n(rst_n),.id_ready(ifid_ready),
        .redirect_valid(alu_redirect),.redirect_ready(unused_redirect_ready),
        .redirect_pc(alu_redirect_pc),.redirect_kill_ifid(alu_redirect_kill),
        .ifid_valid(ifid_valid_q),.ifid_pc(ifid_q.pc),.ifid_instr(ifid_q.instr),
        .ifid_pred_next_pc(ifid_q.pred_next_pc),.ifid_pred_taken(ifid_q.pred_taken),
        .ifid_pred_hit(ifid_q.pred_hit),.ifid_fetch_error(ifid_q.fetch_error),
        .ifid_fetch_tval(ifid_q.fetch_tval),.ifid_seq(ifid_q.seq),.ifid_epoch(ifid_q.epoch),
        .imem_req_valid(imem_req_valid),.imem_req_ready(imem_req_ready),
        .imem_req_addr(imem_req_addr),.imem_rsp_valid(imem_rsp_valid),
        .imem_rsp_ready(imem_rsp_ready),.imem_rsp_rdata(imem_rsp_rdata),.imem_rsp_error(imem_rsp_error),
        .imem_fault(imem_fault),.imem_fault_pc(imem_fault_pc),
        .bp_commit_valid(ENABLE_CONTROL_FLOW && ENABLE_BRANCH_PRED && alu_bp_valid),
        .bp_commit_ready(unused_bp_ready),.bp_commit_seq(alu_bp_seq),
        .bp_commit_pc(alu_bp_pc),.bp_commit_target(alu_bp_target),.bp_commit_taken(alu_bp_taken),
        .bp_commit_is_branch(alu_bp_branch),.bp_commit_is_jal(alu_bp_jal),.bp_update_fire(unused_bp_update),
        .bp_lookup_count(bp_lookup_count),.bp_hit_count(bp_hit_count),.bp_taken_count(bp_taken_count));

    cpu5_pipeline_skeleton #(.SEQ_BITS(SEQ_BITS),.EPOCH_BITS(EPOCH_BITS)) u_pipeline(
        .clk(clk),.rst_n(rst_n),.in_valid(ifid_valid_q&&(SKELETON_ONLY!=0)),.in_ready(skeleton_ready),
        .in_pc(ifid_q.pc),.in_instr(ifid_q.instr),.in_pred_next_pc(ifid_q.pred_next_pc),
        .in_pred_taken(ifid_q.pred_taken),.in_pred_hit(ifid_q.pred_hit),
        .in_fetch_error(ifid_q.fetch_error),.in_fetch_tval(ifid_q.fetch_tval),
        .in_seq(ifid_q.seq),.in_epoch(ifid_q.epoch),
        .id_enable(1'b1),.ex_enable(1'b1),.mem_enable(1'b1),.wb_ready(1'b1),
        .flush_valid(1'b0),.flush_cut_seq({SEQ_BITS{1'b0}}),
        .debug_wb_valid(debug_wb_valid),.debug_wb_pc(debug_wb_pc),
        .debug_wb_instr(debug_wb_instr),.debug_wb_seq(debug_wb_seq),
        .debug_ex_valid(skeleton_ex_valid),.debug_ex_pc(skeleton_ex_pc),.debug_ex_instr(skeleton_ex_instr),
        .debug_ex_epoch(debug_ex_epoch));

    generate if(SKELETON_ONLY==0)begin:g_alu
        cpu5_alu_pipeline #(.SEQ_BITS(SEQ_BITS),.EPOCH_BITS(EPOCH_BITS),.ENABLE_FORWARDING(ENABLE_FORWARDING),
            .ENABLE_CONTROL_FLOW(ENABLE_CONTROL_FLOW),.BRANCH_RESOLVE_IN_ID(BRANCH_RESOLVE_IN_ID),
            .ENABLE_BRANCH_PRED(ENABLE_BRANCH_PRED),.ENABLE_RAM(ENABLE_RAM),
            .DMEM_WORDS(DMEM_WORDS),.DMEM_BASE_ADDR(DMEM_BASE_ADDR)) u_pipeline(
            .clk(clk),.rst_n(rst_n),.in_valid(ifid_valid_q),.in_ready(alu_ready),
            .in_pc(ifid_q.pc),.in_instr(ifid_q.instr),.in_pred_next_pc(ifid_q.pred_next_pc),
            .in_pred_taken(ifid_q.pred_taken),.in_pred_hit(ifid_q.pred_hit),
            .in_fetch_error(ifid_q.fetch_error),.in_fetch_tval(ifid_q.fetch_tval),
            .in_seq(ifid_q.seq),.in_epoch(ifid_q.epoch),
            .id_enable(1'b1),.ex_enable(1'b1),.mem_enable(1'b1),.wb_ready(1'b1),
            .flush_valid(1'b0),.flush_cut_seq({SEQ_BITS{1'b0}}),
            .ex_valid(alu_ex_valid),.ex_pc(alu_ex_pc),.ex_instr(alu_ex_instr),
            .wb_pc(alu_wb_pc),.wb_rd(alu_wb_rd),.wb_data(alu_wb_data),.wb_we(alu_wb_we),
            .retire_valid(alu_retire_valid),.retire_pc(),.retire_instr(),.retire_seq(),
            .retire_rd(),.retire_value(),.retire_writes_rd(),
            .cycle_count(alu_cycle_count),.instret_count(alu_instret_count),.arch_next_pc_q(),
            .halted(),.halt_pc(),.halt_instr(),.halt_seq(),.halt_fetch_error(),
            .id_raw_wait(),.retire_fire(),.wb_fire(),
            .redirect_valid(alu_redirect),.redirect_kill_ifid(alu_redirect_kill),.redirect_pc(alu_redirect_pc),.redirect_seq(alu_redirect_seq),
            .bp_commit_valid(alu_bp_valid),.bp_commit_seq(alu_bp_seq),.bp_commit_pc(alu_bp_pc),.bp_commit_target(alu_bp_target),
            .bp_commit_taken(alu_bp_taken),.bp_commit_is_branch(alu_bp_branch),.bp_commit_is_jal(alu_bp_jal),
            .bp_resolved_count(alu_bp_resolved),.bp_mispredict_count(alu_bp_mismatch),
            .bp_direction_error_count(alu_bp_direrr),.bp_target_error_count(alu_bp_tgterr),.halt_cause(),.halt_tval(),
            .flush_ready(),.flush_fire(),
            .dmem_req_valid(dmem_req_valid),.dmem_req_ready(dmem_req_ready),
            .dmem_req_write(dmem_req_write),.dmem_req_addr(dmem_req_addr),.dmem_req_size(dmem_req_size),
            .dmem_req_wdata(dmem_req_wdata),.dmem_req_wstrb(dmem_req_wstrb),
            .dmem_rsp_valid(dmem_rsp_valid),.dmem_rsp_ready(dmem_rsp_ready),
            .dmem_rsp_rdata(dmem_rsp_rdata),.dmem_rsp_error(dmem_rsp_error),.dmem_fault(dmem_fault));
    end else begin:g_no_alu
        assign {alu_ready,alu_ex_valid,alu_ex_pc,alu_ex_instr,alu_wb_pc,alu_wb_rd,
                alu_wb_data,alu_wb_we,alu_retire_valid,alu_cycle_count,alu_instret_count}=0;
        assign {alu_redirect,alu_redirect_kill,alu_redirect_pc,alu_redirect_seq,alu_bp_valid,alu_bp_pc,alu_bp_target,
                alu_bp_seq,alu_bp_taken,alu_bp_branch,alu_bp_jal,alu_bp_resolved,alu_bp_mismatch,alu_bp_direrr,alu_bp_tgterr}=0;
        assign {dmem_req_valid,dmem_req_write,dmem_req_addr,dmem_req_size,
                dmem_req_wdata,dmem_req_wstrb,dmem_rsp_ready,dmem_fault}=0;
    end endgenerate

    // Forwarding hazard remains an independently verified interface placeholder.
    // The ALU pipeline owns the actual EX forwarding mux when explicitly enabled.
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
    assign wb_pc=alu_wb_pc;assign wb_rd=alu_wb_rd;assign wb_data=alu_wb_data;
    assign wb_we=alu_wb_we;assign retire_valid=alu_retire_valid;
    assign cycle_count=alu_cycle_count;assign instret_count=alu_instret_count;
    // Full ten-class profiling is not connected in this ALU-only subset.
    assign perf_cycle_events=0;
    assign {trap_valid,trap_pc,trap_cause,trap_tval}=0;
    assign bp_resolved_count=alu_bp_resolved;assign bp_mispredict_count=alu_bp_mismatch;
    assign bp_direction_error_count=alu_bp_direrr;assign bp_target_error_count=alu_bp_tgterr;
    assign uart_tx=1'b1;
    assign gpio_out=8'd0; assign gpio_oe=8'd0;
    // synthesis translate_off
    initial begin
        if((SKELETON_ONLY!=0 && SKELETON_ONLY!=1) || EXTERNAL_IMEM!=1 || SEQ_BITS!=64 ||
           (ENABLE_FORWARDING!=0 && ENABLE_FORWARDING!=1) ||
           (ENABLE_CONTROL_FLOW!=0 && ENABLE_CONTROL_FLOW!=1) ||
           (ENABLE_RAM!=0 && ENABLE_RAM!=1) || (ENABLE_RAM && EXTERNAL_DMEM!=1) ||
           (BRANCH_RESOLVE_IN_ID!=0 && BRANCH_RESOLVE_IN_ID!=1))
            $fatal(1,"cpu5_top requires external I, 64-bit age and a supported scaffold/ALU-subset mode");
    end
    always @(posedge clk)if(rst_n && alu_redirect && !unused_redirect_ready)
        $fatal(1,"CPU5 redirect not accepted by the fixed IF adapter protocol");
    // synthesis translate_on
endmodule
