// One native D transaction. Ownership begins at issue_fire, before the
// endpoint accepts the request. A killed LOAD still sends and drains its
// transaction; epochs never decide D ownership. STORE ownership is irrevocable
// here and the caller must use store_lock when accepting a flush.
module cpu5_ram_owner #(
    parameter integer SEQ_BITS=64, EPOCH_BITS=8
)(
    input wire clk,rst_n,
    input wire issue_valid, output wire issue_ready, output wire issue_fire,
    input wire [SEQ_BITS-1:0] issue_seq,
    input wire [31:0] issue_pc,issue_instr,
    input wire [EPOCH_BITS-1:0] issue_epoch,
    input wire issue_is_store,
    input wire [31:0] issue_addr,
    input wire [1:0] issue_size,
    input wire [31:0] issue_wdata,
    input wire [3:0] issue_wstrb,
    input wire [2:0] issue_funct3,
    input wire kill_valid,input wire [SEQ_BITS-1:0] kill_cut_seq,
    output wire dmem_req_valid,input wire dmem_req_ready,
    output wire dmem_req_write,output wire [31:0] dmem_req_addr,
    output wire [1:0] dmem_req_size,output wire [31:0] dmem_req_wdata,
    output wire [3:0] dmem_req_wstrb,
    input wire dmem_rsp_valid,output wire dmem_rsp_ready,
    input wire [31:0] dmem_rsp_rdata,input wire dmem_rsp_error,
    output wire completion_valid,input wire completion_ready,
    output wire [SEQ_BITS-1:0] completion_seq,
    output wire [31:0] completion_pc,completion_instr,
    output wire [EPOCH_BITS-1:0] completion_epoch,
    output wire [31:0] completion_rdata,
    output wire completion_error,completion_killed,completion_is_store,
    output wire [31:0] completion_addr,
    output wire [2:0] completion_funct3,
    output wire owner_valid,output wire [SEQ_BITS-1:0] owner_seq,
    output wire owner_is_store,owner_killed,owner_sent,
    output wire [SEQ_BITS-1:0] req_owner_seq,rsp_owner_seq,
    output wire [31:0] req_owner_pc,req_owner_instr,rsp_owner_pc,rsp_owner_instr,
    output wire req_fire,rsp_fire,store_lock,
    output wire [1:0] state_debug
);
    localparam [1:0] IDLE=0,PRESENTED=1,ACCEPTED=2,COMPLETE=3;
    reg [1:0] state_q;
    reg [SEQ_BITS-1:0] seq_q;
    reg [31:0] pc_q,instr_q,addr_q,wdata_q,rdata_q;
    reg [EPOCH_BITS-1:0] epoch_q;
    reg is_store_q,killed_q,error_q;
    reg [1:0] size_q;
    reg [3:0] wstrb_q;
    reg [2:0] funct3_q;

    wire kill_owner=kill_valid && !is_store_q && seq_q>=kill_cut_seq;
    wire effective_killed=killed_q || (owner_valid && kill_owner);
    wire response_available=(state_q==ACCEPTED && dmem_rsp_valid);
    wire result_available=(state_q==COMPLETE) || response_available;
    wire result_error=state_q==COMPLETE?error_q:dmem_rsp_error;
    // The only turnover shortcut is a consumed, successful, live LOAD to a
    // new LOAD. In particular error/store/killed completion cannot present B.
    wire load_turnover=owner_valid && !is_store_q && result_available &&
        !result_error && !effective_killed && completion_ready;
    assign issue_ready=rst_n && ((state_q==IDLE) ||
        (load_turnover && !issue_is_store));
    assign issue_fire=issue_valid && issue_ready;
    wire new_request=issue_fire;
    assign dmem_req_valid=rst_n && ((state_q==PRESENTED) || new_request);
    assign dmem_req_write=new_request?issue_is_store:is_store_q;
    assign dmem_req_addr=new_request?issue_addr:addr_q;
    assign dmem_req_size=new_request?issue_size:size_q;
    assign dmem_req_wdata=new_request?issue_wdata:wdata_q;
    assign dmem_req_wstrb=new_request?issue_wstrb:wstrb_q;
    assign req_owner_seq=new_request?issue_seq:seq_q;
    assign req_owner_pc=new_request?issue_pc:pc_q;
    assign req_owner_instr=new_request?issue_instr:instr_q;
    assign req_fire=dmem_req_valid && dmem_req_ready;

    // Always accept an owned response, storing it if MEM/WB is blocked. An
    // endpoint with zero latency must keep VALID until this READY is asserted.
    assign dmem_rsp_ready=rst_n && state_q==ACCEPTED;
    assign rsp_fire=dmem_rsp_valid && dmem_rsp_ready;
    assign rsp_owner_seq=seq_q;
    assign rsp_owner_pc=pc_q;
    assign rsp_owner_instr=instr_q;
    assign completion_valid=rst_n && result_available;
    assign completion_seq=seq_q;
    assign completion_pc=pc_q;
    assign completion_instr=instr_q;
    assign completion_epoch=epoch_q;
    assign completion_rdata=dmem_rsp_rdata;
    assign completion_error=result_error;
    assign completion_killed=effective_killed;
    assign completion_is_store=is_store_q;
    assign completion_addr=addr_q;
    assign completion_funct3=funct3_q;
    assign owner_valid=rst_n && state_q!=IDLE;
    assign owner_seq=seq_q;
    assign owner_is_store=is_store_q;
    assign owner_killed=owner_valid && effective_killed;
    assign owner_sent=owner_valid && (state_q==ACCEPTED || state_q==COMPLETE);
    assign store_lock=owner_valid && is_store_q;
    assign state_debug=state_q;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state_q<=IDLE; seq_q<=0; pc_q<=0; instr_q<=0; epoch_q<=0;
            addr_q<=0; size_q<=0; wdata_q<=0; wstrb_q<=0; funct3_q<=0;
            is_store_q<=0; killed_q<=0; rdata_q<=0; error_q<=0;
        end else begin
            if(owner_valid && kill_owner) killed_q<=1'b1;
            case(state_q)
                PRESENTED: if(req_fire) state_q<=ACCEPTED;
                ACCEPTED: if(rsp_fire) begin
                    rdata_q<=dmem_rsp_rdata; error_q<=dmem_rsp_error;
                    if(effective_killed || completion_ready)
                        state_q<=IDLE;
                    else state_q<=COMPLETE;
                end
                COMPLETE: begin
                    // READY explicitly acknowledges either success or error.
                    // A caller that halts on a fault keeps READY low; a future
                    // precise-trap caller can acknowledge the fault instead.
                    if(effective_killed || completion_ready)
                        state_q<=IDLE;
                end
                default: begin end
            endcase
            if(issue_fire) begin
                state_q<=dmem_req_ready?ACCEPTED:PRESENTED;
                seq_q<=issue_seq; pc_q<=issue_pc; instr_q<=issue_instr;
                epoch_q<=issue_epoch; is_store_q<=issue_is_store;
                addr_q<=issue_addr; size_q<=issue_size; wdata_q<=issue_wdata;
                wstrb_q<=issue_wstrb; funct3_q<=issue_funct3;
                killed_q<=kill_valid && !issue_is_store && issue_seq>=kill_cut_seq;
                rdata_q<=0; error_q<=0;
            end
        end
    end
endmodule
