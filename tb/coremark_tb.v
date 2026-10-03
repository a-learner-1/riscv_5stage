`timescale 1ns/1ps
`ifndef COREMARK_CONFIG
`define COREMARK_CONFIG "programs/coremark_smoke_config.vh"
`endif
`include `COREMARK_CONFIG

// Execute the unmodified CoreMark algorithms on the real CPU and local timer.
// Profile metadata comes from the same ELF build that produced ROM/RAM images.
module coremark_tb;
    reg clk = 0, rst_n = 0, test_pass = 0;
    wire [31:0] pc_x, instr_x, wb_pc;
    wire retire_valid, trap_valid, imem_fault, dmem_fault;
    wire [63:0] cycle_count, instret_count;
    localparam integer TOHOST_WORD = 4095;
    localparam integer START_WORD = (`COREMARK_START_TICKS - 32'h10000) / 4;
    localparam integer STOP_WORD = (`COREMARK_STOP_TICKS - 32'h10000) / 4;
    localparam integer TOTAL_WORD = (`COREMARK_TOTAL_TICKS - 32'h10000) / 4;
    localparam integer FAILED_WORD = (`COREMARK_FAILED - 32'h10000) / 4;
    localparam integer ITER_WORD = (`COREMARK_ACTUAL_ITERATIONS - 32'h10000) / 4;
    integer watchdog_cycles = 0, timer_phase = 0, snapshots = 0;
    reg [31:0] high_first = 0;
    reg [63:0] low_sample = 0, observed_start = 0, observed_stop = 0;
    reg [63:0] start_retired = 0, stop_retired = 0;
    reg [63:0] stored_start, stored_stop, stored_total, cpi_milli;
    string console = "";
    string expected;

    cpu_top #(
        .PROGRAM_FILE(`COREMARK_ROM_FILE), .DATA_FILE(`COREMARK_RAM_FILE),
        .IMEM_WORDS(8192), .DMEM_WORDS(4096), .DMEM_BASE_ADDR(32'h10000),
        .UART_CLOCK_HZ(`COREMARK_CLOCK_HZ), .UART_BAUD(`COREMARK_UART_BAUD),
        .ENABLE_TRAPS(1), .ENABLE_TIMER_IRQ(1), .SIM_CONSOLE_ECHO(0)
    ) dut (
        .clk(clk), .rst_n(rst_n), .uart_rx(1'b1), .uart_tx(),
        .pc_x(pc_x), .instr_x(instr_x), .valid_x(), .wb_pc(wb_pc),
        .wb_rd(), .wb_data(), .wb_we(), .retire_valid(retire_valid),
        .cycle_count(cycle_count), .instret_count(instret_count),
        .gpio_in(8'd0), .gpio_out(), .gpio_oe(),
        .imem_req_valid(), .imem_req_ready(1'b0), .imem_req_addr(),
        .imem_rsp_valid(1'b0), .imem_rsp_ready(), .imem_rsp_rdata(32'd0),
        .imem_rsp_error(1'b0), .imem_fault(imem_fault), .imem_fault_pc(),
        .dmem_req_valid(), .dmem_req_ready(1'b0), .dmem_req_write(),
        .dmem_req_addr(), .dmem_req_size(), .dmem_req_wdata(), .dmem_req_wstrb(),
        .dmem_rsp_valid(1'b0), .dmem_rsp_ready(), .dmem_rsp_rdata(32'd0),
        .dmem_rsp_error(1'b0), .dmem_fault(dmem_fault),
        .trap_valid(trap_valid), .trap_pc(), .trap_cause(), .trap_tval()
    );
    always #(500000000.0 / `COREMARK_CLOCK_HZ) clk = ~clk;

    function automatic integer contains(input string whole, input string part);
        integer i;
        begin
            contains = 0;
            for (i = 0; i + part.len() <= whole.len(); i = i + 1)
                if (whole.substr(i, i + part.len() - 1) == part) contains = 1;
        end
    endfunction
    task require_text(input string part);
        begin
            if (!contains(console, part))
                $fatal(1, "CoreMark %s missing UART text: %s", `COREMARK_PROFILE, part);
        end
    endtask

    // Capture pre-edge MMIO values at acceptance, independent of exported RAM.
    // A successful high/low/high sequence returns the exact low-read timestamp.
    always @(posedge clk) if (rst_n) begin
        if (dut.csr_mie !== 0 || dut.csr_mstatus[3] !== 0)
            $fatal(1, "CoreMark unexpectedly enabled machine interrupts");
        if (dut.mem_req_fire && !dut.mem_req_write && dut.timer_read_hit_x) begin
            if (timer_phase == 0) begin
                if (dut.mem_addr_x !== 32'h20000044)
                    $fatal(1, "CoreMark timer snapshot did not begin with high word");
                high_first = dut.timer_mtime[63:32];
                timer_phase = 1;
            end else if (timer_phase == 1) begin
                if (dut.mem_addr_x !== 32'h20000040)
                    $fatal(1, "CoreMark timer snapshot did not read low word second");
                low_sample = dut.timer_mtime;
                timer_phase = 2;
            end else begin
                if (dut.mem_addr_x !== 32'h20000044)
                    $fatal(1, "CoreMark timer snapshot did not verify high word");
                if (high_first == dut.timer_mtime[63:32]) begin
                    if (snapshots == 0) begin
                        observed_start = low_sample;
                        start_retired = instret_count;
                    end else if (snapshots == 1) begin
                        observed_stop = low_sample;
                        stop_retired = instret_count;
                    end else $fatal(1, "Short CoreMark performed unexpected calibration timing");
                    snapshots = snapshots + 1;
                end
                timer_phase = 0;
            end
        end
        #1;
        if (dut.mmio_putchar_valid)
            console = {console, string'(dut.mmio_putchar_data)};
        if (trap_valid || imem_fault || dmem_fault)
            $fatal(1, "CoreMark CPU exception/fault pc=%h", pc_x);
    end

    initial begin
        // Full auto-calibrating board profiles deliberately do not run here.
        if (`COREMARK_ITERATIONS != 1)
            $fatal(1, "HDL accepts only short ITERATIONS=1 CoreMark fixtures");
        repeat (3) @(negedge clk);
        rst_n = 1;
        while (dut.u_data_mem.mem[TOHOST_WORD] !== 1 &&
               dut.u_data_mem.mem[TOHOST_WORD] !== 2) begin
            @(posedge clk); #2;
            watchdog_cycles = watchdog_cycles + 1;
            if (watchdog_cycles > 12000000)
                $fatal(1, "CoreMark %s timeout pc=%h instr=%h", `COREMARK_PROFILE, pc_x, instr_x);
        end
        @(negedge clk);
        if (snapshots != 2 || timer_phase != 0)
            $fatal(1, "CoreMark missing complete start/stop 64-bit snapshots");
        stored_start = {dut.u_data_mem.mem[START_WORD+1], dut.u_data_mem.mem[START_WORD]};
        stored_stop = {dut.u_data_mem.mem[STOP_WORD+1], dut.u_data_mem.mem[STOP_WORD]};
        stored_total = {dut.u_data_mem.mem[TOTAL_WORD+1], dut.u_data_mem.mem[TOTAL_WORD]};
        if (stored_start !== observed_start || stored_stop !== observed_stop ||
            stored_total !== observed_stop - observed_start)
            $fatal(1, "CoreMark RAM 64-bit ticks disagree with actual mtime read transactions");
        if (observed_stop <= observed_start || stop_retired <= start_retired ||
            stop_retired - start_retired >= instret_count || stored_total >= cycle_count)
            $fatal(1, "CoreMark timer did not isolate the algorithm interval");
        if (dut.u_data_mem.mem[ITER_WORD] !== 1)
            $fatal(1, "CoreMark reported wrong actual iteration count");
        if (`COREMARK_FORMAL) begin
            if (dut.u_data_mem.mem[TOHOST_WORD] !== 2 || dut.u_data_mem.mem[FAILED_WORD] == 0)
                $fatal(1, "Short formal CoreMark run was accepted");
            require_text("ERROR! Must execute for at least 10 secs");
            require_text("COREMARK RESULT: FORMAL FAIL");
        end else begin
            if (dut.u_data_mem.mem[TOHOST_WORD] !== 1 || dut.u_data_mem.mem[FAILED_WORD] !== 0)
                $fatal(1, "CoreMark short algorithm/CRC validation failed");
            require_text("COREMARK RESULT: SMOKE PASS");
        end
        expected = $sformatf("COREMARK raw_ticks=%0d", stored_total);
        require_text(expected);
        expected = $sformatf("COREMARK cpu_hz=%0d", `COREMARK_CLOCK_HZ);
        require_text(expected);
        expected = $sformatf("COREMARK uart_baud=%0d", `COREMARK_UART_BAUD);
        require_text(expected);
        expected = $sformatf("seedcrc          : 0x%04x", `COREMARK_SEED_CRC);
        require_text(expected);
        expected = $sformatf("[0]crclist       : 0x%04x", `COREMARK_LIST_CRC);
        require_text(expected);
        expected = $sformatf("[0]crcmatrix     : 0x%04x", `COREMARK_MATRIX_CRC);
        require_text(expected);
        expected = $sformatf("[0]crcstate      : 0x%04x", `COREMARK_STATE_CRC);
        require_text(expected);
        if (contains(console, "ERROR! list") || contains(console, "ERROR! matrix") ||
            contains(console, "ERROR! state"))
            $fatal(1, "CoreMark CRC errors in UART transcript");
        $display("%s", console);
        cpi_milli = (cycle_count * 64'd1000) / instret_count;
        $display("PASS: CoreMark %s real C seeds/CRCs, 64-bit mtime snapshots and algorithm-only interval", `COREMARK_PROFILE);
        $display("COREMARK TEST: algorithm_ticks=%0d algorithm_retired=%0d total_cycles=%0d total_retired=%0d CPI=%0d.%03d",
            stored_total, stop_retired-start_retired, cycle_count, instret_count,
            cpi_milli / 1000, cpi_milli % 1000);
        test_pass = 1;
        $stop;
    end
endmodule
