"""Prove the CoreMark stop harness is a mechanical wrapper-only transform."""
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
PARTS = (
    ("rtl/cpu5_stats_axi_lite_top.v", "cpu5_stats_axi_lite_top", "cpu5_coremark_system_harness"),
    ("rtl/cpu5_d0_axi_lite_top.v", "cpu5_d0_axi_lite_top", "cpu5_coremark_d0_harness"),
    ("rtl/cpu5_cached_top.v", "cpu5_cached_top", "cpu5_coremark_cached_harness"),
)
GATE = '''    // Test-only stop barrier. A request already presented under backpressure
    // keeps VALID/address until handshake. Only later presentations are blocked.
    wire cache_imem_req_ready;
    reg presented_q = 0;
    reg [31:0] presented_addr_q;
    integer if_accepted_count = 0, if_returned_count = 0;
    wire allow_fetch = fetch_enable || presented_q;
    wire cache_imem_req_valid = cpu_imem_req_valid && allow_fetch;
    assign cpu_imem_req_ready = cache_imem_req_ready && allow_fetch;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            presented_q <= 0;
            presented_addr_q <= 0;
            if_accepted_count <= 0;
            if_returned_count <= 0;
        end else begin
            if (presented_q && (!cpu_imem_req_valid || cpu_imem_req_addr !== presented_addr_q))
                $fatal(1, "CoreMark stop barrier withdrew a presented IF request");
            presented_q <= cache_imem_req_valid && !cache_imem_req_ready;
            if (cache_imem_req_valid && !cache_imem_req_ready)
                presented_addr_q <= cpu_imem_req_addr;
            if (cache_imem_req_valid && cache_imem_req_ready)
                if_accepted_count <= if_accepted_count + 1;
            if (cpu_imem_rsp_valid && cpu_imem_rsp_ready)
                if_returned_count <= if_returned_count + 1;
            if (cpu_imem_rsp_valid && if_returned_count >= if_accepted_count)
                $fatal(1, "CoreMark stop barrier received an unowned IF response");
        end
    end
'''
HEADER = '''// Test-only copies of the three unmodified product integration wrappers.
// tools/test_cpu5_coremark_harness.py proves exact derivation, including this
// only behavior change: a protocol-safe CPU-side IF stop barrier after TOHOST.
// With fetch_enable=1 every request/response wire has the product behavior.
`ifndef CPU5_COREMARK_HARNESS_V
`define CPU5_COREMARK_HARNESS_V
'''
def transformed():
    result = []
    for path, old, new in PARTS:
        source = (ROOT / path).read_text(encoding="utf-8")
        source = source.replace("module " + old + " #(", "module " + new + " #(", 1)
        source = source.replace("    input wire clk,rst_n", "    input wire fetch_enable,\n    input wire clk,rst_n", 1)
        if old == "cpu5_stats_axi_lite_top":
            source = source.replace("    cpu5_d0_axi_lite_top #(", "    cpu5_coremark_d0_harness #(", 1)
            source = source.replace(") u_core (", ") u_core (\n        .fetch_enable(fetch_enable),", 1)
        elif old == "cpu5_d0_axi_lite_top":
            source = source.replace("    cpu5_cached_top #(", "    cpu5_coremark_cached_harness #(", 1)
            source = source.replace(") u_cached(", ") u_cached(\n        .fetch_enable(fetch_enable),", 1)
        else:
            marker = "    cpu5_cache_adapter #("
            assert source.count(marker) == 1
            source = source.replace(marker, GATE + marker, 1)
            before, memory = source.split(") u_memory(", 1)
            memory = memory.replace(".cpu_imem_req_valid(cpu_imem_req_valid)", ".cpu_imem_req_valid(cache_imem_req_valid)", 1)
            memory = memory.replace(".cpu_imem_req_ready(cpu_imem_req_ready)", ".cpu_imem_req_ready(cache_imem_req_ready)", 1)
            source = before + ") u_memory(" + memory
        result.append(source)
    return HEADER + "\n".join(result) + "\n`endif\n"
if __name__ == "__main__":
    import sys
    path = ROOT / "tb/cpu5_coremark_harness.v"
    if "--generate" in sys.argv:
        path.write_text(transformed(), encoding="utf-8", newline="\n")
    assert path.read_text(encoding="utf-8") == transformed(), "Harness differs from approved wrapper-only transform"
    print("CPU5 CoreMark test harness derivation PASS (3 wrappers, no product RTL mutation)")

