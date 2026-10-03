`timescale 1ns/1ps
// Bounded board wiring/reset check. The formal auto-calibrating firmware is
// loaded, but this test stops before running the benchmark or reporting scores.
module coremark_prepare_tb;
    reg clk = 0, key1_n = 0, test_pass = 0;
    wire tx;
    wire [7:0] led;
    integer released_clock_edges = 0;
    reg offset_known = 0;
    reg [63:0] counter_start_offset = 0;
    always #10 clk = ~clk;
    coremark_board_top #(.RESET_HOLD_CYCLES(4)) dut (
        .clk_50m(clk), .key1_n(key1_n), .keys_n(7'h7f),
        .led(led), .uart_tx(tx), .uart_rx(1'b1)
    );
    // mtime begins with reset release; cycle_count begins at the first valid
    // instruction. Count clock edges independently instead of assuming that
    // those two architecturally different counters share their initial value.
    always @(posedge clk) begin
        if (dut.cpu_rst_n) released_clock_edges = released_clock_edges + 1;
        else released_clock_edges = 0;
    end
    always @(negedge clk) if (dut.cpu_rst_n && dut.u_cpu.cycle_count != 0) begin
        if (!offset_known) begin
            counter_start_offset = dut.u_cpu.timer_mtime - dut.u_cpu.cycle_count;
            offset_known = 1;
        end else if (dut.u_cpu.timer_mtime - dut.u_cpu.cycle_count !== counter_start_offset)
            $fatal(1, "CoreMark board counter increment mismatch: mtime=%0d cycles=%0d startup_offset=%0d edges=%0d",
                   dut.u_cpu.timer_mtime, dut.u_cpu.cycle_count,
                   counter_start_offset, released_clock_edges);
    end
    initial begin
        if (dut.u_cpu.IMEM_WORDS != 8192 || dut.u_cpu.DMEM_WORDS != 4096 ||
            dut.u_cpu.EXTERNAL_IMEM != 0 || dut.u_cpu.EXTERNAL_DMEM != 0 ||
            dut.u_cpu.DMEM_BASE_ADDR != 32'h10000 ||
            dut.u_cpu.UART_CLOCK_HZ != 50000000 || dut.u_cpu.UART_BAUD != 115200 ||
            dut.u_cpu.ENABLE_TRAPS != 1 || dut.u_cpu.ENABLE_TIMER_IRQ != 1)
            $fatal(1, "CoreMark board memory/clock/timer configuration mismatch");
        repeat (3) @(negedge clk);
        if (dut.cpu_rst_n !== 0 || led !== 0 || tx !== 1)
            $fatal(1, "CoreMark board reset outputs mismatch");
        key1_n = 1;
        wait(dut.cpu_rst_n);
        repeat (120) @(negedge clk);
        if (dut.u_cpu.timer_mtime !== released_clock_edges ||
            released_clock_edges == 0 || !offset_known ||
            dut.u_cpu.csr_mie !== 0 || dut.u_cpu.csr_mstatus[3] !== 0 ||
            dut.u_cpu.trap_valid !== 0 || dut.u_cpu.imem_fault !== 0 || dut.u_cpu.dmem_fault !== 0)
            $fatal(1, "CoreMark board startup failed: mtime=%0d cycles=%0d edges=%0d startup_offset=%0d offset_known=%0d mie=%h mstatus=%h trap=%b imem_fault=%b dmem_fault=%b",
                   dut.u_cpu.timer_mtime, dut.u_cpu.cycle_count, released_clock_edges,
                   counter_start_offset, offset_known, dut.u_cpu.csr_mie,
                   dut.u_cpu.csr_mstatus, dut.u_cpu.trap_valid,
                   dut.u_cpu.imem_fault, dut.u_cpu.dmem_fault);
        $display("CoreMark board startup observed: mtime=%0d cycles=%0d edges=%0d startup_offset=%0d mie=%h mstatus=%h",
                 dut.u_cpu.timer_mtime, dut.u_cpu.cycle_count, released_clock_edges,
                 counter_start_offset, dut.u_cpu.csr_mie, dut.u_cpu.csr_mstatus);
        key1_n = 0;
        @(negedge clk);
        if (dut.cpu_rst_n !== 0 || dut.u_cpu.timer_mtime !== 0 || led !== 0)
            $fatal(1, "CoreMark board KEY1 reset failed: rst_n=%b mtime=%0d led=%h",
                   dut.cpu_rst_n, dut.u_cpu.timer_mtime, led);
        test_pass = 1;
        $display("PASS: CoreMark board internal 32KiB ROM/16KiB RAM, 50MHz/115200, masked timer and KEY1 reset; bounded startup only");
        $stop;
    end
    initial begin #10000; $fatal(1, "CoreMark board startup timeout"); end
endmodule
