`timescale 1ns/1ps
`include "programs/machine_irq_board_symbols.vh"
// Future source-only acceptance. Use the actual 50 MHz / 115200 UART and
// hardware instructions; simulation RAM changes only the heartbeat period.
// No compilation, simulation, timing or physical-board result is implied.
module machine_irq_board_tb;
    wire [2:0] done;
    reg test_pass = 0;
    machine_irq_board_case normal(done[0]);
    machine_irq_board_case #(.RESET_HANDLER(1)) reset_handler(done[1]);
    machine_irq_board_case #(.FIRST_FAIL(1)) software_fail(done[2]);
    initial begin
        wait (&done); test_pass = 1;
        $display("MACHINE IRQ BOARD TESTS PASS: physical UART, eight ordered IRQ/MRET, x1..x31, 2048 unreplayed foreground stores, masked pending, heartbeat, KEY1 handler cancellation/restart and FAIL recovery");
        $stop;
    end
    initial begin #30000000; $fatal(1, "Machine IRQ board timeout done=%b", done); end
endmodule

module machine_irq_board_uart_checker #(parameter integer FIRST_FAIL = 0)(
    input wire tx, rst_n, restart_allowed, output reg [31:0] boots = 0
);
    localparam integer BIT_NS = 434 * 20;
    localparam [18*8-1:0] PASS_MESSAGE = "MACHINE IRQ PASS\015\012";
    localparam [27*8-1:0] FAIL_MESSAGE = "MACHINE IRQ FAIL 00000001\015\012";
    integer bytes = 0, bit_index, length;
    reg [7:0] value, expected;
    initial forever begin
        @(negedge tx);
        if (!rst_n || boots >= 2 || (boots == 1 && !restart_allowed))
            $fatal(1, "Unexpected machine IRQ UART frame");
        length = (FIRST_FAIL && boots == 0) ? 27 : 18;
        expected = (FIRST_FAIL && boots == 0) ?
            FAIL_MESSAGE[(26-bytes)*8+:8] : PASS_MESSAGE[(17-bytes)*8+:8];
        #(BIT_NS/2);
        if (tx !== 0) $fatal(1, "Machine IRQ UART start bit");
        for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
            #(BIT_NS);
            if (tx !== 0 && tx !== 1) $fatal(1, "Unknown machine IRQ UART data bit");
            value[bit_index] = tx;
        end
        #(BIT_NS);
        if (tx !== 1 || value !== expected)
            $fatal(1, "Machine IRQ UART %m boot=%0d byte=%0d got=%h expected=%h", boots, bytes, value, expected);
        bytes = bytes + 1;
        if (bytes == length) begin
            bytes = 0; boots = boots + 1;
            $display("MACHINE IRQ UART %m boot=%0d bytes=%0d", boots, length);
        end
    end
endmodule

