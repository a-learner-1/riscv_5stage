// Metadata-only elastic stage framework. NOT an instruction executor.
// There is no retirement, GPR write, D request, CSR, M unit or Trap here.
// Debug WB token consumption below is explicitly not architectural retirement.
module cpu5_pipeline_skeleton #(
    parameter integer SEQ_BITS=64, EPOCH_BITS=8
)(
    input wire clk, rst_n,
    input wire in_valid, output wire in_ready,
    input wire [31:0] in_pc, in_instr, in_pred_next_pc,
    input wire in_pred_taken, in_pred_hit, in_fetch_error,
    input wire [31:0] in_fetch_tval,
    input wire [SEQ_BITS-1:0] in_seq,
    input wire [EPOCH_BITS-1:0] in_epoch,
    input wire id_enable, ex_enable, mem_enable, wb_ready,
    // Event source defines FIRST KILLED age, not the redirect's source age:
    // branch => source+1; synchronous Trap => fault source; IRQ => first
    // unretired instruction. All tokens >=cut are discarded;
    // strictly older tokens may advance, including an older debug WB token.
    // Fetch epoch is deliberately absent from this liveness decision.
    input wire flush_valid,
    input wire [SEQ_BITS-1:0] flush_cut_seq,
    output wire debug_wb_valid,
    output wire [31:0] debug_wb_pc, debug_wb_instr,
    output wire [SEQ_BITS-1:0] debug_wb_seq,
    output wire [EPOCH_BITS-1:0] debug_ex_epoch,
    output wire debug_ex_valid,
    output wire [31:0] debug_ex_pc, debug_ex_instr
);
    `include "rtl/cpu5_pipeline_types.vh"
    reg idex_valid_q, exmem_valid_q, memwb_valid_q;
    cpu5_idex_t idex_q, idex_next;
    cpu5_exmem_t exmem_q, exmem_next;
    cpu5_memwb_t memwb_q, memwb_next;
    // Future hierarchy names explicitly mean the EX instruction here.
    wire [31:0] idex_pc_q=idex_q.pc, idex_instr_q=idex_q.instr;
    wire [SEQ_BITS-1:0] idex_seq_q=idex_q.seq, exmem_seq_q=exmem_q.seq,
                              memwb_seq_q=memwb_q.seq;
    wire kill_idex=flush_valid && idex_q.seq[31:0]>=flush_cut_seq[31:0];
    wire kill_exmem=flush_valid && exmem_q.seq[31:0]>=flush_cut_seq[31:0];
    wire kill_memwb=flush_valid && memwb_q.seq[31:0]>=flush_cut_seq[31:0];
    wire kill_input=flush_valid && in_seq>=flush_cut_seq;
    wire wb_can_load=!memwb_valid_q || kill_memwb || wb_ready;
    // A queued IF fault stops at MEM until a future commit controller handles
    // it, or an age-authorized flush consumes it. It is never silently retired.
    wire mem_move=exmem_valid_q && !kill_exmem && !exmem_q.exception_valid && mem_enable && wb_can_load;
    wire mem_can_load=!exmem_valid_q || kill_exmem || mem_move;
    wire ex_move=idex_valid_q && !kill_idex && ex_enable && mem_can_load;
    wire ex_can_load=!idex_valid_q || kill_idex || ex_move;
    wire id_move=in_valid && in_ready;
    assign in_ready=rst_n && id_enable && !kill_input && ex_can_load;
    assign debug_wb_valid=rst_n && memwb_valid_q && !kill_memwb;
    assign debug_wb_pc=memwb_q.pc;
    assign debug_wb_instr=memwb_q.instr;
    assign debug_wb_seq=memwb_q.seq;
    assign debug_ex_valid=rst_n && idex_valid_q && !kill_idex;
    assign debug_ex_pc=idex_q.pc;
    assign debug_ex_instr=idex_q.instr;
    assign debug_ex_epoch=idex_q.epoch;

    // Only identity, prediction and IF-fault metadata are implemented.
    // All execution/side-effect controls are reset-to-zero placeholders.
    always @* begin
        idex_next='0;
        idex_next.pc=in_pc; idex_next.instr=in_instr;
        idex_next.seq=in_seq; idex_next.epoch=in_epoch;
        idex_next.pred_next_pc=in_pred_next_pc;
        idex_next.pred_taken=in_pred_taken; idex_next.pred_hit=in_pred_hit;
        idex_next.exception_valid=in_fetch_error;
        idex_next.exception_cause=in_fetch_error ? 32'd1 : 32'd0;
        idex_next.exception_tval=in_fetch_tval;
        exmem_next='0;
        exmem_next.pc=idex_q.pc; exmem_next.instr=idex_q.instr;
        exmem_next.seq=idex_q.seq; exmem_next.epoch=idex_q.epoch;
        exmem_next.pred_next_pc=idex_q.pred_next_pc;
        exmem_next.pred_taken=idex_q.pred_taken;
        exmem_next.pred_hit=idex_q.pred_hit;
        exmem_next.exception_valid=idex_q.exception_valid;
        exmem_next.exception_cause=idex_q.exception_cause;
        exmem_next.exception_tval=idex_q.exception_tval;
        // A PC+4 placeholder is carried for debug; it does not update arch PC.
        exmem_next.link_pc4=idex_q.pc+32'd4;
        exmem_next.actual_next_pc=idex_q.pc+32'd4;
        memwb_next='0;
        memwb_next.pc=exmem_q.pc; memwb_next.instr=exmem_q.instr;
        memwb_next.seq=exmem_q.seq;
        memwb_next.actual_next_pc=exmem_q.actual_next_pc;
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            idex_valid_q<=0; exmem_valid_q<=0; memwb_valid_q<=0;
            idex_q<='0; exmem_q<='0; memwb_q<='0;
        end else begin
            // Each independently drains. A stalled MEM cannot repeat WB.
            if(wb_can_load) begin
                memwb_valid_q<=mem_move;
                if(mem_move) memwb_q<=memwb_next;
                else memwb_q<='0;
            end
            if(mem_can_load) begin
                exmem_valid_q<=ex_move;
                if(ex_move) exmem_q<=exmem_next;
                else exmem_q<='0;
            end
            if(ex_can_load) begin
                idex_valid_q<=id_move;
                if(id_move) idex_q<=idex_next;
                else idex_q<='0;
            end
        end
    end
    // synthesis translate_off
    initial if(SEQ_BITS!=64 || EPOCH_BITS<1)
        $fatal(1,"CPU5 skeleton requires 64-bit nonwrapping age and positive epoch width");
    always @(posedge clk) if(rst_n) begin
        if((idex_valid_q && idex_q.writes_rd) || (exmem_valid_q &&
          (exmem_q.writes_rd || exmem_q.commit_eligible || exmem_q.is_store)) ||
          (memwb_valid_q && memwb_q.writes_rd))
            $fatal(1,"Metadata skeleton must never authorize architectural effects");
    end
    // synthesis translate_on
endmodule
