// Direct-mapped BTB with a two-bit conditional-branch direction counter.
// A ROM-relative PC tag and word target retain exact in-ROM addresses.
// Four branch counters, INVALID and JAL share one three-bit state field.
module branch_predictor #(
    parameter integer BTB_ENTRIES = 64,
    parameter integer IMEM_WORDS = 8192
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
        end
    endfunction

    // Keep invalid parameter values elaboratable so the diagnostic below,
    // rather than a zero-sized array or division by zero, reports the error.
    localparam integer ENTRIES = (BTB_ENTRIES >= 1 && BTB_ENTRIES <= 1024 &&
                                  (BTB_ENTRIES & (BTB_ENTRIES - 1)) == 0) ?
                                  BTB_ENTRIES : 1;
    localparam integer ROM_WORDS = (IMEM_WORDS >= 1 && IMEM_WORDS <= 1073741824) ? IMEM_WORDS : 1;
    localparam integer SLOT_BITS = index_width(ENTRIES);
    localparam integer INDEX_BITS = SLOT_BITS > 0 ? SLOT_BITS : 1;
    localparam integer ROM_WORD_BITS = index_width(ROM_WORDS);
    localparam integer TARGET_BITS = ROM_WORD_BITS > 0 ? ROM_WORD_BITS : 1;
    localparam integer TAG_BITS = ROM_WORD_BITS > SLOT_BITS ? ROM_WORD_BITS-SLOT_BITS : 1;
    localparam integer ENTRY_BITS = TAG_BITS + TARGET_BITS + 3;
    localparam [2:0] STATE_INVALID = 3'b100, STATE_JAL = 3'b101;
    reg [TAG_BITS-1:0] pc_tag_q [0:ENTRIES-1];
    reg [TARGET_BITS-1:0] target_q [0:ENTRIES-1];
    reg [2:0] state_q [0:ENTRIES-1];
    wire [INDEX_BITS-1:0] query_index;
    wire [INDEX_BITS-1:0] update_index;
    wire [TAG_BITS-1:0] query_tag, update_tag;
    wire [TARGET_BITS-1:0] update_target_word;
    wire query_pc_in_rom, update_pc_in_rom, update_target_in_rom;
    wire [2:0] query_state, update_state;
    wire [1:0] update_direction;
    wire update_match;
    integer entry;

    // Power-of-two entry counts reduce these constant modulos to wires.
    // The modulo also defines the single-entry configuration without a
    // zero-width PC slice.
    assign query_index = (query_pc >> 2) % ENTRIES;
    assign update_index = (update_pc >> 2) % ENTRIES;
    assign query_tag = (query_pc >> 2) >> SLOT_BITS;
    assign update_tag = (update_pc >> 2) >> SLOT_BITS;
    assign update_target_word = update_target >> 2;
    // Guard the complete address before using a narrowed tag or target.
    // This also handles a non-power-of-two ROM without high-PC aliases.
    assign query_pc_in_rom = (query_pc[1:0] == 2'b00) && (query_pc[31:2] < ROM_WORDS);
    assign update_pc_in_rom = (update_pc[1:0] == 2'b00) && (update_pc[31:2] < ROM_WORDS);
    assign update_target_in_rom = (update_target[1:0] == 2'b00) && (update_target[31:2] < ROM_WORDS);
    assign query_state = state_q[query_index];
    assign update_state = state_q[update_index];
    assign update_direction = update_state[1:0];
    assign lookup_hit = query_pc_in_rom &&
                        ((query_state <= 3'b011) || query_state == STATE_JAL) &&
                        (pc_tag_q[query_index] == query_tag) &&
                        (target_q[query_index] < ROM_WORDS);
    assign lookup_taken = lookup_hit &&
                          ((query_state == STATE_JAL) || query_state[1]);
    assign lookup_target = lookup_hit ? {target_q[query_index], 2'b00} : query_pc + 32'd4;
    assign update_match = ((update_state <= 3'b011) || update_state == STATE_JAL) &&
                          (pc_tag_q[update_index] == update_tag);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (entry = 0; entry < ENTRIES; entry = entry + 1) begin
                pc_tag_q[entry] <= 0;
                target_q[entry] <= 0;
                state_q[entry] <= STATE_INVALID;
            end
        end else if (update_valid && update_pc_in_rom) begin
            if (update_is_branch || update_is_jal) begin
                pc_tag_q[update_index] <= update_tag;
                target_q[update_index] <= update_target_word;
                if (!update_target_in_rom) begin
                    // Preserve invalid-target replacement semantics: even a
                    // different PC at this index must lose its old prediction.
                    state_q[update_index] <= STATE_INVALID;
                end else if (update_is_jal) begin
                    state_q[update_index] <= STATE_JAL;
                end else if (!update_match || update_state == STATE_JAL) begin
                    // New conditional branches start weakly in the direction
                    // of their first observed, successfully executed outcome.
                    state_q[update_index] <= update_taken ? 3'b010 : 3'b001;
                end else if (update_taken) begin
                    if (update_direction != 2'b11)
                        state_q[update_index] <= {1'b0, update_direction + 2'b01};
                end else begin
                    if (update_direction != 2'b00)
                        state_q[update_index] <= {1'b0, update_direction - 2'b01};
                end
            end else if (update_match) begin
                // JALR and ordinary instructions are never predicted here.
                // An executed replacement instruction invalidates a stale tag.
                state_q[update_index] <= STATE_INVALID;
            end
        end
    end

    // synthesis translate_off
    initial begin
        if (BTB_ENTRIES < 1 || BTB_ENTRIES > 1024 ||
            (BTB_ENTRIES & (BTB_ENTRIES - 1)) != 0)
            $fatal(1, "branch_predictor requires power-of-two BTB_ENTRIES in 1..1024");
        if (IMEM_WORDS < 1 || IMEM_WORDS > 1073741824)
            $fatal(1, "branch_predictor requires IMEM_WORDS in 1..1073741824");
    end
    // synthesis translate_on
endmodule
