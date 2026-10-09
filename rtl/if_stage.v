module if_stage #(
    parameter PROGRAM_FILE = "programs/rv32i_regression.hex",
    parameter integer IMEM_WORDS = 1024,
    parameter integer EXTERNAL_IMEM = 0,
    parameter integer IMEM_REQ_WAIT_CYCLES = 0,
    parameter integer IMEM_RSP_WAIT_CYCLES = 0,
    parameter integer ENABLE_TRAPS = 0,
    parameter integer ENABLE_BRANCH_PRED = 0,
    parameter integer BTB_ENTRIES = 64
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        redirect_x,
    input  wire [31:0] redirect_pc_x,
    input  wire        stall_x,
    output reg  [31:0] pc_f,
    output reg  [31:0] pc_x,
    output reg  [31:0] instr_x,
    output reg         valid_x,
    output wire        imem_req_valid,
    input  wire        imem_req_ready,
    output wire [31:0] imem_req_addr,
    input  wire        imem_rsp_valid,
    output wire        imem_rsp_ready,
    input  wire [31:0] imem_rsp_rdata,
    input  wire        imem_rsp_error,
    output reg         imem_fault,
    output reg  [31:0] imem_fault_pc,
    input  wire        bp_update_valid,
    input  wire [31:0] bp_update_pc,
    input  wire [31:0] bp_update_target,
    input  wire        bp_update_taken,
    input  wire        bp_update_is_branch,
    input  wire        bp_update_is_jal,
    output reg  [31:0] predicted_next_pc_x,
    output reg         prediction_taken_x,
    output reg         prediction_hit_x,
    output wire [31:0] bp_lookup_count,
    output wire [31:0] bp_hit_count,
    output wire [31:0] bp_taken_count
);
    localparam [31:0] NOP = 32'h00000013;
    wire [31:0] instr_f;
    wire fetch_ok_f;
    // One accepted request is outstanding. A response may be consumed
    // on the same edge as the next request is accepted.
    reg [31:0] fetch_pc_q;
    reg [31:0] fetch_pred_next_q;
    reg        fetch_pred_taken_q;
    reg        fetch_pred_hit_q;
    reg        fetch_pending_q;
    reg        fetch_stale_q;
    // A presented request cannot be withdrawn or change address until
    // ready. Redirect marks it stale instead of breaking that contract.
    reg        req_hold_q;
    reg [31:0] req_pc_q;
    reg [31:0] req_pred_next_q;
    reg        req_pred_taken_q;
    reg        req_pred_hit_q;
    reg        req_stale_q;
    wire       fetch_req_valid, fetch_req_ready, fetch_req_fire;
    wire [31:0] fetch_req_addr;
    wire       fetch_req_stale;
    wire       fetch_rsp_valid, fetch_rsp_ready, fetch_rsp_fire;
    wire [31:0] fetch_rsp_rdata;
    wire       fetch_rsp_error, fetch_rsp_drop, fetch_rsp_fault;
    wire       local_req_ready, local_rsp_valid, local_rsp_error;
    wire [31:0] local_rsp_rdata;
    wire       request_ok;
    wire       lookup_hit, lookup_taken;
    wire [31:0] lookup_target;
    wire [31:0] fetch_req_pred_next;
    wire        fetch_req_pred_taken, fetch_req_pred_hit;

    assign fetch_req_pred_next = req_hold_q ? req_pred_next_q :
                                  lookup_taken ? lookup_target : fetch_req_addr + 32'd4;
    assign fetch_req_pred_taken = req_hold_q ? req_pred_taken_q : lookup_taken;
    assign fetch_req_pred_hit = req_hold_q ? req_pred_hit_q : lookup_hit;

    generate
        if (ENABLE_BRANCH_PRED != 0) begin : g_branch_predictor
            reg [31:0] lookup_count_q, hit_count_q, taken_count_q;
            branch_predictor #(.BTB_ENTRIES(BTB_ENTRIES)) u_branch_predictor (
                .clk(clk), .rst_n(rst_n), .query_pc(fetch_req_addr),
                .lookup_hit(lookup_hit), .lookup_taken(lookup_taken),
                .lookup_target(lookup_target),
                .update_valid(bp_update_valid), .update_pc(bp_update_pc),
                .update_target(bp_update_target), .update_taken(bp_update_taken),
                .update_is_branch(bp_update_is_branch), .update_is_jal(bp_update_is_jal)
            );
            assign bp_lookup_count = lookup_count_q;
            assign bp_hit_count = hit_count_q;
            assign bp_taken_count = taken_count_q;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    lookup_count_q <= 32'd0;
                    hit_count_q <= 32'd0;
                    taken_count_q <= 32'd0;
                end else if (fetch_req_fire && !fetch_req_stale) begin
                    lookup_count_q <= lookup_count_q + 32'd1;
                    if (fetch_req_pred_hit)
                        hit_count_q <= hit_count_q + 32'd1;
                    if (fetch_req_pred_taken)
                        taken_count_q <= taken_count_q + 32'd1;
                end
            end
        end else begin : g_no_branch_predictor
            assign lookup_hit = 1'b0;
            assign lookup_taken = 1'b0;
            assign lookup_target = fetch_req_addr + 32'd4;
            assign bp_lookup_count = 32'd0;
            assign bp_hit_count = 32'd0;
            assign bp_taken_count = 32'd0;
        end
    endgenerate

    assign fetch_rsp_valid = (EXTERNAL_IMEM != 0) ? imem_rsp_valid : local_rsp_valid;
    assign fetch_rsp_rdata = (EXTERNAL_IMEM != 0) ? imem_rsp_rdata : local_rsp_rdata;
    assign fetch_rsp_error = (EXTERNAL_IMEM != 0) ? imem_rsp_error : local_rsp_error;
    assign fetch_rsp_drop = fetch_stale_q || redirect_x;
    // Current-path errors wait behind older EX/data instructions too.
    // Legacy mode stops here. Trap mode keeps the fault descriptor until
    // CPU redirect acknowledges it, so older EX/data work finishes first.
    assign fetch_rsp_ready = rst_n && fetch_pending_q &&
                             (fetch_rsp_drop || !stall_x);
    assign fetch_rsp_fire = fetch_rsp_valid && fetch_rsp_ready;
    assign fetch_rsp_fault = fetch_rsp_fire && !fetch_rsp_drop && fetch_rsp_error;
    assign fetch_req_valid = rst_n &&
        (!imem_fault || ((ENABLE_TRAPS != 0) && redirect_x)) && !fetch_rsp_fault &&
        (req_hold_q || ((!fetch_pending_q || fetch_rsp_fire) && !stall_x));
    assign fetch_req_addr = req_hold_q ? req_pc_q :
                            redirect_x ? redirect_pc_x : pc_f;
    assign fetch_req_stale = req_hold_q && (req_stale_q || redirect_x);
    assign fetch_req_ready = (EXTERNAL_IMEM != 0) ? imem_req_ready : local_req_ready;
    assign fetch_req_fire = fetch_req_valid && fetch_req_ready;
    assign request_ok = (fetch_req_addr[1:0] == 2'b00) &&
                         (fetch_req_addr[31:2] < IMEM_WORDS);

    assign imem_req_valid = (EXTERNAL_IMEM != 0) && fetch_req_valid;
    assign imem_req_addr = fetch_req_addr;
    assign imem_rsp_ready = (EXTERNAL_IMEM != 0) && fetch_rsp_ready;

    // Preserve the direct hierarchy used by existing ROM monitors.
    instr_mem #(.WORDS(IMEM_WORDS), .INIT_FILE(PROGRAM_FILE)) u_instr_mem (
        .clk(clk), .en((EXTERNAL_IMEM == 0) && fetch_req_fire),
        .addr(fetch_req_addr), .instr(instr_f), .access_ok(fetch_ok_f)
    );
    instr_bus_adapter #(
        .REQ_WAIT_CYCLES(IMEM_REQ_WAIT_CYCLES),
        .RSP_WAIT_CYCLES(IMEM_RSP_WAIT_CYCLES)
    ) u_instr_bus_adapter (
        .clk(clk), .rst_n(rst_n),
        .req_valid((EXTERNAL_IMEM == 0) && fetch_req_valid),
        .req_ready(local_req_ready), .req_access_ok(request_ok),
        .instr_data(instr_f), .rsp_valid(local_rsp_valid),
        .rsp_ready((EXTERNAL_IMEM == 0) && fetch_rsp_ready),
        .rsp_rdata(local_rsp_rdata), .rsp_error(local_rsp_error)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_f <= 32'd0;
            pc_x <= 32'd0;
            instr_x <= NOP;
            valid_x <= 1'b0;
            predicted_next_pc_x <= 32'd0;
            prediction_taken_x <= 1'b0;
            prediction_hit_x <= 1'b0;
            fetch_pc_q <= 32'd0;
            fetch_pred_next_q <= 32'd0;
            fetch_pred_taken_q <= 1'b0;
            fetch_pred_hit_q <= 1'b0;
            fetch_pending_q <= 1'b0;
            fetch_stale_q <= 1'b0;
            req_hold_q <= 1'b0;
            req_pc_q <= 32'd0;
            req_pred_next_q <= 32'd0;
            req_pred_taken_q <= 1'b0;
            req_pred_hit_q <= 1'b0;
            req_stale_q <= 1'b0;
            imem_fault <= 1'b0;
            imem_fault_pc <= 32'd0;
        end else begin
            if (redirect_x)
                pc_f <= redirect_pc_x;
            if (fetch_req_fire && !fetch_req_stale)
                pc_f <= fetch_req_pred_next;

            if (fetch_rsp_fire) begin
                fetch_pending_q <= 1'b0;
                fetch_stale_q <= 1'b0;
            end else if (redirect_x && fetch_pending_q) begin
                fetch_stale_q <= 1'b1;
            end
            if (fetch_req_fire) begin
                fetch_pc_q <= fetch_req_addr;
                fetch_pred_next_q <= fetch_req_pred_next;
                fetch_pred_taken_q <= fetch_req_pred_taken;
                fetch_pred_hit_q <= fetch_req_pred_hit;
                fetch_pending_q <= 1'b1;
                fetch_stale_q <= fetch_req_stale;
                req_hold_q <= 1'b0;
                req_stale_q <= 1'b0;
            end else if (fetch_req_valid && !fetch_req_ready) begin
                req_hold_q <= 1'b1;
                req_pc_q <= fetch_req_addr;
                req_pred_next_q <= fetch_req_pred_next;
                req_pred_taken_q <= fetch_req_pred_taken;
                req_pred_hit_q <= fetch_req_pred_hit;
                req_stale_q <= fetch_req_stale;
            end

            if (redirect_x) begin
                pc_x <= fetch_pc_q;
                instr_x <= NOP;
                valid_x <= 1'b0;
                predicted_next_pc_x <= 32'd0;
                prediction_taken_x <= 1'b0;
                prediction_hit_x <= 1'b0;
            end else if (!stall_x) begin
                // EX consumed its previous instruction on this edge. A
                // missing response creates a bubble, never a repeated EX.
                instr_x <= NOP;
                valid_x <= 1'b0;
                predicted_next_pc_x <= 32'd0;
                prediction_taken_x <= 1'b0;
                prediction_hit_x <= 1'b0;
                if (fetch_rsp_fire && !fetch_rsp_drop && !fetch_rsp_error) begin
                    pc_x <= fetch_pc_q;
                    instr_x <= fetch_rsp_rdata;
                    valid_x <= 1'b1;
                    predicted_next_pc_x <= fetch_pred_next_q;
                    prediction_taken_x <= fetch_pred_taken_q;
                    prediction_hit_x <= fetch_pred_hit_q;
                end
            end
            if (fetch_rsp_fault) begin
                imem_fault <= 1'b1;
                imem_fault_pc <= fetch_pc_q;
            end else if ((ENABLE_TRAPS != 0) && redirect_x) begin
                // A trap or an older control redirect supersedes this fault.
                // The accepted-request stale mechanism still drains any
                // earlier response without admitting wrong-path errors.
                imem_fault <= 1'b0;
            end
        end
    end

    // synthesis translate_off
    initial begin
        if (ENABLE_BRANCH_PRED != 0 && ENABLE_BRANCH_PRED != 1)
            $fatal(1, "if_stage requires ENABLE_BRANCH_PRED=0 or 1");
        if (BTB_ENTRIES < 1 || BTB_ENTRIES > 1024 ||
            (BTB_ENTRIES & (BTB_ENTRIES - 1)) != 0)
            $fatal(1, "if_stage requires power-of-two BTB_ENTRIES in 1..1024");
    end
    // synthesis translate_on
endmodule


