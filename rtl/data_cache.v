// Blocking two-way write-through/no-write-allocate cache for ordinary RAM.
// CPU, bridge and memory must share reset. Completed RAM writes survive reset.
// No dirty lines, write buffer, speculative I/O or DMA coherence are provided.
module data_cache #(
    parameter integer SETS=64, LINE_WORDS=4, MEM_WORDS=4096,
    parameter [31:0] BASE_ADDR=32'h00010000
) (
    input wire clk,rst_n,
    input wire req_valid, output wire req_ready,
    input wire req_write, input wire [31:0] req_addr,
    input wire [1:0] req_size, input wire [31:0] req_wdata,
    input wire [3:0] req_wstrb,
    output wire rsp_valid, input wire rsp_ready,
    output wire [31:0] rsp_rdata, output wire rsp_error,
    output wire mem_req_valid, input wire mem_req_ready,
    output wire mem_req_write, output wire [31:0] mem_req_addr,
    output wire [1:0] mem_req_size, output wire [31:0] mem_req_wdata,
    output wire [3:0] mem_req_wstrb,
    input wire mem_rsp_valid, output wire mem_rsp_ready,
    input wire [31:0] mem_rsp_rdata, input wire mem_rsp_error,
    output reg [31:0] access_count,hit_count,miss_count,refill_word_count,
    output reg [31:0] error_count,write_count,bypass_count
);
    localparam integer SB=$clog2(SETS), WB=$clog2(LINE_WORDS), LB=WB+2;
    localparam integer AB=$clog2(MEM_WORDS)+2;
    localparam integer TB=AB>LB+SB ? AB-LB-SB : 1;
    localparam [2:0] IDLE=0,FILL_REQ=1,FILL_RSP=2,OUT_REQ=3,OUT_RSP=4,RESPONSE=5;
    reg [2:0] state;
    reg [SETS-1:0] valid0,valid1,victim_lru;
    reg [TB-1:0] tag0[0:SETS-1],tag1[0:SETS-1];
    reg [31:0] data0[0:SETS*LINE_WORDS-1],data1[0:SETS*LINE_WORDS-1];
    reg [31:0] read_data0,read_data1,rsp_data_q;
    reg hit_response_q,hit_way_q;
    assign rsp_rdata=hit_response_q ? (hit_way_q ? read_data1 : read_data0) : rsp_data_q;
    wire [31:0] offset=req_addr-BASE_ADDR;
    wire [SB-1:0] lookup_set=offset[LB+:SB];
    wire [WB-1:0] lookup_word=offset[2+:WB];
    wire [TB-1:0] lookup_tag=offset[LB+SB+:TB];
    wire in_range=({1'b0,req_addr}>={1'b0,BASE_ADDR}) &&
        ({1'b0,req_addr}<({1'b0,BASE_ADDR}+33'd4*MEM_WORDS));
    wire aligned=(req_size==0) || (req_size==1 && !req_addr[0]) ||
        (req_size==2 && req_addr[1:0]==0);
    wire [3:0] expected_strobe=req_size==0 ? (4'b0001<<req_addr[1:0]) :
        req_size==1 ? (4'b0011<<req_addr[1:0]) : 4'b1111;
    wire request_ok=aligned && (!req_write || req_wstrb==expected_strobe);
    wire hit0=valid0[lookup_set] && tag0[lookup_set]==lookup_tag;
    wire hit1=valid1[lookup_set] && tag1[lookup_set]==lookup_tag;
    wire victim=!valid0[lookup_set] ? 1'b0 : !valid1[lookup_set] ? 1'b1 : victim_lru[lookup_set];
    reg write_q,write_hit_q,way_q;
    reg rsp_error_q;
    // The bridge holds its completed write response until the CPU
    // consumes it. Bypass only the cache response register for writes.
    wire write_rsp_bypass=(state==OUT_RSP) && write_q;
    assign rsp_error=write_rsp_bypass ? mem_rsp_error : rsp_error_q;
    reg [31:0] addr_q,wdata_q,fill_base,wanted_data;
    reg [1:0] size_q;
    reg [3:0] strobe_q;
    reg [SB-1:0] set_q;
    reg [TB-1:0] tag_q;
    reg [WB-1:0] word_q,fill_word;
    reg access_event,hit_event,miss_event,refill_event,error_event,write_event,bypass_event;
    wire request_fire=req_valid && req_ready;
    wire memory_fire=mem_rsp_valid && mem_rsp_ready;

    assign req_ready=rst_n && (state==IDLE || (state==RESPONSE && rsp_ready));
    assign rsp_valid=rst_n && (state==RESPONSE ||
        (write_rsp_bypass && mem_rsp_valid));
    assign mem_req_valid=rst_n && (state==FILL_REQ || state==OUT_REQ);
    assign mem_req_write=state==OUT_REQ && write_q;
    assign mem_req_addr=state==FILL_REQ ? fill_base+({{(32-WB){1'b0}},fill_word}<<2) : addr_q;
    assign mem_req_size=state==FILL_REQ ? 2'd2 : size_q;
    assign mem_req_wdata=wdata_q;
    assign mem_req_wstrb=state==FILL_REQ ? 4'b0000 : strobe_q;
    assign mem_rsp_ready=rst_n && (state==FILL_RSP ||
        (state==OUT_RSP && (!write_q || rsp_ready)));

    // Separate synchronous array processes retain byte write enables and avoid
    // resetting RAM contents. Protocol valid bits protect every lookup.
    wire filling=state==FILL_RSP;
    wire cache_we=rst_n && memory_fire && !mem_rsp_error && (filling || write_hit_q);
    wire [SB+WB-1:0] cache_windex={set_q,(filling ? fill_word : word_q)};
    wire [31:0] cache_wdata=filling ? mem_rsp_rdata : wdata_q;
    wire [3:0] cache_wstrobe=filling ? 4'b1111 : strobe_q;
    always @(posedge clk) begin
        // Explicit synchronous read registers let the FPGA infer block RAM.
        // They hold under CPU response backpressure; a new accepted request
        // may replace them only when the previous response is consumed.
        if(request_fire) begin
            read_data0<=data0[{lookup_set,lookup_word}];
            read_data1<=data1[{lookup_set,lookup_word}];
        end
        if(cache_we && way_q) begin
            if(cache_wstrobe[0]) data1[cache_windex][7:0]<=cache_wdata[7:0];
            if(cache_wstrobe[1]) data1[cache_windex][15:8]<=cache_wdata[15:8];
            if(cache_wstrobe[2]) data1[cache_windex][23:16]<=cache_wdata[23:16];
            if(cache_wstrobe[3]) data1[cache_windex][31:24]<=cache_wdata[31:24];
        end
        if(cache_we && !way_q) begin
            if(cache_wstrobe[0]) data0[cache_windex][7:0]<=cache_wdata[7:0];
            if(cache_wstrobe[1]) data0[cache_windex][15:8]<=cache_wdata[15:8];
            if(cache_wstrobe[2]) data0[cache_windex][23:16]<=cache_wdata[23:16];
            if(cache_wstrobe[3]) data0[cache_windex][31:24]<=cache_wdata[31:24];
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;valid0<=0;valid1<=0;victim_lru<=0;
            write_q<=0;write_hit_q<=0;way_q<=0;addr_q<=0;wdata_q<=0;
            size_q<=0;strobe_q<=0;set_q<=0;tag_q<=0;word_q<=0;fill_word<=0;
            fill_base<=0;wanted_data<=0;rsp_data_q<=0;rsp_error_q<=0;
            hit_response_q<=0;hit_way_q<=0;
            access_count<=0;hit_count<=0;miss_count<=0;refill_word_count<=0;
            error_count<=0;write_count<=0;bypass_count<=0;
            access_event<=0;hit_event<=0;miss_event<=0;refill_event<=0;
            error_event<=0;write_event<=0;bypass_event<=0;
        end else begin
            access_event<=0;hit_event<=0;miss_event<=0;refill_event<=0;
            error_event<=0;write_event<=0;bypass_event<=0;
            if(access_event) access_count<=access_count+1;
            if(hit_event) hit_count<=hit_count+1;
            if(miss_event) miss_count<=miss_count+1;
            if(refill_event) refill_word_count<=refill_word_count+1;
            if(error_event) error_count<=error_count+1;
            if(write_event) write_count<=write_count+1;
            if(bypass_event) bypass_count<=bypass_count+1;
            if(state==RESPONSE && rsp_ready) state<=IDLE;
            if(request_fire) begin
                access_event<=1;addr_q<=req_addr;size_q<=req_size;
                hit_response_q<=0;hit_way_q<=!hit0;
                wdata_q<=req_wdata;strobe_q<=req_wstrb;write_q<=req_write;
                set_q<=lookup_set;tag_q<=lookup_tag;word_q<=lookup_word;
                fill_base<={req_addr[31:LB],{LB{1'b0}}};fill_word<=0;
                way_q<=req_write ? !hit0 : victim;
                write_hit_q<=request_ok && in_range && req_write && (hit0||hit1);
                rsp_data_q<=0;rsp_error_q<=0;
                if(!request_ok) begin
                    rsp_error_q<=1;error_event<=1;state<=RESPONSE;
                end else if(!in_range) begin
                    bypass_event<=1;state<=OUT_REQ;
                end else if(req_write) begin
                    write_event<=1;state<=OUT_REQ;
                end else if(hit0||hit1) begin
                    hit_response_q<=1;
                    victim_lru[lookup_set]<=hit0;hit_event<=1;state<=RESPONSE;
                end else begin
                    miss_event<=1;state<=FILL_REQ;
                end
            end
            if(state==FILL_REQ && fill_word==0) begin
                if(way_q) valid1[set_q]<=0;else valid0[set_q]<=0;
            end
            if(state==OUT_REQ && write_hit_q) begin
                // Also invalidate on a failed/partially committed backend write.
                if(way_q) valid1[set_q]<=0;else valid0[set_q]<=0;
            end
            if(mem_req_valid && mem_req_ready) state<=state==FILL_REQ ? FILL_RSP : OUT_RSP;
            if(memory_fire) begin
                if(mem_rsp_error) begin
                    rsp_data_q<=0;rsp_error_q<=1;error_event<=1;
                    state<=write_rsp_bypass ? IDLE : RESPONSE;
                end else if(state==OUT_RSP) begin
                    if(write_hit_q) begin
                        if(way_q) valid1[set_q]<=1;else valid0[set_q]<=1;
                        victim_lru[set_q]<=!way_q;
                    end
                    rsp_data_q<=write_q ? 32'd0 : mem_rsp_rdata;rsp_error_q<=0;
                    state<=write_q ? IDLE : RESPONSE;
                end else begin
                    refill_event<=1;
                    if(fill_word==word_q) wanted_data<=mem_rsp_rdata;
                    if(fill_word==LINE_WORDS-1) begin
                        if(way_q) begin tag1[set_q]<=tag_q;valid1[set_q]<=1;end
                        else begin tag0[set_q]<=tag_q;valid0[set_q]<=1;end
                        victim_lru[set_q]<=!way_q;
                        rsp_data_q<=fill_word==word_q ? mem_rsp_rdata : wanted_data;
                        rsp_error_q<=0;state<=RESPONSE;
                    end else begin fill_word<=fill_word+1'b1;state<=FILL_REQ;end
                end
            end
        end
    end
    // synthesis translate_off
    initial begin
        if(SETS<2 || (SETS&(SETS-1))!=0 || LINE_WORDS<2 || (LINE_WORDS&(LINE_WORDS-1))!=0 ||
           MEM_WORDS<LINE_WORDS || MEM_WORDS%LINE_WORDS!=0 || LB+SB+TB>32 ||
           BASE_ADDR%(LINE_WORDS*4)!=0 || ({1'b0,BASE_ADDR}+33'd4*MEM_WORDS)>33'h100000000)
            $fatal(1,"data_cache requires complete/aligned RAM lines and power-of-two sets/line");
    end
    // synthesis translate_on
endmodule
