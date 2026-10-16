// Blocking, read-only, two-way instruction cache. CPU and ROM share reset.
// Hit response takes one clock; a miss refills the entire line before reply.
// Data/tag RAMs are not reset. Valid bits protect their uninitialized contents.
module instr_cache #(
    parameter integer SETS = 64,
    parameter integer LINE_WORDS = 4,
    parameter integer MEM_WORDS = 8192
) (
    input wire clk, rst_n,
    input wire req_valid, output wire req_ready, input wire [31:0] req_addr,
    output wire rsp_valid, input wire rsp_ready,
    output reg [31:0] rsp_rdata, output reg rsp_error,
    output wire mem_req_valid, input wire mem_req_ready,
    output wire [31:0] mem_req_addr,
    input wire mem_rsp_valid, output wire mem_rsp_ready,
    input wire [31:0] mem_rsp_rdata, input wire mem_rsp_error,
    output reg [31:0] access_count, hit_count, miss_count,
    output reg [31:0] refill_word_count, error_count
);
    localparam integer SB = $clog2(SETS), WB = $clog2(LINE_WORDS);
    // Only in-range ROM requests can install a tag. Keep the tag as wide as
    // the ROM address, rather than storing/comparing always-zero high bits.
    // The full 32-bit range check below prevents high-address aliasing.
    localparam integer LB = WB + 2, AB = $clog2(MEM_WORDS) + 2;
    localparam integer TB = AB>LB+SB ? AB-LB-SB : 1;
    localparam [1:0] IDLE=0, FILL_REQ=1, FILL_RSP=2, RESPONSE=3;
    reg [1:0] state;
    reg [SETS-1:0] valid0, valid1, victim_lru;
    reg [TB-1:0] tag0[0:SETS-1], tag1[0:SETS-1];
    reg [31:0] data0[0:SETS*LINE_WORDS-1], data1[0:SETS*LINE_WORDS-1];
    wire [SB-1:0] lookup_set=req_addr[LB+:SB];
    wire [WB-1:0] lookup_word=req_addr[2+:WB];
    wire [TB-1:0] lookup_tag=req_addr[LB+SB+:TB];
    wire hit0=valid0[lookup_set] && tag0[lookup_set]==lookup_tag;
    wire hit1=valid1[lookup_set] && tag1[lookup_set]==lookup_tag;
    wire recent_victim;
    wire victim= !valid0[lookup_set] ? 1'b0 :
                 !valid1[lookup_set] ? 1'b1 : recent_victim;
    // Commit hit LRU through registered metadata, so a late CPU redirect
    // does not drive the distributed LRU array's write-enable decoder.
    // Forward the pending value to an immediately following same-set miss.
    reg lru_pending,lru_value;
    reg [SB-1:0] lru_set;
    assign recent_victim=lru_pending && lru_set==lookup_set ? lru_value : victim_lru[lookup_set];
    reg fill_way;
    reg [SB-1:0] fill_set;
    reg [WB-1:0] fill_word, wanted_word;
    reg [TB-1:0] fill_tag;
    reg [31:0] fill_base, wanted_data;
    // Delay statistics events one clock so the late redirect/tag-compare
    // path does not drive a 32-bit counter's carry/clock-enable chain.
    // All events use the same delay; hit latency and cache state are unchanged.
    reg access_event,hit_event,miss_event,refill_event,error_event;

    assign req_ready=rst_n && (state==IDLE || (state==RESPONSE && rsp_ready));
    assign rsp_valid=rst_n && state==RESPONSE;
    assign mem_req_valid=rst_n && state==FILL_REQ;
    assign mem_req_addr=fill_base + ({ {(32-WB){1'b0}}, fill_word } << 2);
    assign mem_rsp_ready=rst_n && state==FILL_RSP;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; valid0<=0; valid1<=0; victim_lru<=0;
            lru_pending<=0;lru_value<=0;lru_set<=0;
            fill_way<=0; fill_set<=0; fill_word<=0; wanted_word<=0;
            fill_tag<=0; fill_base<=0; wanted_data<=0;
            rsp_rdata<=0; rsp_error<=0;
            access_count<=0; hit_count<=0; miss_count<=0;
            refill_word_count<=0; error_count<=0;
            access_event<=0;hit_event<=0;miss_event<=0;refill_event<=0;error_event<=0;
        end else begin
            lru_pending<=0;
            if(lru_pending) victim_lru[lru_set]<=lru_value;
            // Only lru_pending qualifies this metadata on the next edge.
            // Unconditional capture keeps the late hit/range decision off
            // the metadata register clock enables, including same-set misses.
            lru_set<=lookup_set;lru_value<=hit0;
            access_event<=0;hit_event<=0;miss_event<=0;refill_event<=0;error_event<=0;
            if(access_event) access_count<=access_count+1;
            if(hit_event) hit_count<=hit_count+1;
            if(miss_event) miss_count<=miss_count+1;
            if(refill_event) refill_word_count<=refill_word_count+1;
            if(error_event) error_count<=error_count+1;
            if(state==RESPONSE && rsp_ready) state<=IDLE;
            if(req_valid && req_ready) begin
                // Capture request metadata independently of the hit decision.
                // None of it is used on a hit; this keeps tag comparison off
                // the refill register clock enables on a late CPU redirect.
                fill_way<=victim; fill_set<=lookup_set; fill_tag<=lookup_tag;
                fill_base<={req_addr[31:LB],{LB{1'b0}}};
                fill_word<=0; wanted_word<=lookup_word;
                access_event<=1;
                if(req_addr[1:0]!=0 || {32'd0,req_addr}>=(64'd4*MEM_WORDS)) begin
                    // Out-of-range/misaligned accesses never touch the ROM.
                    rsp_rdata<=0; rsp_error<=1; state<=RESPONSE;
                    error_event<=1;
                end else if(hit0 || hit1) begin
                    rsp_rdata<=hit0 ? data0[{lookup_set,lookup_word}] : data1[{lookup_set,lookup_word}];
                    rsp_error<=0; state<=RESPONSE;
                    lru_pending<=1; // opposite way is least recent
                    hit_event<=1;
                end else begin
                    miss_event<=1;
                    state<=FILL_REQ;
                end
            end
            // Invalidate from registered miss state, before any refill reply.
            if(state==FILL_REQ && fill_word==0) begin
                if(fill_way) valid1[fill_set]<=0; else valid0[fill_set]<=0;
            end
            if(mem_req_valid && mem_req_ready) state<=FILL_RSP;
            if(mem_rsp_valid && mem_rsp_ready) begin
                if(mem_rsp_error) begin
                    // The victim remains invalid after even a late refill error.
                    rsp_rdata<=0; rsp_error<=1; state<=RESPONSE;
                    error_event<=1;
                end else begin
                    if(fill_way) data1[{fill_set,fill_word}]<=mem_rsp_rdata;
                    else data0[{fill_set,fill_word}]<=mem_rsp_rdata;
                    refill_event<=1;
                    if(fill_word==wanted_word) wanted_data<=mem_rsp_rdata;
                    if(fill_word==LINE_WORDS-1) begin
                        if(fill_way) begin tag1[fill_set]<=fill_tag; valid1[fill_set]<=1; end
                        else begin tag0[fill_set]<=fill_tag; valid0[fill_set]<=1; end
                        victim_lru[fill_set]<=!fill_way;
                        rsp_rdata<=fill_word==wanted_word ? mem_rsp_rdata : wanted_data;
                        rsp_error<=0; state<=RESPONSE;
                    end else begin fill_word<=fill_word+1'b1; state<=FILL_REQ; end
                end
            end
        end
    end
    // synthesis translate_off
    initial begin
        if(SETS<2 || (SETS&(SETS-1))!=0 || LINE_WORDS<2 || (LINE_WORDS&(LINE_WORDS-1))!=0 ||
           LB+SB+TB>32 || MEM_WORDS<LINE_WORDS || MEM_WORDS%LINE_WORDS!=0)
            $fatal(1,"instr_cache requires power-of-two sets/line and complete ROM lines");
    end
    // synthesis translate_on
endmodule
