// One generation-tagged owner around the unchanged sticky-done RV32M unit.
// Fetch epoch is trace metadata; only seq/cut and killed determine liveness.
// An empty slot may start once. No result is consumed at that start edge, and
// completion/kill drain must free the slot before a later edge can start again.
module cpu5_m_owner #(
    parameter integer SEQ_BITS=64,EPOCH_BITS=8,
    parameter [63:0] RESET_GENERATION=64'd0
)(
    input wire clk,rst_n,
    input wire issue_valid,output wire issue_ready,output wire issue_fire,
    input wire [SEQ_BITS-1:0] issue_seq,
    input wire [31:0] issue_pc,issue_instr,
    input wire [EPOCH_BITS-1:0] issue_epoch,
    input wire [2:0] issue_op,
    input wire [31:0] issue_lhs,issue_rhs,
    input wire kill_valid,input wire [SEQ_BITS-1:0] kill_cut_seq,
    output wire completion_valid,input wire completion_ready,
    output wire [SEQ_BITS-1:0] completion_seq,
    output wire [31:0] completion_pc,completion_instr,
    output wire [EPOCH_BITS-1:0] completion_epoch,
    output wire [31:0] completion_result,
    output wire completion_killed,
    output wire [2:0] completion_op,
    output wire owner_valid,output wire [SEQ_BITS-1:0] owner_seq,
    output wire owner_killed,
    output wire unit_start_fire,unit_busy,unit_done,
    output wire [63:0] owner_generation,result_generation,
    output wire drain_fire
);
    localparam [1:0] NONE=0,WAIT_RESULT=1,HOLD_RESULT=2;
    reg [1:0] state_q;
    reg [SEQ_BITS-1:0] seq_q;
    reg [31:0] pc_q,instr_q,result_q;
    reg [EPOCH_BITS-1:0] epoch_q;
    reg [2:0] op_q;
    reg killed_q,result_consumed_q;
    // All ones is a terminal allocation marker, never an issued generation.
    // RESET_GENERATION permits finite boundary tests without changing width.
    reg [63:0] next_generation_q,owner_generation_q,result_generation_q;
    wire generation_exhausted=&next_generation_q;
    wire issue_killed=kill_valid && issue_seq>=kill_cut_seq;
    wire kill_owner=kill_valid && seq_q>=kill_cut_seq;
    wire effective_killed=killed_q || (owner_valid && kill_owner);
    wire [31:0] unit_result;
    wire fresh_result=state_q==WAIT_RESULT && unit_done;
    wire result_available=state_q==HOLD_RESULT || fresh_result;

    assign owner_valid=rst_n && state_q!=NONE;
    assign owner_seq=seq_q;
    assign owner_killed=owner_valid && effective_killed;
    assign issue_ready=rst_n && state_q==NONE && !unit_busy &&
        !generation_exhausted && !issue_killed;
    assign issue_fire=issue_valid && issue_ready;
    assign unit_start_fire=issue_fire;
    rv32m_unit u_unit(.clk(clk),.rst_n(rst_n),.start(unit_start_fire),
        .op(issue_op),.lhs(issue_lhs),.rhs(issue_rhs),
        .busy(unit_busy),.done(unit_done),.result(unit_result));

    // WAIT_RESULT can bypass the newly completed unit into the held-result
    // interface. Ownership was created at an earlier edge: the old done high
    // before a new start can never consume this newly allocated generation.
    assign completion_valid=owner_valid && result_available;
    assign completion_seq=seq_q;
    assign completion_pc=pc_q;assign completion_instr=instr_q;
    assign completion_epoch=epoch_q;assign completion_op=op_q;
    assign completion_result=state_q==HOLD_RESULT?result_q:unit_result;
    assign completion_killed=effective_killed;
    assign owner_generation=owner_generation_q;
    assign result_generation=fresh_result?owner_generation_q:result_generation_q;
    assign drain_fire=completion_valid && completion_killed;
    wire consume_fire=completion_valid && completion_ready && !completion_killed;

    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            state_q<=NONE;seq_q<=0;pc_q<=0;instr_q<=0;epoch_q<=0;op_q<=0;
            killed_q<=0;result_q<=0;result_consumed_q<=0;
            next_generation_q<=RESET_GENERATION;
            owner_generation_q<=RESET_GENERATION;result_generation_q<=RESET_GENERATION;
        end else begin
            if(owner_valid && kill_owner)killed_q<=1'b1;
            if(fresh_result)begin
                result_q<=unit_result;result_generation_q<=owner_generation_q;
                state_q<=HOLD_RESULT;
            end
            if(consume_fire || drain_fire)begin
                state_q<=NONE;result_consumed_q<=1'b1;
            end
            if(issue_fire)begin
                state_q<=WAIT_RESULT;seq_q<=issue_seq;pc_q<=issue_pc;
                instr_q<=issue_instr;epoch_q<=issue_epoch;op_q<=issue_op;
                killed_q<=0;result_consumed_q<=0;
                owner_generation_q<=next_generation_q;
                next_generation_q<=next_generation_q+64'd1;
            end
        end
    end
    // synthesis translate_off
    initial if(SEQ_BITS!=64 || EPOCH_BITS<1)
        $fatal(1,"CPU5 M owner requires 64-bit age and positive epoch");
    always @(posedge clk)if(rst_n)begin
        if(generation_exhausted && state_q==NONE && issue_valid && !issue_killed)
            $fatal(1,"CPU5 M generation exhausted; reset required");
        if(unit_start_fire!==issue_fire)
            $fatal(1,"CPU5 M start differs from owner issue");
        if(issue_fire && (owner_valid || unit_busy || completion_valid || consume_fire || drain_fire))
            $fatal(1,"CPU5 M start overlaps old ownership or result consumption");
        if(completion_valid && (!owner_valid || result_consumed_q || result_generation!==owner_generation))
            $fatal(1,"CPU5 M completion generation or single-consume violation");
        if(state_q==NONE && unit_busy)
            $fatal(1,"CPU5 M busy unit lost its owner");
    end
    // synthesis translate_on
endmodule
