// Direct-mapped BTB with a two-bit conditional-branch direction counter.
// A full PC tag prevents an index collision from predicting another branch.
module branch_predictor #(
    parameter integer BTB_ENTRIES = 64
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] query_pc,
    output wire        lookup_hit,
    output wire        lookup_taken,
    output wire [31:0] lookup_target,
    input  wire        update_valid,
    input  wire [31:0] update_pc,
    input  wire [31:0] update_target,
    input  wire        update_taken,
    input  wire        update_is_branch,
    input  wire        update_is_jal
);
    function integer index_width;
        input integer count;
        integer value;
        begin
            value = count - 1;
            index_width = 0;
            while (value > 0) begin
                index_width = index_width + 1;
                value = value >> 1;
            end
            if (index_width < 1)
                index_width = 1;
        end
    endfunction

    // Keep invalid parameter values elaboratable so the diagnostic below,
    // rather than a zero-sized array or division by zero, reports the error.
    localparam integer ENTRIES = (BTB_ENTRIES >= 1 && BTB_ENTRIES <= 1024 &&
                                  (BTB_ENTRIES & (BTB_ENTRIES - 1)) == 0) ?
                                  BTB_ENTRIES : 1;
    localparam integer INDEX_BITS = index_width(ENTRIES);
    reg        valid_q [0:ENTRIES-1];
    reg [31:0] pc_tag_q [0:ENTRIES-1];
    reg [31:0] target_q [0:ENTRIES-1];
    reg        is_jal_q [0:ENTRIES-1];
    reg [1:0]  direction_q [0:ENTRIES-1];
    wire [INDEX_BITS-1:0] query_index;
    wire [INDEX_BITS-1:0] update_index;
    wire update_match;
    integer entry;

    // Power-of-two entry counts reduce these constant modulos to wires.
    // The modulo also defines the single-entry configuration without a
    // zero-width PC slice.
    assign query_index = (query_pc >> 2) % ENTRIES;
    assign update_index = (update_pc >> 2) % ENTRIES;
    assign lookup_hit = (query_pc[1:0] == 2'b00) &&
                        valid_q[query_index] &&
                        (pc_tag_q[query_index] == query_pc) &&
                        (target_q[query_index][1:0] == 2'b00);
    assign lookup_taken = lookup_hit &&
                          (is_jal_q[query_index] || direction_q[query_index][1]);
    assign lookup_target = lookup_hit ? target_q[query_index] : query_pc + 32'd4;
    assign update_match = valid_q[update_index] &&
                          (pc_tag_q[update_index] == update_pc);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (entry = 0; entry < ENTRIES; entry = entry + 1) begin
                valid_q[entry] <= 1'b0;
                pc_tag_q[entry] <= 32'd0;
                target_q[entry] <= 32'd0;
                is_jal_q[entry] <= 1'b0;
                direction_q[entry] <= 2'b01;
            end
        end else if (update_valid && (update_pc[1:0] == 2'b00)) begin
            if (update_is_branch || update_is_jal) begin
                valid_q[update_index] <= (update_target[1:0] == 2'b00);
                pc_tag_q[update_index] <= update_pc;
                target_q[update_index] <= update_target;
                is_jal_q[update_index] <= update_is_jal;
                if (update_is_jal) begin
                    direction_q[update_index] <= 2'b11;
                end else if (!update_match || is_jal_q[update_index]) begin
                    // New conditional branches start weakly in the direction
                    // of their first observed, successfully executed outcome.
                    direction_q[update_index] <= update_taken ? 2'b10 : 2'b01;
                end else if (update_taken) begin
                    if (direction_q[update_index] != 2'b11)
                        direction_q[update_index] <= direction_q[update_index] + 2'b01;
                end else begin
                    if (direction_q[update_index] != 2'b00)
                        direction_q[update_index] <= direction_q[update_index] - 2'b01;
                end
            end else if (update_match) begin
                // JALR and ordinary instructions are never predicted here.
                // An executed replacement instruction invalidates a stale tag.
                valid_q[update_index] <= 1'b0;
            end
        end
    end

    // synthesis translate_off
    initial begin
        if (BTB_ENTRIES < 1 || BTB_ENTRIES > 1024 ||
            (BTB_ENTRIES & (BTB_ENTRIES - 1)) != 0)
            $fatal(1, "branch_predictor requires power-of-two BTB_ENTRIES in 1..1024");
    end
    // synthesis translate_on
endmodule