module machine_irq_board_case #(
    parameter integer RESET_HANDLER = 0, FIRST_FAIL = 0
)(output reg done = 0);
    reg clk = 0, key1_n = 1, restart_allowed = 0, in_isr = 0, in_work = 0;
    wire tx;
    wire [7:0] led;
    wire [31:0] boots;
    integer traps = 0, mrets = 0, work_writes = 0, checksum_writes = 0;
    integer requests = 0, responses = 0, zero_tohost_writes = 0, terminal_writes = 0;
    integer i, j, slot, wait_cycles;
    reg old_phase, got_aw = 0, got_w = 0;
    reg [31:0] pcs [0:7], causes [0:7], saved_regs [0:31];
    reg [31:0] buffered_addr, buffered_data;
    reg [3:0] buffered_strobe;
    reg [31:0] rolling_checksum = 32'h13579bdf;
    reg [31:0] terminal_value = 0;
    machine_irq_board_top #(
        .DATA_FILE("programs/machine_irq_board_sim_data.hex"), .RESET_HOLD_CYCLES(16)
    ) dut (
        .clk_50m(clk), .key1_n(key1_n), .keys_n(7'h7f),
        .led(led), .uart_tx(tx), .uart_rx(1'b1)
    );
    machine_irq_board_uart_checker #(.FIRST_FAIL(FIRST_FAIL)) serial(
        tx, dut.cpu_rst_n, restart_allowed, boots
    );
    always #10 clk = ~clk;

    function [31:0] expected_cause(input integer index);
        case (index)
            0, 3, 5: expected_cause = 32'h8000000b;
            1, 4, 6: expected_cause = 32'h80000003;
            2, 7: expected_cause = 32'h80000007;
            default: expected_cause = 0;
        endcase
    endfunction
    function [31:0] ram_word(input [31:0] address);
        ram_word = dut.u_ram.u_data_mem.mem[(address-32'h10000)/4];
    endfunction

    always @(posedge clk) begin
        if (!dut.cpu_rst_n) begin
            traps = 0; mrets = 0; work_writes = 0; checksum_writes = 0;
            requests = 0; responses = 0; zero_tohost_writes = 0; terminal_writes = 0;
            terminal_value = 0; in_isr = 0; in_work = 0; got_aw = 0; got_w = 0;
            rolling_checksum = 32'h13579bdf;
        end else if (!done) begin
            if (dut.imem_fault || dut.dmem_fault) $fatal(1, "Machine IRQ board unexpected access halt");
            if (dut.u_soc.u_cpu.u_if_stage.u_instr_mem.en ||
                dut.u_soc.u_cpu.u_data_mem.re || dut.u_soc.u_cpu.u_data_mem.we)
                $fatal(1, "Machine IRQ board used inactive CPU-local ROM/RAM");
            if (dut.u_soc.dmem_req_valid && dut.u_soc.dmem_req_ready) requests = requests + 1;
            if (dut.u_soc.dmem_rsp_valid && dut.u_soc.dmem_rsp_ready) responses = responses + 1;
            if (dut.axi_awvalid && dut.axi_awready) begin
                if (got_aw) $fatal(1, "Machine IRQ board duplicate AW");
                got_aw = 1; buffered_addr = dut.axi_awaddr;
            end
            if (dut.axi_wvalid && dut.axi_wready) begin
                if (got_w) $fatal(1, "Machine IRQ board duplicate W");
                got_w = 1; buffered_data = dut.axi_wdata; buffered_strobe = dut.axi_wstrb;
            end
            if (dut.axi_bvalid && dut.axi_bready) begin
                if (!got_aw || !got_w || dut.axi_bresp !== 0)
                    $fatal(1, "Machine IRQ board invalid write response");
                if (in_work && buffered_addr == `MACHINE_IRQ_CHECKSUM) begin
                    rolling_checksum = (rolling_checksum << 5) ^ (rolling_checksum >> 2) ^ checksum_writes;
                    if (buffered_strobe !== 4'hf || buffered_data !== rolling_checksum)
                        $fatal(1, "Machine IRQ board lost/replayed checksum step %0d", checksum_writes);
                    checksum_writes = checksum_writes + 1;
                end
                if (in_work && buffered_addr == `MACHINE_IRQ_WORK) begin
                    work_writes = work_writes + 1;
                    if (buffered_strobe !== 4'hf || buffered_data !== work_writes)
                        $fatal(1, "Machine IRQ board lost/replayed foreground update");
                end
                if (buffered_addr == `MACHINE_IRQ_TOHOST) begin
                    if (buffered_strobe !== 4'hf) $fatal(1, "Machine IRQ partial tohost write");
                    if (buffered_data == 0) begin
                        zero_tohost_writes = zero_tohost_writes + 1;
                        if (zero_tohost_writes != 1 || terminal_writes != 0)
                            $fatal(1, "Machine IRQ main failed to clear named tohost exactly once per boot");
                    end else begin
                        terminal_writes = terminal_writes + 1; terminal_value = buffered_data;
                        if (zero_tohost_writes != 1 || terminal_writes != 1 ||
                            (buffered_data != 1 && buffered_data != 2))
                            $fatal(1, "Machine IRQ terminal write absent/replayed/invalid");
                    end
                end
                got_aw = 0; got_w = 0;
            end
            #1;
            if (dut.trap_valid) begin
                if (in_isr || traps >= 8 || dut.trap_cause !== expected_cause(traps) ||
                    dut.trap_tval !== 0 || dut.trap_pc[1:0] != 0 ||
                    dut.u_soc.u_cpu.csr_mstatus !== 32'h1880 || dut.u_soc.u_cpu.csr_mie !== 32'h888)
                    $fatal(1, "Machine IRQ board wrong/nested interrupt slot=%0d PC=%h cause=%h", traps, dut.trap_pc, dut.trap_cause);
                if (requests != responses || dut.u_soc.u_cpu.mem_active || got_aw || got_w)
                    $fatal(1, "Machine IRQ board IRQ interrupted an outstanding memory transaction");
                if (zero_tohost_writes != 1 || terminal_writes != 0)
                    $fatal(1, "Machine IRQ started before main cleared tohost or after completion");
                if ((dut.trap_cause == 32'h8000000b &&
                     (!dut.irq_external || !dut.u_soc.u_cpu.external_irq_sync)) ||
                    (dut.trap_cause == 32'h80000003 && !dut.u_soc.u_cpu.software_msip) ||
                    (dut.trap_cause == 32'h80000007 && !dut.u_soc.u_cpu.timer_mtip))
                    $fatal(1, "Machine IRQ board source auto-cleared before handler acknowledgement");
                if (traps == 2 && (!in_work || dut.trap_pc < `MACHINE_IRQ_WORK_BEGIN ||
                    dut.trap_pc >= `MACHINE_IRQ_WORK_END || work_writes == 0 || work_writes >= 2048))
                    $fatal(1, "Machine IRQ timer did not interrupt ordinary foreground work");
                if (traps == 3 && ram_word(`MACHINE_IRQ_MASK_CHECKS) !== 1 ||
                    traps == 4 && ram_word(`MACHINE_IRQ_MASK_CHECKS) !== 2 ||
                    traps >= 5 && ram_word(`MACHINE_IRQ_MASK_CHECKS) !== 3)
                    $fatal(1, "Machine IRQ accepted pending source before its mask check completed");
                if (traps == 5 && (dut.u_soc.u_cpu.csr_mip_value & 32'h888) !== 32'h888)
                    $fatal(1, "Machine IRQ three-source priority did not start with all sources pending");
                if (dut.u_soc.retire_valid && dut.u_soc.wb_pc == dut.trap_pc)
                    $fatal(1, "Machine IRQ interrupted instruction retired at entry");
                pcs[traps] = dut.trap_pc; causes[traps] = dut.trap_cause;
                for (j = 1; j < 32; j = j + 1) saved_regs[j] = dut.u_soc.u_cpu.u_regfile.regs[j];
                traps = traps + 1; in_isr = 1;
            end
            if (dut.u_soc.retire_valid) begin
                if (dut.u_soc.wb_pc == `MACHINE_IRQ_MRET) begin
                    if (!in_isr || mrets >= traps || dut.u_soc.u_cpu.csr_mepc !== pcs[traps-1] ||
                        dut.u_soc.u_cpu.csr_mstatus !== 32'h1888)
                        $fatal(1, "Machine IRQ MRET did not resume same PC/restore MIE");
                    for (j = 1; j < 32; j = j + 1)
                        if (dut.u_soc.u_cpu.u_regfile.regs[j] !== saved_regs[j])
                            $fatal(1, "Machine IRQ handler corrupted x%0d", j);
                    if ((causes[traps-1] == 32'h8000000b && dut.u_soc.u_cpu.external_irq_sync) ||
                        (causes[traps-1] == 32'h80000003 && dut.u_soc.u_cpu.software_msip) ||
                        (causes[traps-1] == 32'h80000007 && dut.u_soc.u_cpu.timer_mtip))
                        $fatal(1, "Machine IRQ handler returned while its source was still pending");
                    mrets = mrets + 1; in_isr = 0;
                end
                if (dut.u_soc.wb_pc == `MACHINE_IRQ_WORK_BEGIN) in_work = 1;
                if (dut.u_soc.wb_pc == `MACHINE_IRQ_WORK_END) in_work = 0;
            end
        end
    end

    task check_completed;
        begin
            wait (terminal_writes == 1);
            wait (dut.u_soc.u_cpu.uart_busy === 0);
            wait_cycles = 0;
            while (led[1] !== 1) begin
                @(posedge clk); #2; wait_cycles = wait_cycles + 1;
                if (wait_cycles > 1000) $fatal(1, "Machine IRQ PASS LED timeout");
            end
            if (terminal_value !== 1 || ram_word(`MACHINE_IRQ_TOHOST) !== 1 ||
                zero_tohost_writes != 1 || traps != 8 || mrets != 8 || in_isr || in_work ||
                work_writes != 2048 || checksum_writes != 2048 ||
                rolling_checksum !== `MACHINE_IRQ_EXPECT_CHECKSUM || led[7:1] !== 7'b0000001 ||
                dut.gpio_oe !== 7 || ram_word(`MACHINE_IRQ_DONE) !== 1 ||
                ram_word(`MACHINE_IRQ_FAILED) !== 0 || ram_word(`MACHINE_IRQ_EXTERNAL_COUNT) !== 3 ||
                ram_word(`MACHINE_IRQ_SOFTWARE_COUNT) !== 3 || ram_word(`MACHINE_IRQ_TIMER_COUNT) !== 2 ||
                ram_word(`MACHINE_IRQ_ORDER_COUNT) !== 8 ||
                ram_word(`MACHINE_IRQ_CHECKSUM) !== `MACHINE_IRQ_EXPECT_CHECKSUM ||
                ram_word(`MACHINE_IRQ_WORK) !== 2048 || ram_word(`MACHINE_IRQ_MASK_CHECKS) !== 3 ||
                ram_word(`MACHINE_IRQ_GUARD) !== 32'h12345678 || ram_word(`MACHINE_IRQ_BLINK_CYCLES) !== 2000 ||
                dut.u_irq_source.pending || dut.u_irq_source.set_count !== 3 || dut.u_irq_source.clear_count !== 3 ||
                dut.u_soc.u_cpu.software_msip || dut.u_soc.u_cpu.csr_mip_value !== 0 ||
                dut.u_soc.u_cpu.csr_mie !== 0 || dut.u_soc.u_cpu.csr_mstatus !== 32'h1880)
                $fatal(1, "Machine IRQ final software/register/LED state mismatch %m IRQ/MRET=%0d/%0d work/checksum=%0d/%0d", traps, mrets, work_writes, checksum_writes);
            for (slot = 0; slot < 8; slot = slot + 1) begin
                if (ram_word(`MACHINE_IRQ_ORDER + slot*4) !== (expected_cause(slot) & 32'h7fffffff) ||
                    ram_word(`MACHINE_IRQ_LOG + slot*16) !== expected_cause(slot) ||
                    ram_word(`MACHINE_IRQ_LOG + slot*16 + 4) !== pcs[slot] ||
                    ram_word(`MACHINE_IRQ_LOG + slot*16 + 8) !== 0 ||
                    ram_word(`MACHINE_IRQ_LOG + slot*16 + 12) !== 32'h1880)
                    $fatal(1, "Machine IRQ software order/log mismatch slot=%0d", slot);
            end
        end
    endtask
    task check_reset;
        begin
            #2;
            if (dut.cpu_rst_n !== 0 || led !== 0 || tx !== 1 || dut.trap_valid || dut.imem_fault || dut.dmem_fault ||
                dut.u_soc.u_cpu.mem_active || dut.u_soc.u_cpu.csr_mstatus !== 32'h1800 ||
                dut.u_soc.u_cpu.csr_mtvec !== 0 || dut.u_soc.u_cpu.csr_mie !== 0 ||
                dut.u_soc.u_cpu.external_irq_meta || dut.u_soc.u_cpu.external_irq_sync || dut.u_soc.u_cpu.software_msip ||
                dut.u_soc.u_cpu.timer_mtip || dut.u_soc.u_cpu.timer_mtime !== 0 ||
                dut.u_soc.u_cpu.timer_mtimecmp !== 64'hffffffffffffffff ||
                dut.u_irq_source.pending || dut.u_irq_source.set_count !== 0 || dut.u_irq_source.clear_count !== 0 ||
                dut.axi_awvalid || dut.axi_wvalid || dut.axi_arvalid || dut.axi_bvalid || dut.axi_rvalid ||
                ram_word(`MACHINE_IRQ_GUARD) !== 32'h12345678 || ram_word(`MACHINE_IRQ_BLINK_CYCLES) !== 2000)
                $fatal(1, "Machine IRQ shared reset/CSR/pending/protocol defaults/RAM retention");
            // RAM keeps its terminal word during KEY1. The successful zero
            // write from main on the next boot, rather than BSS, clears it.
            if (!RESET_HANDLER && ram_word(`MACHINE_IRQ_TOHOST) !== terminal_value)
                $fatal(1, "Machine IRQ reset unexpectedly erased retained tohost");
        end
    endtask

    initial begin
        #2;
        if (FIRST_FAIL) dut.u_ram.u_data_mem.mem[(`MACHINE_IRQ_GUARD-32'h10000)/4] = 0;
        if (dut.cpu_rst_n !== 0 || led !== 0 || tx !== 1) $fatal(1, "Machine IRQ power-up defaults");
        repeat (15) @(posedge clk); #2;
        if (dut.cpu_rst_n !== 0) $fatal(1, "Machine IRQ power-up released too early");
        // Seed after reset releases, before the first active CPU edge; seeding
        // during reset would be erased by the register-file reset clock.
        wait (dut.cpu_rst_n === 1'b1); #2;
        for (i = 1; i < 32; i = i + 1) dut.u_soc.u_cpu.u_regfile.regs[i] = 32'h51a70000 + i*32'h01010101;
        if (RESET_HANDLER) begin
            wait (dut.trap_valid);
            wait (dut.u_soc.valid_x && dut.u_soc.pc_x == `MACHINE_IRQ_ENTRY + 12);
            @(negedge clk);
            if (traps != 1 || mrets != 0 || boots !== 0) $fatal(1, "KEY1 did not cancel first machine IRQ handler");
            key1_n = 0; check_reset;
            repeat (4) @(negedge clk); key1_n = 1;
        end
        wait (boots == 1);
        if (FIRST_FAIL) begin
            wait (terminal_writes == 1);
            wait (dut.u_soc.u_cpu.uart_busy === 0); repeat (100) @(posedge clk); #2;
            if (terminal_value !== 2 || ram_word(`MACHINE_IRQ_TOHOST) !== 2 || zero_tohost_writes != 1 ||
                led !== 4 || dut.gpio_oe !== 7 || traps != 0 || mrets != 0 ||
                ram_word(`MACHINE_IRQ_DONE) !== 2 || ram_word(`MACHINE_IRQ_FAILED) !== 1 ||
                dut.u_soc.u_cpu.csr_mie !== 0 || dut.u_soc.u_cpu.csr_mstatus !== 32'h1800)
                $fatal(1, "Machine IRQ real guard failure did not halt with UART/FAIL LED/tohost=2");
            dut.u_ram.u_data_mem.mem[(`MACHINE_IRQ_GUARD-32'h10000)/4] = 32'h12345678;
        end else begin
            check_completed;
            old_phase = led[0]; wait (led[0] !== old_phase); wait (led[0] === old_phase);
            if (led[7:1] !== 7'b0000001) $fatal(1, "Machine IRQ heartbeat changed status LEDs");
        end
        restart_allowed = 1; @(negedge clk); key1_n = 0; check_reset;
        repeat (4) @(negedge clk); key1_n = 1;
        repeat (15) @(posedge clk); #2;
        if (dut.cpu_rst_n !== 0) $fatal(1, "Machine IRQ KEY1 hold released too early");
        wait (boots == 2); check_completed;
        repeat (100) @(posedge clk);
        $display("MACHINE IRQ BOARD CASE PASS %m reset_handler=%0d first_fail=%0d", RESET_HANDLER, FIRST_FAIL);
        done = 1;
    end
endmodule
