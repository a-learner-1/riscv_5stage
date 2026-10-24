// Independent CPU5 native-port cache adapter. Local MMIO stays upstream.
// Both ends share reset; redirects/kills never cancel cache transactions.
module cpu5_cache_adapter #(
    parameter integer ENABLE_ICACHE=0, ENABLE_DCACHE=0,
    ICACHE_SETS=64, ICACHE_LINE_WORDS=4, DCACHE_SETS=64, DCACHE_LINE_WORDS=4,
    IMEM_WORDS=8192, DMEM_WORDS=4096,
    parameter [31:0] DMEM_BASE_ADDR=32'h00010000
)(
    input wire clk,rst_n,
    input wire cpu_imem_req_valid,
    output wire cpu_imem_req_ready,
    input wire [31:0] cpu_imem_req_addr,
    output wire cpu_imem_rsp_valid,
    input wire cpu_imem_rsp_ready,
    output wire [31:0] cpu_imem_rsp_rdata,
    output wire cpu_imem_rsp_error,
    input wire cpu_dmem_req_valid,
    output wire cpu_dmem_req_ready,
    input wire cpu_dmem_req_write,
    input wire [31:0] cpu_dmem_req_addr,
    input wire [1:0] cpu_dmem_req_size,
    input wire [31:0] cpu_dmem_req_wdata,
    input wire [3:0] cpu_dmem_req_wstrb,
    output wire cpu_dmem_rsp_valid,
    input wire cpu_dmem_rsp_ready,
    output wire [31:0] cpu_dmem_rsp_rdata,
    output wire cpu_dmem_rsp_error,
    output wire mem_imem_req_valid,
    input wire mem_imem_req_ready,
    output wire [31:0] mem_imem_req_addr,
    input wire mem_imem_rsp_valid,
    output wire mem_imem_rsp_ready,
    input wire [31:0] mem_imem_rsp_rdata,
    input wire mem_imem_rsp_error,
    output wire mem_dmem_req_valid,
    input wire mem_dmem_req_ready,
    output wire mem_dmem_req_write,
    output wire [31:0] mem_dmem_req_addr,
    output wire [1:0] mem_dmem_req_size,
    output wire [31:0] mem_dmem_req_wdata,
    output wire [3:0] mem_dmem_req_wstrb,
    input wire mem_dmem_rsp_valid,
    output wire mem_dmem_rsp_ready,
    input wire [31:0] mem_dmem_rsp_rdata,
    input wire mem_dmem_rsp_error,
    output wire [31:0] icache_access_count,
    output wire [31:0] icache_hit_count,
    output wire [31:0] icache_miss_count,
    output wire [31:0] icache_refill_word_count,
    output wire [31:0] icache_error_count,
    output wire [31:0] dcache_access_count,
    output wire [31:0] dcache_hit_count,
    output wire [31:0] dcache_miss_count,
    output wire [31:0] dcache_refill_word_count,
    output wire [31:0] dcache_error_count,
    output wire [31:0] dcache_write_count,
    output wire [31:0] dcache_bypass_count
);
    generate if(ENABLE_ICACHE)begin:g_icache
        instr_cache #(.SETS(ICACHE_SETS),.LINE_WORDS(ICACHE_LINE_WORDS),.MEM_WORDS(IMEM_WORDS)) u_cache(
            .clk(clk),
            .rst_n(rst_n),
            .req_valid(cpu_imem_req_valid),
            .req_ready(cpu_imem_req_ready),
            .req_addr(cpu_imem_req_addr),
            .rsp_valid(cpu_imem_rsp_valid),
            .rsp_ready(cpu_imem_rsp_ready),
            .rsp_rdata(cpu_imem_rsp_rdata),
            .rsp_error(cpu_imem_rsp_error),
            .mem_req_valid(mem_imem_req_valid),
            .mem_req_ready(mem_imem_req_ready),
            .mem_req_addr(mem_imem_req_addr),
            .mem_rsp_valid(mem_imem_rsp_valid),
            .mem_rsp_ready(mem_imem_rsp_ready),
            .mem_rsp_rdata(mem_imem_rsp_rdata),
            .mem_rsp_error(mem_imem_rsp_error),
            .access_count(icache_access_count),
            .hit_count(icache_hit_count),
            .miss_count(icache_miss_count),
            .refill_word_count(icache_refill_word_count),
            .error_count(icache_error_count)
        );
    end else begin:g_no_icache
        assign mem_imem_req_valid=cpu_imem_req_valid;
        assign cpu_imem_req_ready=mem_imem_req_ready;
        assign mem_imem_req_addr=cpu_imem_req_addr;
        assign cpu_imem_rsp_valid=mem_imem_rsp_valid;
        assign mem_imem_rsp_ready=cpu_imem_rsp_ready;
        assign cpu_imem_rsp_rdata=mem_imem_rsp_rdata;
        assign cpu_imem_rsp_error=mem_imem_rsp_error;
        assign icache_access_count=0;
        assign icache_hit_count=0;
        assign icache_miss_count=0;
        assign icache_refill_word_count=0;
        assign icache_error_count=0;
    end endgenerate
    generate if(ENABLE_DCACHE)begin:g_dcache
        data_cache #(.SETS(DCACHE_SETS),.LINE_WORDS(DCACHE_LINE_WORDS),.MEM_WORDS(DMEM_WORDS),.BASE_ADDR(DMEM_BASE_ADDR)) u_cache(
            .clk(clk),
            .rst_n(rst_n),
            .req_valid(cpu_dmem_req_valid),
            .req_ready(cpu_dmem_req_ready),
            .req_write(cpu_dmem_req_write),
            .req_addr(cpu_dmem_req_addr),
            .req_size(cpu_dmem_req_size),
            .req_wdata(cpu_dmem_req_wdata),
            .req_wstrb(cpu_dmem_req_wstrb),
            .rsp_valid(cpu_dmem_rsp_valid),
            .rsp_ready(cpu_dmem_rsp_ready),
            .rsp_rdata(cpu_dmem_rsp_rdata),
            .rsp_error(cpu_dmem_rsp_error),
            .mem_req_valid(mem_dmem_req_valid),
            .mem_req_ready(mem_dmem_req_ready),
            .mem_req_write(mem_dmem_req_write),
            .mem_req_addr(mem_dmem_req_addr),
            .mem_req_size(mem_dmem_req_size),
            .mem_req_wdata(mem_dmem_req_wdata),
            .mem_req_wstrb(mem_dmem_req_wstrb),
            .mem_rsp_valid(mem_dmem_rsp_valid),
            .mem_rsp_ready(mem_dmem_rsp_ready),
            .mem_rsp_rdata(mem_dmem_rsp_rdata),
            .mem_rsp_error(mem_dmem_rsp_error),
            .access_count(dcache_access_count),
            .hit_count(dcache_hit_count),
            .miss_count(dcache_miss_count),
            .refill_word_count(dcache_refill_word_count),
            .error_count(dcache_error_count),
            .write_count(dcache_write_count),
            .bypass_count(dcache_bypass_count)
        );
    end else begin:g_no_dcache
        assign mem_dmem_req_valid=cpu_dmem_req_valid;
        assign cpu_dmem_req_ready=mem_dmem_req_ready;
        assign mem_dmem_req_write=cpu_dmem_req_write;
        assign mem_dmem_req_addr=cpu_dmem_req_addr;
        assign mem_dmem_req_size=cpu_dmem_req_size;
        assign mem_dmem_req_wdata=cpu_dmem_req_wdata;
        assign mem_dmem_req_wstrb=cpu_dmem_req_wstrb;
        assign cpu_dmem_rsp_valid=mem_dmem_rsp_valid;
        assign mem_dmem_rsp_ready=cpu_dmem_rsp_ready;
        assign cpu_dmem_rsp_rdata=mem_dmem_rsp_rdata;
        assign cpu_dmem_rsp_error=mem_dmem_rsp_error;
        assign dcache_access_count=0;
        assign dcache_hit_count=0;
        assign dcache_miss_count=0;
        assign dcache_refill_word_count=0;
        assign dcache_error_count=0;
        assign dcache_write_count=0;
        assign dcache_bypass_count=0;
    end endgenerate
    // synthesis translate_off
    initial if((ENABLE_ICACHE!=0 && ENABLE_ICACHE!=1) || (ENABLE_DCACHE!=0 && ENABLE_DCACHE!=1))
        $fatal(1,"CPU5 cache adapter requires boolean cache enables");
    // synthesis translate_on
endmodule
