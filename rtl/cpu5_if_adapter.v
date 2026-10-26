// CPU5 candidate front end. The original IF owns the normal IF/ID registers;
// this adapter adds age/epoch sidebands and queues its sticky fault as a packet.
// EXTERNAL_IMEM is deliberately fixed to 1: the SoC owns the ROM/cache endpoint.
module cpu5_if_adapter #(
    parameter PROGRAM_FILE = "programs/rv32i_regression.hex",
    parameter integer IMEM_WORDS = 8192,
    parameter integer ENABLE_BRANCH_PRED = 0,
    parameter integer BTB_ENTRIES = 64,
    parameter integer SEQ_BITS = 64,
    parameter integer EPOCH_BITS = 8
) (
    input wire clk, input wire rst_n,
    input wire id_ready,
    input wire redirect_valid, output wire redirect_ready,
    input wire [31:0] redirect_pc, input wire redirect_kill_ifid,
    output wire ifid_valid, output wire [31:0] ifid_pc,
    output wire [31:0] ifid_instr, output wire [31:0] ifid_pred_next_pc,
    output wire ifid_pred_taken, output wire ifid_pred_hit,
    output wire ifid_fetch_error, output wire [31:0] ifid_fetch_tval,
    output wire [SEQ_BITS-1:0] ifid_seq,
    output wire [EPOCH_BITS-1:0] ifid_epoch,
    output wire imem_req_valid, input wire imem_req_ready,
    output wire [31:0] imem_req_addr,
    input wire imem_rsp_valid, output wire imem_rsp_ready,
    input wire [31:0] imem_rsp_rdata, input wire imem_rsp_error,
    input wire bp_commit_valid, output wire bp_commit_ready,
    input wire [SEQ_BITS-1:0] bp_commit_seq,
    input wire [31:0] bp_commit_pc, input wire [31:0] bp_commit_target,
    input wire bp_commit_taken, input wire bp_commit_is_branch,
    input wire bp_commit_is_jal, output wire bp_update_fire,
    output wire [31:0] bp_lookup_count, output wire [31:0] bp_hit_count,
    output wire [31:0] bp_taken_count,
    output wire imem_fault, output wire [31:0] imem_fault_pc
);
    wire raw_valid;
    wire [31:0] raw_pc, raw_instr, raw_pred_next_pc, unused_pc_f;
    wire raw_pred_taken, raw_pred_hit;
    wire redirect_fire = redirect_valid && redirect_ready;
    // An ID-owned redirect may only discard the IF/ID slot on its transfer.
    // An older MEM/EX event explicitly authorizes killing a younger IF/ID.
    assign redirect_ready = redirect_kill_ifid || (ifid_valid && id_ready);
    reg fault_valid_q;
    reg [31:0] fault_pc_q;
    reg [SEQ_BITS-1:0] next_seq_q, packet_seq_q;
    // Reserve all-ones as a terminal, non-wrapping halt. The containing CPU
    // must quiesce/reset BEFORE this condition. The tail packet is retained
    // internally but not offered to ID; no successful execution is claimed
    // after exhaustion, even when synthesis removes the diagnostic fatal.
    wire seq_exhausted = &next_seq_q;
    reg [EPOCH_BITS-1:0] epoch_q, packet_epoch_q;
    // Shadow only externally visible ownership. No hierarchical IF probes.
    reg pending_q, pending_stale_q;
    reg [31:0] pending_pc_q;
    reg [EPOCH_BITS-1:0] pending_epoch_q;
    reg held_q, held_stale_q;
    reg [EPOCH_BITS-1:0] held_epoch_q;
    wire req_fire = imem_req_valid && imem_req_ready;
    wire rsp_fire = imem_rsp_valid && imem_rsp_ready;
    wire req_stale = held_q && (held_stale_q || redirect_fire);
    wire rsp_drop = pending_stale_q || redirect_fire;
    wire [EPOCH_BITS-1:0] request_epoch = held_q ? held_epoch_q :
        (redirect_fire ? epoch_q + 1'b1 : epoch_q);
    reg bp_last_valid_q;
    reg [SEQ_BITS-1:0] bp_last_seq_q;
    // Commit seq is monotonic. A held/replayed MEM descriptor trains once.
    // Exhausting SEQ_BITS requires a quiescent reset; no modular age ordering.
    assign bp_commit_ready = !bp_last_valid_q || bp_commit_seq > bp_last_seq_q;
    assign bp_update_fire = rst_n && bp_commit_valid && bp_commit_ready;
    assign ifid_valid = !seq_exhausted && (raw_valid || fault_valid_q);
    assign ifid_pc = fault_valid_q ? fault_pc_q : raw_pc;
    assign ifid_instr = fault_valid_q ? 32'h00000013 : raw_instr;
    assign ifid_pred_next_pc = fault_valid_q ? fault_pc_q + 32'd4 : raw_pred_next_pc;
    assign ifid_pred_taken = !fault_valid_q && raw_pred_taken;
    assign ifid_pred_hit = !fault_valid_q && raw_pred_hit;
    assign ifid_fetch_error = fault_valid_q;
    assign ifid_fetch_tval = fault_valid_q ? fault_pc_q : 32'd0;
    assign ifid_seq = packet_seq_q;
    assign ifid_epoch = packet_epoch_q;

    if_stage #(.PROGRAM_FILE(PROGRAM_FILE), .IMEM_WORDS(IMEM_WORDS),
        .EXTERNAL_IMEM(1), .ENABLE_TRAPS(1),
        .ENABLE_BRANCH_PRED(ENABLE_BRANCH_PRED), .BTB_ENTRIES(BTB_ENTRIES),
        .REGISTER_REDIRECT_REQUEST(1)) u_if_stage (
        .clk(clk), .rst_n(rst_n), .redirect_x(redirect_fire),
        .redirect_pc_x(redirect_pc), .stall_x(!id_ready || fault_valid_q || seq_exhausted),
        .pc_f(unused_pc_f), .pc_x(raw_pc), .instr_x(raw_instr), .valid_x(raw_valid),
        .imem_req_valid(imem_req_valid), .imem_req_ready(imem_req_ready),
        .imem_req_addr(imem_req_addr), .imem_rsp_valid(imem_rsp_valid),
        .imem_rsp_ready(imem_rsp_ready), .imem_rsp_rdata(imem_rsp_rdata),
        .imem_rsp_error(imem_rsp_error), .imem_fault(imem_fault),
        .imem_fault_pc(imem_fault_pc), .bp_update_valid(bp_update_fire),
        .bp_update_pc(bp_commit_pc), .bp_update_target(bp_commit_target),
        .bp_update_taken(bp_commit_taken), .bp_update_is_branch(bp_commit_is_branch),
        .bp_update_is_jal(bp_commit_is_jal),
        .predicted_next_pc_x(raw_pred_next_pc),
        .prediction_taken_x(raw_pred_taken), .prediction_hit_x(raw_pred_hit),
        .bp_lookup_count(bp_lookup_count), .bp_hit_count(bp_hit_count),
        .bp_taken_count(bp_taken_count)
    );
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fault_valid_q <= 0; fault_pc_q <= 0;
            next_seq_q <= 0; packet_seq_q <= 0; packet_epoch_q <= 0; epoch_q <= 0;
            pending_q <= 0; pending_stale_q <= 0; pending_pc_q <= 0; pending_epoch_q <= 0;
            held_q <= 0; held_stale_q <= 0; held_epoch_q <= 0;
            bp_last_valid_q <= 0; bp_last_seq_q <= 0;
        end else begin
            if (bp_update_fire) begin
                bp_last_valid_q <= 1; bp_last_seq_q <= bp_commit_seq;
            end
            if (fault_valid_q && id_ready) fault_valid_q <= 0;
            if (redirect_fire) begin
                epoch_q <= epoch_q + 1'b1;
                fault_valid_q <= 0;
            end
            if (rsp_fire && !rsp_drop) begin
                // This is the same edge that original IF updates normal output.
                packet_seq_q <= next_seq_q; next_seq_q <= next_seq_q + 1'b1;
                packet_epoch_q <= pending_epoch_q;
                if (imem_rsp_error) begin
                    fault_valid_q <= 1; fault_pc_q <= pending_pc_q;
                end
            end
            if (rsp_fire) begin
                pending_q <= 0; pending_stale_q <= 0;
            end else if (redirect_fire && pending_q) pending_stale_q <= 1;
            if (req_fire) begin
                pending_q <= 1; pending_stale_q <= req_stale;
                pending_pc_q <= imem_req_addr; pending_epoch_q <= request_epoch;
                held_q <= 0; held_stale_q <= 0;
            end else if (imem_req_valid && !imem_req_ready) begin
                if (!held_q) held_epoch_q <= request_epoch;
                held_q <= 1; held_stale_q <= req_stale;
            end
        end
    end
    // synthesis translate_off
    initial begin
        if (SEQ_BITS != 64) $fatal(1, "CPU5 IF requires 64-bit non-wrapping age");
        if (EPOCH_BITS < 1) $fatal(1, "CPU5 IF requires positive EPOCH_BITS");
        if (IMEM_WORDS < 1 || IMEM_WORDS > 1073741824)
            $fatal(1, "CPU5 IF requires IMEM_WORDS in 1..1073741824");
    end
    always @(posedge clk) if (rst_n) begin
        if (rsp_fire && !pending_q) $fatal(1, "CPU5 IF response without owner");
        if (raw_valid && fault_valid_q) $fatal(1, "CPU5 IF normal/fault overlap");
        if (seq_exhausted) $fatal(1, "CPU5 IF seq exhausted; drain and reset required");
    end
    // synthesis translate_on
endmodule
