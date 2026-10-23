// CPU5 ALU subset: stage 3A-1 reference or opt-in stage 3A-2 forwarding.
// Optional control flow, ordinary RAM and fixed-vector synchronous traps.
// M, software-visible CSR/MRET and IRQ remain outside this stage.
// The unchanged regfile defines only x0 after reset; software initializes x1..31.
module cpu5_alu_pipeline #(
    parameter integer SEQ_BITS=64,EPOCH_BITS=8,ENABLE_FORWARDING=0,
    ENABLE_CONTROL_FLOW=0,BRANCH_RESOLVE_IN_ID=0,ENABLE_BRANCH_PRED=0,
    ENABLE_RAM=0,DMEM_WORDS=4096,ENABLE_SYNC_TRAPS=0,
    parameter [31:0] DMEM_BASE_ADDR=32'h00010000,TRAP_VECTOR=32'h00000100
)(
    input wire clk,rst_n,
    input wire in_valid,output wire in_ready,
    input wire [31:0] in_pc,in_instr,in_pred_next_pc,
    input wire in_pred_taken,in_pred_hit,in_fetch_error,
    input wire [31:0] in_fetch_tval,
    input wire [SEQ_BITS-1:0] in_seq,
    input wire [EPOCH_BITS-1:0] in_epoch,
    input wire id_enable,ex_enable,mem_enable,wb_ready,
    // First killed, unretired age. Upstream must cancel its killed IFID token.
    input wire flush_valid,input wire [SEQ_BITS-1:0] flush_cut_seq,
    output wire ex_valid,output wire [31:0] ex_pc,ex_instr,
    output wire [31:0] wb_pc,wb_data,output wire [4:0] wb_rd,output wire wb_we,
    output reg retire_valid,
    output reg [31:0] retire_pc,retire_instr,retire_value,
    output reg [4:0] retire_rd,output reg retire_writes_rd,
    output reg [SEQ_BITS-1:0] retire_seq,
    output reg [63:0] cycle_count,instret_count,
    output reg [31:0] arch_next_pc_q,
    output wire halted,output wire [31:0] halt_pc,halt_instr,
    output wire [SEQ_BITS-1:0] halt_seq,
    output wire halt_fetch_error,
    output wire id_raw_wait,
    output wire retire_fire,wb_fire,
    // Current IF adapter guarantees acceptance for an ID transfer or EX kill.
    output wire redirect_valid,redirect_kill_ifid,output wire [31:0] redirect_pc,
    output wire [SEQ_BITS-1:0] redirect_seq,
    output wire bp_commit_valid,output wire [SEQ_BITS-1:0] bp_commit_seq,
    output wire [31:0] bp_commit_pc,bp_commit_target,
    output wire bp_commit_taken,bp_commit_is_branch,bp_commit_is_jal,
    output reg [31:0] bp_resolved_count,bp_mispredict_count,
    output reg [31:0] bp_direction_error_count,bp_target_error_count,
    output wire [31:0] halt_cause,halt_tval,
    // A caller must retain a flush while an older irrevocable STORE rejects it.
    output wire flush_ready,flush_fire,
    output wire dmem_req_valid,input wire dmem_req_ready,
    output wire dmem_req_write,output wire [31:0] dmem_req_addr,
    output wire [1:0] dmem_req_size,output wire [31:0] dmem_req_wdata,
    output wire [3:0] dmem_req_wstrb,
    input wire dmem_rsp_valid,output wire dmem_rsp_ready,
    input wire [31:0] dmem_rsp_rdata,input wire dmem_rsp_error,
    output wire dmem_fault,
    output wire trap_fire,output reg trap_valid,
    output reg [31:0] trap_pc,trap_cause,trap_tval,
    output reg [SEQ_BITS-1:0] trap_seq
);
    `include "rtl/cpu5_pipeline_types.vh"
    reg idex_valid_q,exmem_valid_q,memwb_valid_q;
    cpu5_idex_t idex_q,idex_next;
    cpu5_exmem_t exmem_q,exmem_next;
    cpu5_memwb_t memwb_q,memwb_next;
    reg idex_supported_q,exmem_supported_q;
    reg [31:0] idex_alu_a_q,idex_alu_b_q;
    reg idex_a_pc_q,idex_a_zero_q,idex_b_imm_q;
    reg [31:0] idex_cf_next_q,idex_cf_target_q;
    reg idex_cf_taken_q;
    wire ram_supported,ram_load,ram_store,ram_uses1,ram_uses2,ram_writes;
    wire [4:0] ram_rs1,ram_rs2,ram_rd;
    wire [31:0] ram_imm,ram_ex_addr,ram_ex_wdata,ram_ex_fault_cause,ram_load_value;
    wire [1:0] ram_ex_size;wire [3:0] ram_ex_wstrb;
    wire ram_ex_fault;
    wire ram_owner_valid,ram_owner_store,ram_owner_killed,ram_owner_sent,ram_store_lock;
    wire [SEQ_BITS-1:0] ram_owner_seq,ram_req_seq,ram_rsp_seq,ram_completion_seq;
    wire [31:0] ram_req_pc,ram_req_instr,ram_rsp_pc,ram_rsp_instr;
    wire ram_completion_valid,ram_completion_ready,ram_completion_error,ram_completion_killed,ram_completion_store;
    wire [31:0] ram_completion_pc,ram_completion_instr,ram_completion_data,ram_completion_addr;
    wire [EPOCH_BITS-1:0] ram_completion_epoch;
    wire [2:0] ram_completion_funct3;
    wire ram_issue_valid,ram_issue_ready,ram_issue_fire,ram_issue_store,ram_req_fire,ram_rsp_fire;
    wire [1:0] ram_owner_state;
    wire [31:0] mem_result_value;
    wire mem_result_ready;
    wire supported,uses_rs1,uses_rs2,writes_rd,a_pc,a_zero,b_imm;
    wire [4:0] rs1,rs2,rd;
    wire [31:0] imm,rf1,rf2,alu_result;
    wire [3:0] alu_op;
    wire alu_supported,alu_uses1,alu_uses2,alu_writes;
    wire [4:0] alu_rs1,alu_rs2,alu_rd;
    wire [31:0] alu_imm;
    wire cf_supported,cf_branch,cf_jal,cf_jalr,cf_uses1,cf_uses2,cf_writes;
    wire [4:0] cf_rs1,cf_rs2,cf_rd;
    wire [31:0] cf_imm,id_target,id_next_pc,id_link;
    wire id_taken,id_misaligned,id_branch_stall;
    wire [31:0] id_branch_rs1,id_branch_rs2;
    wire [31:0] ex_target_calc,ex_next_calc,ex_link;
    wire ex_taken_calc,ex_misaligned_calc;
    wire ex_is_cf=idex_q.is_branch||idex_q.is_jal||idex_q.is_jalr;
    wire [31:0] ex_actual_next=BRANCH_RESOLVE_IN_ID?idex_cf_next_q:ex_next_calc;
    wire [31:0] ex_branch_target=BRANCH_RESOLVE_IN_ID?idex_cf_target_q:ex_target_calc;
    wire ex_branch_taken=BRANCH_RESOLVE_IN_ID?idex_cf_taken_q:ex_taken_calc;
    wire ex_target_fault=ENABLE_CONTROL_FLOW && !BRANCH_RESOLVE_IN_ID && ex_is_cf &&
        !idex_q.exception_valid && ex_misaligned_calc;
    cpu5_alu_decode u_decode(.instr(in_instr),.supported(alu_supported),
        .uses_rs1(alu_uses1),.uses_rs2(alu_uses2),.writes_rd(alu_writes),
        .rs1(alu_rs1),.rs2(alu_rs2),.rd(alu_rd),.imm(alu_imm),.alu_op(alu_op),
        .alu_a_pc(a_pc),.alu_a_zero(a_zero),.alu_b_imm(b_imm));
    wire id_ecall=ENABLE_SYNC_TRAPS && in_instr==32'h00000073;
    wire id_ebreak=ENABLE_SYNC_TRAPS && in_instr==32'h00100073;
    assign supported=alu_supported||cf_supported||ram_supported||id_ecall||id_ebreak;
    wire id_illegal=ENABLE_SYNC_TRAPS && !supported;
    assign {uses_rs1,uses_rs2,writes_rd}=ram_supported?{ram_uses1,ram_uses2,ram_writes}:
        cf_supported?{cf_uses1,cf_uses2,cf_writes}:{alu_uses1,alu_uses2,alu_writes};
    assign rs1=ram_supported?ram_rs1:cf_supported?cf_rs1:alu_rs1;
    assign rs2=ram_supported?ram_rs2:cf_supported?cf_rs2:alu_rs2;
    assign rd=ram_supported?ram_rd:cf_supported?cf_rd:alu_rd;
    assign imm=ram_supported?ram_imm:cf_supported?cf_imm:alu_imm;
    regfile u_regfile(.clk(clk),.we(wb_we),.rs1_addr(rs1),.rs2_addr(rs2),
        .rd_addr(wb_rd),.rd_data(wb_data),.rs1_data(rf1),.rs2_data(rf2));
    wire [31:0] ex_rs1_value,ex_rs2_value;
    wire [2:0] ex_fwd1,ex_fwd2;
    wire ex_source_stall,ex_stall1,ex_stall2;
    wire [31:0] alu_a=ENABLE_FORWARDING ?
        (idex_a_pc_q?idex_q.pc:idex_a_zero_q?32'd0:ex_rs1_value):idex_alu_a_q;
    wire [31:0] alu_b=ENABLE_FORWARDING ?
        (idex_b_imm_q?idex_q.imm:ex_rs2_value):idex_alu_b_q;
    alu u_alu(.a(alu_a),.b(alu_b),.alu_op(idex_q.alu_op),.result(alu_result));
    assign flush_ready=!ENABLE_RAM || !flush_valid ||
        !(ram_store_lock && flush_cut_seq<=ram_owner_seq);
    assign flush_fire=flush_valid && flush_ready;
    wire kill_input=flush_fire && in_seq>=flush_cut_seq;
    wire kill_ex=flush_fire && idex_q.seq>=flush_cut_seq;
    wire kill_mem=flush_fire && exmem_q.seq>=flush_cut_seq;
    wire ex_is_mem=idex_q.is_load||idex_q.is_store;
    wire ex_ram_fault=ENABLE_RAM && ex_is_mem && !idex_q.exception_valid && ram_ex_fault;
    wire ram_mem_matches=ENABLE_RAM && ram_completion_valid && exmem_valid_q &&
        ram_completion_seq==exmem_q.seq && !ram_completion_killed;
    wire ram_mem_error=ram_mem_matches && (exmem_q.is_load||exmem_q.is_store) && ram_completion_error;
    assign mem_result_ready=(exmem_q.is_load||exmem_q.is_store)?
        (ram_mem_matches && !ram_completion_error):exmem_q.result_ready;
    assign mem_result_value=exmem_q.is_load?ram_load_value:exmem_q.is_store?32'd0:exmem_q.alu_result;
    // WB was already retired at an earlier MEM edge and is never age-killed.
    assign wb_fire=rst_n && memwb_valid_q && wb_ready;
    assign wb_we=wb_fire && memwb_q.writes_rd && memwb_q.rd!=0;
    assign wb_pc=memwb_q.pc;assign wb_rd=memwb_q.rd;assign wb_data=memwb_q.result;
    wire wb_can_load=!memwb_valid_q || wb_fire;
    wire mem_fault=rst_n && exmem_valid_q && !kill_mem &&
        (!exmem_supported_q || exmem_q.exception_valid || ram_mem_error);
    assign halted=mem_fault && !ENABLE_SYNC_TRAPS;
    // Fault delivery needs no new WB slot. An already retired WB remains
    // independent and may be held or write at the same edge as this trap.
    wire trap_safe=!ram_store_lock || (ram_mem_matches && ram_completion_error);
    assign trap_fire=ENABLE_SYNC_TRAPS && mem_fault && mem_enable && trap_safe;
    assign halt_pc=exmem_q.pc;assign halt_instr=exmem_q.instr;
    assign halt_seq=exmem_q.seq;
    assign halt_fetch_error=exmem_q.exception_valid && exmem_q.exception_cause==1;
    assign halt_cause=ram_mem_error?(exmem_q.is_store?32'd7:32'd5):exmem_q.exception_cause;
    assign halt_tval=ram_mem_error?exmem_q.mem_addr:exmem_q.exception_tval;
    assign dmem_fault=ENABLE_RAM && mem_fault && (exmem_q.is_load||exmem_q.is_store) &&
        halt_cause>=4 && halt_cause<=7;
    assign retire_fire=rst_n && exmem_valid_q && !kill_mem && !mem_fault &&
        mem_result_ready && mem_enable && wb_can_load;
    wire mem_can_load=!exmem_valid_q || kill_mem || retire_fire || trap_fire;
    wire ex_base_move=rst_n && idex_valid_q && !kill_ex && !trap_fire && ex_enable && mem_can_load &&
        (!ENABLE_FORWARDING || !ex_source_stall) && !((ENABLE_CONTROL_FLOW||ENABLE_RAM) && flush_valid);
    wire ex_load_request=ENABLE_RAM && idex_q.is_load && !idex_q.exception_valid && !ex_ram_fault && ex_base_move;
    wire ex_move=ex_base_move && (!ex_load_request || ram_issue_ready);
    wire ex_can_load=!idex_valid_q || kill_ex || ex_move || trap_fire;
    // A STORE is first offered only by the oldest live, commit-qualified MEM
    // packet. Once offered, the owner retains it regardless of later stalls.
    wire ram_mem_owned=ram_owner_valid && ram_owner_seq==exmem_q.seq;
    wire mem_store_request=ENABLE_RAM && rst_n && exmem_valid_q && !kill_mem &&
        exmem_q.is_store && exmem_supported_q && !exmem_q.exception_valid &&
        mem_enable && !flush_valid && !mem_fault && !ram_mem_owned;
    assign ram_issue_valid=mem_store_request || ex_load_request;
    assign ram_issue_store=mem_store_request;
    // A faulting source completion is acknowledged, not marked killed. Only
    // younger owners are age-killed; killing this source combinationally would
    // feed completion_killed back into fault detection and cancel the trap.
    assign ram_completion_ready=ram_mem_matches && (retire_fire || trap_fire);
    wire owner_kill_valid=flush_fire || trap_fire;
    wire [SEQ_BITS-1:0] owner_kill_cut=flush_fire?flush_cut_seq:exmem_q.seq+1'b1;
    generate if(ENABLE_RAM)begin:g_ram
        cpu5_ram_unit #(.DMEM_BASE_ADDR(DMEM_BASE_ADDR),.DMEM_WORDS(DMEM_WORDS)) u_decode(
            .instr(in_instr),.rs1_value(rf1),.rs2_value(rf2),.response_word(32'd0),
            .supported(ram_supported),.is_load(ram_load),.is_store(ram_store),
            .uses_rs1(ram_uses1),.uses_rs2(ram_uses2),.writes_rd(ram_writes),
            .rs1(ram_rs1),.rs2(ram_rs2),.rd(ram_rd),.imm(ram_imm),
            .addr(),.wdata(),.load_value(),.size(),.wstrb(),.misaligned(),
            .out_of_range(),.fault(),.fault_cause());
        cpu5_ram_unit #(.DMEM_BASE_ADDR(DMEM_BASE_ADDR),.DMEM_WORDS(DMEM_WORDS)) u_ex(
            .instr(idex_q.instr),.rs1_value(ex_rs1_value),.rs2_value(ex_rs2_value),
            .response_word(32'd0),.supported(),.is_load(),.is_store(),
            .uses_rs1(),.uses_rs2(),.writes_rd(),.rs1(),.rs2(),.rd(),.imm(),
            .addr(ram_ex_addr),.wdata(ram_ex_wdata),.load_value(),.size(ram_ex_size),
            .wstrb(ram_ex_wstrb),.misaligned(),.out_of_range(),
            .fault(ram_ex_fault),.fault_cause(ram_ex_fault_cause));
        cpu5_ram_unit #(.DMEM_BASE_ADDR(DMEM_BASE_ADDR),.DMEM_WORDS(DMEM_WORDS)) u_load_format(
            .instr({12'd0,5'd0,exmem_q.mem_funct3,5'd1,7'h03}),
            .rs1_value(exmem_q.mem_addr),.rs2_value(32'd0),.response_word(ram_completion_data),
            .supported(),.is_load(),.is_store(),.uses_rs1(),.uses_rs2(),.writes_rd(),
            .rs1(),.rs2(),.rd(),.imm(),.addr(),.wdata(),.load_value(ram_load_value),
            .size(),.wstrb(),.misaligned(),.out_of_range(),.fault(),.fault_cause());
        cpu5_ram_owner #(.SEQ_BITS(SEQ_BITS),.EPOCH_BITS(EPOCH_BITS)) u_owner(
            .clk(clk),.rst_n(rst_n),.issue_valid(ram_issue_valid),.issue_ready(ram_issue_ready),
            .issue_fire(ram_issue_fire),.issue_is_store(ram_issue_store),
            .issue_seq(mem_store_request?exmem_q.seq:idex_q.seq),
            .issue_pc(mem_store_request?exmem_q.pc:idex_q.pc),
            .issue_instr(mem_store_request?exmem_q.instr:idex_q.instr),
            .issue_epoch(mem_store_request?exmem_q.epoch:idex_q.epoch),
            .issue_addr(mem_store_request?exmem_q.mem_addr:ram_ex_addr),
            .issue_size(mem_store_request?exmem_q.mem_size:ram_ex_size),
            .issue_wdata(mem_store_request?exmem_q.mem_wdata:ram_ex_wdata),
            .issue_wstrb(mem_store_request?exmem_q.mem_wstrb:ram_ex_wstrb),
            .issue_funct3(mem_store_request?exmem_q.mem_funct3:idex_q.funct3),
            .kill_valid(owner_kill_valid),.kill_cut_seq(owner_kill_cut),
            .dmem_req_valid(dmem_req_valid),.dmem_req_ready(dmem_req_ready),
            .dmem_req_write(dmem_req_write),.dmem_req_addr(dmem_req_addr),.dmem_req_size(dmem_req_size),
            .dmem_req_wdata(dmem_req_wdata),.dmem_req_wstrb(dmem_req_wstrb),
            .dmem_rsp_valid(dmem_rsp_valid),.dmem_rsp_ready(dmem_rsp_ready),
            .dmem_rsp_rdata(dmem_rsp_rdata),.dmem_rsp_error(dmem_rsp_error),
            .completion_valid(ram_completion_valid),.completion_ready(ram_completion_ready),
            .completion_seq(ram_completion_seq),.completion_pc(ram_completion_pc),
            .completion_instr(ram_completion_instr),.completion_epoch(ram_completion_epoch),
            .completion_rdata(ram_completion_data),.completion_error(ram_completion_error),
            .completion_killed(ram_completion_killed),.completion_is_store(ram_completion_store),
            .completion_addr(ram_completion_addr),.completion_funct3(ram_completion_funct3),
            .owner_valid(ram_owner_valid),.owner_seq(ram_owner_seq),.owner_is_store(ram_owner_store),
            .owner_killed(ram_owner_killed),.owner_sent(ram_owner_sent),.store_lock(ram_store_lock),
            .req_owner_seq(ram_req_seq),.rsp_owner_seq(ram_rsp_seq),
            .req_owner_pc(ram_req_pc),.req_owner_instr(ram_req_instr),
            .rsp_owner_pc(ram_rsp_pc),.rsp_owner_instr(ram_rsp_instr),
            .req_fire(ram_req_fire),.rsp_fire(ram_rsp_fire),.state_debug(ram_owner_state));
    end else begin:g_no_ram
        assign {ram_supported,ram_load,ram_store,ram_uses1,ram_uses2,ram_writes,
                ram_rs1,ram_rs2,ram_rd,ram_imm,ram_ex_addr,ram_ex_wdata,ram_ex_fault_cause,
                ram_load_value,ram_ex_size,ram_ex_wstrb,ram_ex_fault,
                ram_owner_valid,ram_owner_store,ram_owner_killed,ram_owner_sent,ram_store_lock,
                ram_owner_seq,ram_req_seq,ram_rsp_seq,ram_completion_seq,ram_req_pc,ram_req_instr,
                ram_rsp_pc,ram_rsp_instr,ram_completion_valid,ram_completion_error,
                ram_completion_killed,ram_completion_store,ram_completion_pc,ram_completion_instr,
                ram_completion_data,ram_completion_addr,ram_completion_epoch,ram_completion_funct3,
                ram_issue_ready,ram_issue_fire,ram_req_fire,ram_rsp_fire,ram_owner_state,
                dmem_req_valid,dmem_req_write,dmem_req_addr,dmem_req_size,dmem_req_wdata,
                dmem_req_wstrb,dmem_rsp_ready}=0;
    end endgenerate

    // 3A-1 deliberately waits until every older writer physically leaves WB.
    // Even a WB write at this edge is not yet visible to the pre-edge ID read.
    wire ex_writer=idex_valid_q && !kill_ex && idex_q.writes_rd && idex_q.rd!=0;
    wire mem_writer=exmem_valid_q && !kill_mem && exmem_q.writes_rd && exmem_q.rd!=0;
    wire wb_writer=memwb_valid_q && memwb_q.writes_rd && memwb_q.rd!=0;
    wire pending_rs1=rs1!=0 && ((ex_writer&&idex_q.rd==rs1) ||
        (mem_writer&&exmem_q.rd==rs1) || (wb_writer&&memwb_q.rd==rs1));
    wire pending_rs2=rs2!=0 && ((ex_writer&&idex_q.rd==rs2) ||
        (mem_writer&&exmem_q.rd==rs2) || (wb_writer&&memwb_q.rd==rs2));
    wire known_ex_fault=idex_valid_q && !kill_ex &&
        (!idex_supported_q || idex_q.exception_valid || ex_target_fault || ex_ram_fault);
    // Memory instructions repair stale predictions in EX, after validating
    // their effective address, even when branches resolve in ID.
    wire ex_redirect=ENABLE_CONTROL_FLOW && (!BRANCH_RESOLVE_IN_ID || ex_is_mem) && !flush_valid &&
        ex_move && idex_supported_q && !idex_q.exception_valid && !ex_target_fault && !ex_ram_fault &&
        ex_actual_next!=idex_q.pred_next_pc;
    assign id_raw_wait=(!ENABLE_FORWARDING && in_valid && !in_fetch_error && supported &&
        ((uses_rs1&&pending_rs1) || (uses_rs2&&pending_rs2))) || id_branch_stall;
    assign in_ready=rst_n && id_enable && !kill_input && !trap_fire &&
        !(ENABLE_SYNC_TRAPS && mem_fault) && !id_raw_wait && ex_can_load &&
        !ex_redirect && !((ENABLE_CONTROL_FLOW||ENABLE_RAM) && flush_valid) &&
        !(ENABLE_CONTROL_FLOW && BRANCH_RESOLVE_IN_ID && known_ex_fault);
    wire id_move=in_valid && in_ready;
    assign ex_valid=rst_n && idex_valid_q && !kill_ex;
    assign ex_pc=idex_q.pc;assign ex_instr=idex_q.instr;

    // WB data exists while the retired packet is held, even if wb_ready=0.
    // Capture it at ID so a same-edge physical write/drain cannot leave a stale
    // saved RF value for the consumer's later EX cycle.
    wire [31:0] id_saved_rs1=ENABLE_CONTROL_FLOW && BRANCH_RESOLVE_IN_ID && cf_supported ? id_branch_rs1 :
        ENABLE_FORWARDING && uses_rs1 && rs1!=0 && wb_writer && memwb_q.rd==rs1 ? memwb_q.result : rf1;
    wire [31:0] id_saved_rs2=ENABLE_CONTROL_FLOW && BRANCH_RESOLVE_IN_ID && cf_supported ? id_branch_rs2 :
        ENABLE_FORWARDING && uses_rs2 && rs2!=0 && wb_writer && memwb_q.rd==rs2 ? memwb_q.result : rf2;
    wire id_target_fault=ENABLE_CONTROL_FLOW && BRANCH_RESOLVE_IN_ID && cf_supported && id_misaligned;
    wire id_redirect=ENABLE_CONTROL_FLOW && BRANCH_RESOLVE_IN_ID && !flush_valid &&
        !mem_fault && !known_ex_fault && id_move && supported && !ram_supported &&
        !id_ecall && !id_ebreak && !in_fetch_error && !id_target_fault &&
        id_next_pc!=in_pred_next_pc;
    assign redirect_valid=trap_fire||ex_redirect||id_redirect;
    assign redirect_kill_ifid=trap_fire||ex_redirect;
    assign redirect_pc=trap_fire?TRAP_VECTOR:ex_redirect?ex_actual_next:id_next_pc;
    assign redirect_seq=trap_fire?exmem_q.seq:ex_redirect?idex_q.seq:in_seq;
    assign bp_commit_valid=ENABLE_CONTROL_FLOW && retire_fire;
    assign bp_commit_seq=exmem_q.seq;assign bp_commit_pc=exmem_q.pc;
    assign bp_commit_target=exmem_q.branch_target;assign bp_commit_taken=exmem_q.branch_taken;
    assign bp_commit_is_branch=exmem_q.is_branch;assign bp_commit_is_jal=exmem_q.is_jal;
    generate if(ENABLE_CONTROL_FLOW)begin:g_control_flow
        cpu5_branch_unit u_id_unit(.instr(in_instr),.pc(in_pc),
            .rs1_value(id_branch_rs1),.rs2_value(id_branch_rs2),
            .supported(cf_supported),.is_branch(cf_branch),.is_jal(cf_jal),.is_jalr(cf_jalr),
            .uses_rs1(cf_uses1),.uses_rs2(cf_uses2),.writes_rd(cf_writes),
            .rs1(cf_rs1),.rs2(cf_rs2),.rd(cf_rd),.imm(cf_imm),
            .target(id_target),.actual_next_pc(id_next_pc),.link_value(id_link),
            .taken(id_taken),.misaligned(id_misaligned));
        cpu5_branch_unit u_ex_unit(.instr(idex_q.instr),.pc(idex_q.pc),
            .rs1_value(ENABLE_FORWARDING?ex_rs1_value:idex_q.rs1_value),
            .rs2_value(ENABLE_FORWARDING?ex_rs2_value:idex_q.rs2_value),
            .supported(),.is_branch(),.is_jal(),.is_jalr(),.uses_rs1(),.uses_rs2(),.writes_rd(),
            .rs1(),.rs2(),.rd(),.imm(),.target(ex_target_calc),.actual_next_pc(ex_next_calc),
            .link_value(ex_link),.taken(ex_taken_calc),.misaligned(ex_misaligned_calc));
        cpu5_hazard #(.CHECK_EX_PRODUCER(1)) u_id_hazard(
            .consumer_valid(in_valid && !in_fetch_error && cf_supported && BRANCH_RESOLVE_IN_ID),
            .uses_rs1(cf_uses1),.uses_rs2(cf_uses2),.rs1(cf_rs1),.rs2(cf_rs2),
            .rf_rs1_value(rf1),.rf_rs2_value(rf2),
            .ex_valid(idex_valid_q && !kill_ex),.ex_writes_rd(idex_q.writes_rd),.ex_rd(idex_q.rd),.ex_result_ready(1'b0),
            .mem_valid(exmem_valid_q && !kill_mem),.mem_writes_rd(exmem_q.writes_rd),.mem_rd(exmem_q.rd),
            .mem_result_ready(exmem_supported_q && !exmem_q.exception_valid && mem_result_ready),.mem_result_value(mem_result_value),
            .wb_valid(memwb_valid_q),.wb_writes_rd(memwb_q.writes_rd),.wb_rd(memwb_q.rd),
            .wb_result_ready(1'b1),.wb_result_value(memwb_q.result),
            .rs1_value(id_branch_rs1),.rs2_value(id_branch_rs2),.fwd1(),.fwd2(),
            .stall(id_branch_stall),.stall1(),.stall2(),.ex_block(),.ex_block1(),.ex_block2());
    end else begin:g_no_control_flow
        assign {cf_supported,cf_branch,cf_jal,cf_jalr,cf_uses1,cf_uses2,cf_writes,cf_rs1,cf_rs2,cf_rd,cf_imm,
                id_target,id_link,id_taken,id_misaligned,id_branch_stall,ex_target_calc,ex_link,ex_taken_calc,ex_misaligned_calc}=0;
        assign id_next_pc=in_pc+32'd4;assign ex_next_calc=idex_q.pc+32'd4;
        assign id_branch_rs1=rf1;assign id_branch_rs2=rf2;
    end endgenerate
    // Match the latest live writer before testing ready. An unready MEM match
    // must block, rather than exposing an older matching WB or saved RF value.
    generate if(ENABLE_FORWARDING)begin:g_forward
    cpu5_hazard #(.CHECK_EX_PRODUCER(0)) u_ex_hazard(
        .consumer_valid(rst_n && idex_valid_q && !kill_ex && idex_supported_q && !idex_q.exception_valid),
        .uses_rs1(idex_q.uses_rs1),.uses_rs2(idex_q.uses_rs2),
        .rs1(idex_q.rs1),.rs2(idex_q.rs2),
        .rf_rs1_value(idex_q.rs1_value),.rf_rs2_value(idex_q.rs2_value),
        .ex_valid(1'b0),.ex_writes_rd(1'b0),.ex_rd(5'd0),.ex_result_ready(1'b0),
        .mem_valid(exmem_valid_q && !kill_mem),.mem_writes_rd(exmem_q.writes_rd),.mem_rd(exmem_q.rd),
        .mem_result_ready(exmem_supported_q && !exmem_q.exception_valid && mem_result_ready),
        .mem_result_value(mem_result_value),
        .wb_valid(memwb_valid_q),.wb_writes_rd(memwb_q.writes_rd),.wb_rd(memwb_q.rd),
        .wb_result_ready(1'b1),.wb_result_value(memwb_q.result),
        .rs1_value(ex_rs1_value),.rs2_value(ex_rs2_value),.fwd1(ex_fwd1),.fwd2(ex_fwd2),
        .stall1(ex_stall1),.stall2(ex_stall2),.stall(ex_source_stall),
        .ex_block1(),.ex_block2(),.ex_block());
    end else begin:g_no_forward
        assign ex_rs1_value=idex_q.rs1_value;assign ex_rs2_value=idex_q.rs2_value;
        assign {ex_fwd1,ex_fwd2,ex_source_stall,ex_stall1,ex_stall2}=0;
    end endgenerate

    always @* begin
        idex_next='0;
        idex_next.pc=in_pc;idex_next.instr=in_instr;
        idex_next.seq=in_seq;idex_next.epoch=in_epoch;
        idex_next.rs1=rs1;idex_next.rs2=rs2;idex_next.rd=rd;
        idex_next.uses_rs1=uses_rs1;idex_next.uses_rs2=uses_rs2;
        idex_next.writes_rd=writes_rd && !in_fetch_error && !id_ecall && !id_ebreak && !id_illegal;
        idex_next.rs1_value=id_saved_rs1;idex_next.rs2_value=id_saved_rs2;idex_next.imm=imm;
        idex_next.funct3=in_instr[14:12];idex_next.alu_op=alu_op;
        idex_next.pred_next_pc=in_pred_next_pc;
        idex_next.pred_taken=in_pred_taken;idex_next.pred_hit=in_pred_hit;
        idex_next.is_branch=cf_branch;idex_next.is_jal=cf_jal;idex_next.is_jalr=cf_jalr;
        idex_next.is_load=ram_load;idex_next.is_store=ram_store;
        idex_next.exception_valid=in_fetch_error || id_target_fault || id_ecall || id_ebreak || id_illegal;
        idex_next.exception_cause=in_fetch_error?32'd1:id_target_fault?32'd0:
            id_ecall?32'd8:id_ebreak?32'd3:id_illegal?32'd2:32'd0;
        idex_next.exception_tval=in_fetch_error?in_fetch_tval:id_target_fault?id_target:
            id_ebreak?in_pc:id_illegal?in_instr:32'd0;
        exmem_next='0;
        exmem_next.pc=idex_q.pc;exmem_next.instr=idex_q.instr;
        exmem_next.seq=idex_q.seq;exmem_next.epoch=idex_q.epoch;
        exmem_next.rd=idex_q.rd;exmem_next.writes_rd=idex_q.writes_rd;
        exmem_next.alu_result=ex_is_mem?32'd0:ex_is_cf?(idex_q.is_branch?32'd0:idex_q.pc+32'd4):alu_result;
        exmem_next.is_load=idex_q.is_load;exmem_next.is_store=idex_q.is_store;
        exmem_next.mem_addr=ram_ex_addr;exmem_next.mem_size=ram_ex_size;
        exmem_next.mem_wdata=ram_ex_wdata;exmem_next.mem_wstrb=ram_ex_wstrb;
        exmem_next.store_raw=ENABLE_FORWARDING?ex_rs2_value:idex_q.rs2_value;
        exmem_next.mem_funct3=idex_q.funct3;
        exmem_next.link_pc4=idex_q.pc+32'd4;exmem_next.actual_next_pc=ex_actual_next;
        exmem_next.is_branch=idex_q.is_branch;exmem_next.is_jal=idex_q.is_jal;exmem_next.is_jalr=idex_q.is_jalr;
        exmem_next.branch_target=ex_branch_target;exmem_next.branch_taken=ex_branch_taken;
        exmem_next.pred_next_pc=idex_q.pred_next_pc;
        exmem_next.pred_taken=idex_q.pred_taken;exmem_next.pred_hit=idex_q.pred_hit;
        exmem_next.exception_valid=idex_q.exception_valid || ex_target_fault || ex_ram_fault;
        exmem_next.exception_cause=idex_q.exception_valid?idex_q.exception_cause:ex_ram_fault?ram_ex_fault_cause:32'd0;
        exmem_next.exception_tval=idex_q.exception_valid?idex_q.exception_tval:ex_target_fault?ex_target_calc:ex_ram_fault?ram_ex_addr:32'd0;
        exmem_next.result_ready=idex_supported_q && !ex_is_mem && !exmem_next.exception_valid;
        memwb_next='0;
        memwb_next.pc=exmem_q.pc;memwb_next.instr=exmem_q.instr;memwb_next.seq=exmem_q.seq;
        memwb_next.rd=exmem_q.rd;memwb_next.writes_rd=exmem_q.writes_rd;
        memwb_next.result=mem_result_value;memwb_next.wb_kind=3'd1;
        memwb_next.actual_next_pc=exmem_q.actual_next_pc;
    end
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            idex_valid_q<=0;exmem_valid_q<=0;memwb_valid_q<=0;
            idex_q<='0;exmem_q<='0;memwb_q<='0;
            idex_supported_q<=0;exmem_supported_q<=0;idex_alu_a_q<=0;idex_alu_b_q<=0;
            idex_a_pc_q<=0;idex_a_zero_q<=0;idex_b_imm_q<=0;
            idex_cf_next_q<=0;idex_cf_target_q<=0;idex_cf_taken_q<=0;
            retire_valid<=0;retire_pc<=0;retire_instr<=0;retire_value<=0;
            retire_rd<=0;retire_writes_rd<=0;retire_seq<=0;
            trap_valid<=0;trap_pc<=0;trap_cause<=0;trap_tval<=0;trap_seq<=0;
            cycle_count<=0;instret_count<=0;arch_next_pc_q<=0;
            bp_resolved_count<=0;bp_mispredict_count<=0;bp_direction_error_count<=0;bp_target_error_count<=0;
        end else begin
            cycle_count<=cycle_count+64'd1;
            retire_valid<=retire_fire;
            trap_valid<=trap_fire;
            if(trap_fire)begin
                trap_pc<=exmem_q.pc;trap_cause<=halt_cause;trap_tval<=halt_tval;
                trap_seq<=exmem_q.seq;arch_next_pc_q<=TRAP_VECTOR;
            end
            if(retire_fire)begin
                instret_count<=instret_count+64'd1;
                arch_next_pc_q<=exmem_q.actual_next_pc;
                retire_pc<=exmem_q.pc;retire_instr<=exmem_q.instr;retire_seq<=exmem_q.seq;
                retire_rd<=exmem_q.rd;retire_value<=mem_result_value;
                retire_writes_rd<=exmem_q.writes_rd && exmem_q.rd!=0;
                if(ENABLE_CONTROL_FLOW && ENABLE_BRANCH_PRED)begin
                    if(exmem_q.is_branch||exmem_q.is_jal)bp_resolved_count<=bp_resolved_count+1;
                    if(exmem_q.actual_next_pc!=exmem_q.pred_next_pc)bp_mispredict_count<=bp_mispredict_count+1;
                    if((exmem_q.is_branch||exmem_q.is_jal) && exmem_q.pred_taken!=exmem_q.branch_taken)
                        bp_direction_error_count<=bp_direction_error_count+1;
                    if((exmem_q.is_branch||exmem_q.is_jal) && exmem_q.pred_taken && exmem_q.branch_taken &&
                       exmem_q.actual_next_pc!=exmem_q.pred_next_pc)bp_target_error_count<=bp_target_error_count+1;
                end
            end
            if(wb_can_load)begin
                memwb_valid_q<=retire_fire;
                if(retire_fire)memwb_q<=memwb_next;else memwb_q<='0;
            end
            if(mem_can_load)begin
                exmem_valid_q<=ex_move;
                if(ex_move)begin exmem_q<=exmem_next;exmem_supported_q<=idex_supported_q;end
                else begin exmem_q<='0;exmem_supported_q<=0;end
            end
            if(ex_can_load)begin
                idex_valid_q<=id_move;
                if(id_move)begin
                    idex_q<=idex_next;idex_supported_q<=supported;
                    idex_a_pc_q<=a_pc;idex_a_zero_q<=a_zero;idex_b_imm_q<=b_imm;
                    idex_cf_next_q<=id_next_pc;idex_cf_target_q<=id_target;idex_cf_taken_q<=id_taken;
                    idex_alu_a_q<=a_pc?in_pc:a_zero?32'd0:rf1;
                    idex_alu_b_q<=b_imm?imm:rf2;
                end else begin
                    idex_q<='0;idex_supported_q<=0;idex_alu_a_q<=0;idex_alu_b_q<=0;
                    idex_a_pc_q<=0;idex_a_zero_q<=0;idex_b_imm_q<=0;
                    idex_cf_next_q<=0;idex_cf_target_q<=0;idex_cf_taken_q<=0;
                end
            end else if(ENABLE_FORWARDING && idex_valid_q && !kill_ex)begin
                // A producer may drain while EX is held. Retain each resolved
                // source independently; never save the zero from a blocked one.
                if(idex_q.uses_rs1 && !ex_stall1)idex_q.rs1_value<=ex_rs1_value;
                if(idex_q.uses_rs2 && !ex_stall2)idex_q.rs2_value<=ex_rs2_value;
            end
        end
    end
    // synthesis translate_off
    initial if(SEQ_BITS!=64 || EPOCH_BITS<1 || (ENABLE_FORWARDING!=0 && ENABLE_FORWARDING!=1) ||
               (ENABLE_SYNC_TRAPS!=0 && ENABLE_SYNC_TRAPS!=1) || (ENABLE_SYNC_TRAPS && TRAP_VECTOR[1:0]!=0))
        $fatal(1,"CPU5 ALU requires 64-bit age, positive epoch and supported forwarding mode");
    always @(posedge clk)if(rst_n)begin
        if(retire_fire && (!exmem_supported_q||exmem_q.exception_valid||kill_mem))
            $fatal(1,"CPU5 invalid retirement authorization");
        if(wb_we && wb_rd==0)$fatal(1,"CPU5 x0 write");
        if(id_move && id_raw_wait)$fatal(1,"CPU5 stale operand admission");
        if(ENABLE_FORWARDING && ex_move && ex_source_stall)$fatal(1,"CPU5 unresolved EX source advanced");
        if(ENABLE_RAM && ram_issue_fire && !ram_issue_store &&
           (!ex_move || !idex_q.is_load || ex_ram_fault || kill_ex))
            $fatal(1,"CPU5 LOAD issue lacks live advancing EX owner");
        if(ENABLE_RAM && ram_issue_fire && ram_issue_store &&
           (!exmem_valid_q || !exmem_q.is_store || exmem_q.exception_valid || kill_mem || !mem_enable))
            $fatal(1,"CPU5 STORE issue lacks oldest qualified MEM owner");
        if(ram_mem_matches && (ram_completion_pc!==exmem_q.pc || ram_completion_instr!==exmem_q.instr))
            $fatal(1,"CPU5 D completion owner identity mismatch");
        if(trap_fire && (retire_fire || bp_commit_valid || ex_move || id_move || ram_issue_fire))
            $fatal(1,"CPU5 synchronous trap leaked younger or fault-source action");
        if(trap_fire && (!exmem_valid_q || kill_mem || !mem_fault || !mem_enable))
            $fatal(1,"CPU5 trap lacks live oldest MEM fault");
    end
    // synthesis translate_on
endmodule
