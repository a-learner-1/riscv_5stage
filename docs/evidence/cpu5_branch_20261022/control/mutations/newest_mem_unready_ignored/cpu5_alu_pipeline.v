// CPU5 ALU subset: stage 3A-1 reference or opt-in stage 3A-2 forwarding.
// Optional integer control flow; memory, M, CSR, traps/IRQs remain absent.
// The unchanged regfile defines only x0 after reset; software initializes x1..31.
module cpu5_alu_pipeline #(
    parameter integer SEQ_BITS=64,EPOCH_BITS=8,ENABLE_FORWARDING=0,
    ENABLE_CONTROL_FLOW=0,BRANCH_RESOLVE_IN_ID=0,ENABLE_BRANCH_PRED=0
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
    output wire [31:0] halt_cause,halt_tval
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
    assign supported=alu_supported||cf_supported;
    assign {uses_rs1,uses_rs2,writes_rd}=cf_supported?{cf_uses1,cf_uses2,cf_writes}:{alu_uses1,alu_uses2,alu_writes};
    assign rs1=cf_supported?cf_rs1:alu_rs1;assign rs2=cf_supported?cf_rs2:alu_rs2;
    assign rd=cf_supported?cf_rd:alu_rd;assign imm=cf_supported?cf_imm:alu_imm;
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
    wire kill_input=flush_valid && in_seq>=flush_cut_seq;
    wire kill_ex=flush_valid && idex_q.seq>=flush_cut_seq;
    wire kill_mem=flush_valid && exmem_q.seq>=flush_cut_seq;
    // WB was already retired at an earlier MEM edge and is never age-killed.
    assign wb_fire=rst_n && memwb_valid_q && wb_ready;
    assign wb_we=wb_fire && memwb_q.writes_rd && memwb_q.rd!=0;
    assign wb_pc=memwb_q.pc;assign wb_rd=memwb_q.rd;assign wb_data=memwb_q.result;
    wire wb_can_load=!memwb_valid_q || wb_fire;
    assign halted=rst_n && exmem_valid_q && !kill_mem &&
        (!exmem_supported_q || exmem_q.exception_valid);
    assign halt_pc=exmem_q.pc;assign halt_instr=exmem_q.instr;
    assign halt_seq=exmem_q.seq;
    assign halt_fetch_error=exmem_q.exception_valid && exmem_q.exception_cause==1;
    assign halt_cause=exmem_q.exception_cause;assign halt_tval=exmem_q.exception_tval;
    assign retire_fire=rst_n && exmem_valid_q && !kill_mem && !halted &&
        exmem_q.result_ready && mem_enable && wb_can_load;
    wire mem_can_load=!exmem_valid_q || kill_mem || retire_fire;
    wire ex_move=rst_n && idex_valid_q && !kill_ex && ex_enable && mem_can_load &&
        (!ENABLE_FORWARDING || !ex_source_stall) && !(ENABLE_CONTROL_FLOW && flush_valid);
    wire ex_can_load=!idex_valid_q || kill_ex || ex_move;

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
        (!idex_supported_q || idex_q.exception_valid || ex_target_fault);
    wire ex_redirect=ENABLE_CONTROL_FLOW && !BRANCH_RESOLVE_IN_ID && !flush_valid &&
        ex_move && idex_supported_q && !idex_q.exception_valid && !ex_target_fault &&
        ex_actual_next!=idex_q.pred_next_pc;
    assign id_raw_wait=(!ENABLE_FORWARDING && in_valid && !in_fetch_error && supported &&
        ((uses_rs1&&pending_rs1) || (uses_rs2&&pending_rs2))) || id_branch_stall;
    assign in_ready=rst_n && id_enable && !kill_input && !id_raw_wait && ex_can_load &&
        !ex_redirect && !(ENABLE_CONTROL_FLOW && flush_valid) &&
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
        !halted && !known_ex_fault && id_move && supported && !in_fetch_error && !id_target_fault &&
        id_next_pc!=in_pred_next_pc;
    assign redirect_valid=ex_redirect||id_redirect;
    assign redirect_kill_ifid=ex_redirect;
    assign redirect_pc=ex_redirect?ex_actual_next:id_next_pc;
    assign redirect_seq=ex_redirect?idex_q.seq:in_seq;
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
            .mem_result_ready(exmem_supported_q && !exmem_q.exception_valid),.mem_result_value(exmem_q.alu_result),
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
        .mem_result_ready(exmem_supported_q && !exmem_q.exception_valid),
        .mem_result_value(exmem_q.alu_result),
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
        idex_next.writes_rd=writes_rd && !in_fetch_error;
        idex_next.rs1_value=id_saved_rs1;idex_next.rs2_value=id_saved_rs2;idex_next.imm=imm;
        idex_next.funct3=in_instr[14:12];idex_next.alu_op=alu_op;
        idex_next.pred_next_pc=in_pred_next_pc;
        idex_next.pred_taken=in_pred_taken;idex_next.pred_hit=in_pred_hit;
        idex_next.is_branch=cf_branch;idex_next.is_jal=cf_jal;idex_next.is_jalr=cf_jalr;
        idex_next.exception_valid=in_fetch_error || id_target_fault;
        idex_next.exception_cause=in_fetch_error?32'd1:32'd0;
        idex_next.exception_tval=in_fetch_error?in_fetch_tval:id_target_fault?id_target:32'd0;
        exmem_next='0;
        exmem_next.pc=idex_q.pc;exmem_next.instr=idex_q.instr;
        exmem_next.seq=idex_q.seq;exmem_next.epoch=idex_q.epoch;
        exmem_next.rd=idex_q.rd;exmem_next.writes_rd=idex_q.writes_rd;
        exmem_next.alu_result=ex_is_cf?(idex_q.is_branch?32'd0:idex_q.pc+32'd4):alu_result;
        exmem_next.link_pc4=idex_q.pc+32'd4;exmem_next.actual_next_pc=ex_actual_next;
        exmem_next.is_branch=idex_q.is_branch;exmem_next.is_jal=idex_q.is_jal;exmem_next.is_jalr=idex_q.is_jalr;
        exmem_next.branch_target=ex_branch_target;exmem_next.branch_taken=ex_branch_taken;
        exmem_next.pred_next_pc=idex_q.pred_next_pc;
        exmem_next.pred_taken=idex_q.pred_taken;exmem_next.pred_hit=idex_q.pred_hit;
        exmem_next.exception_valid=idex_q.exception_valid || ex_target_fault;
        exmem_next.exception_cause=idex_q.exception_valid?idex_q.exception_cause:32'd0;
        exmem_next.exception_tval=idex_q.exception_valid?idex_q.exception_tval:ex_target_fault?ex_target_calc:32'd0;
        exmem_next.result_ready=idex_supported_q && !exmem_next.exception_valid;
        memwb_next='0;
        memwb_next.pc=exmem_q.pc;memwb_next.instr=exmem_q.instr;memwb_next.seq=exmem_q.seq;
        memwb_next.rd=exmem_q.rd;memwb_next.writes_rd=exmem_q.writes_rd;
        memwb_next.result=exmem_q.alu_result;memwb_next.wb_kind=3'd1;
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
            cycle_count<=0;instret_count<=0;arch_next_pc_q<=0;
            bp_resolved_count<=0;bp_mispredict_count<=0;bp_direction_error_count<=0;bp_target_error_count<=0;
        end else begin
            cycle_count<=cycle_count+64'd1;
            retire_valid<=retire_fire;
            if(retire_fire)begin
                instret_count<=instret_count+64'd1;
                arch_next_pc_q<=exmem_q.actual_next_pc;
                retire_pc<=exmem_q.pc;retire_instr<=exmem_q.instr;retire_seq<=exmem_q.seq;
                retire_rd<=exmem_q.rd;retire_value<=exmem_q.alu_result;
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
    initial if(SEQ_BITS!=64 || EPOCH_BITS<1 || (ENABLE_FORWARDING!=0 && ENABLE_FORWARDING!=1))
        $fatal(1,"CPU5 ALU requires 64-bit age, positive epoch and supported forwarding mode");
    always @(posedge clk)if(rst_n)begin
        if(retire_fire && (!exmem_supported_q||exmem_q.exception_valid||kill_mem))
            $fatal(1,"CPU5 invalid retirement authorization");
        if(wb_we && wb_rd==0)$fatal(1,"CPU5 x0 write");
        if(id_move && id_raw_wait)$fatal(1,"CPU5 stale operand admission");
        if(ENABLE_FORWARDING && ex_move && ex_source_stall)$fatal(1,"CPU5 unresolved EX source advanced");
    end
    // synthesis translate_on
endmodule
