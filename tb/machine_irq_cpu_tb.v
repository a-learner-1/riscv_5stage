`timescale 1ns/1ps
// Prepared directed instruction tests; not compiled or simulated this step.
// ROM installation during reset is the only hierarchical state modification.
module machine_irq_cpu_tb;
    reg test_pass = 0;
    wire [10:0] done;
    machine_irq_cpu_case #(.KIND(0), .SOFT_ENABLE(0), .TIMER_ENABLE(0)) external_masks(done[0]);
    machine_irq_cpu_case #(.KIND(1), .EXT_ENABLE(0), .TIMER_ENABLE(0)) software_masks(done[1]);
    machine_irq_cpu_case #(.KIND(2)) priority_off(done[2]);
    machine_irq_cpu_case #(.KIND(3), .PRED(1)) priority_on(done[3]);
    machine_irq_cpu_case #(.KIND(4), .SOFT_ENABLE(0), .TIMER_ENABLE(0)) level_reentry(done[4]);
    machine_irq_cpu_case #(.KIND(5), .SOFT_ENABLE(0), .TIMER_ENABLE(0)) request_wait(done[5]);
    machine_irq_cpu_case #(.KIND(6), .SOFT_ENABLE(0), .TIMER_ENABLE(0), .PRED(1)) response_wait(done[6]);
    machine_irq_cpu_case #(.KIND(7), .SOFT_ENABLE(0), .TIMER_ENABLE(0)) fault_priority(done[7]);
    machine_irq_cpu_case #(.KIND(8), .EXT_ENABLE(0), .SOFT_ENABLE(0), .TIMER_ENABLE(0)) default_off(done[8]);
    machine_irq_cpu_case #(.KIND(9), .EXT_ENABLE(0), .TIMER_ENABLE(0)) msip_access_errors(done[9]);
    machine_irq_cpu_case #(.KIND(10), .EXT_ENABLE(0), .SOFT_ENABLE(0)) timer_mask(done[10]);
    initial begin
        wait (&done);
        test_pass = 1;
        $display("MACHINE IRQ CPU TESTS PASS: source masks, ignored mip writes, MSIP lane/size rules, level reentry, three-source priority, precise MRET, memory drain/fault precedence and BTB off/on");
        $stop;
    end
    initial begin #1000000; $fatal(1, "Machine IRQ CPU timeout done=%b", done); end
endmodule

module machine_irq_cpu_case #(
    parameter integer KIND = 0, EXT_ENABLE = 1, SOFT_ENABLE = 1,
    parameter integer TIMER_ENABLE = 1, PRED = 0
)(output reg done = 0);
    reg clk = 0, rst_n = 0, irq_external = 0;
    always #5 clk = ~clk;
    reg [31:0] rom [0:255], memory [0:63];
    reg main_expected [0:127], fault_expected [0:127], write_expected [0:127];
    reg [4:0] expected_rd [0:127];
    reg [31:0] expected_data [0:127], fault_cause [0:127], fault_tval [0:127];
    integer retire_count [0:127];
    wire [31:0] pc_x, instr_x, wb_pc, wb_data, trap_pc, trap_cause, trap_tval;
    wire [4:0] wb_rd;
    wire valid_x, retire_valid, wb_we, trap_valid, imem_fault, dmem_fault;
    wire d_req_valid, d_req_write, d_rsp_ready;
    wire [31:0] d_req_addr, d_req_data;
    wire [1:0] d_req_size;
    wire [3:0] d_req_strobe;
    reg d_rsp_valid = 0, d_rsp_error = 0, memory_active = 0;
    reg [31:0] d_rsp_data = 0, saved_addr = 0, saved_data = 0;
    reg [3:0] saved_strobe = 0;
    reg saved_write = 0, external_armed = 0;
    integer cursor = 0, critical_pc = -1, terminal_pc = 0;
    integer irqs = 0, syncs = 0, mret_commits = 0, mret_retired = 0;
    integer requests = 0, responses = 0, stores = 0, msip_writes = 0;
    integer req_wait = 0, rsp_wait = 0, blocked_requests = 0, response_holds = 0;
    integer i, lane, expected_irqs, expected_syncs;
    reg in_handler = 0, saved_mie = 0;
    reg [31:0] resume_pc = 0;
    reg request_held = 0, response_held = 0;
    reg [70:0] held_descriptor;
    reg [32:0] held_response;
    wire d_req_ready = rst_n && !memory_active && !d_rsp_valid &&
        (KIND != 5 || requests != 0 || req_wait >= 70);

    cpu_top #(
        .PROGRAM_FILE("programs/data_handshake_blank.hex"), .IMEM_WORDS(256),
        .DMEM_WORDS(64), .DMEM_BASE_ADDR(0), .ENABLE_TRAPS(1),
        .ENABLE_EXTERNAL_IRQ(EXT_ENABLE), .ENABLE_SOFTWARE_IRQ(SOFT_ENABLE),
        .ENABLE_TIMER_IRQ(TIMER_ENABLE), .ENABLE_BRANCH_PRED(PRED),
        .EXTERNAL_DMEM(KIND >= 5 && KIND <= 7), .SIM_CONSOLE_ECHO(0),
        .DMEM_REQ_WAIT_CYCLES(2), .DMEM_RSP_WAIT_CYCLES(3)
    ) dut (
        .clk(clk), .rst_n(rst_n), .irq_external(irq_external),
        .uart_rx(1'b1), .uart_tx(), .gpio_in(8'd0), .gpio_out(), .gpio_oe(),
        .pc_x(pc_x), .instr_x(instr_x), .valid_x(valid_x),
        .wb_pc(wb_pc), .wb_rd(wb_rd), .wb_data(wb_data), .wb_we(wb_we),
        .retire_valid(retire_valid), .cycle_count(), .instret_count(),
        .imem_req_valid(), .imem_req_ready(1'b0), .imem_req_addr(),
        .imem_rsp_valid(1'b0), .imem_rsp_ready(), .imem_rsp_rdata(32'd0),
        .imem_rsp_error(1'b0), .imem_fault(imem_fault), .imem_fault_pc(),
        .dmem_req_valid(d_req_valid), .dmem_req_ready(d_req_ready),
        .dmem_req_write(d_req_write), .dmem_req_addr(d_req_addr), .dmem_req_size(d_req_size),
        .dmem_req_wdata(d_req_data), .dmem_req_wstrb(d_req_strobe),
        .dmem_rsp_valid(d_rsp_valid), .dmem_rsp_ready(d_rsp_ready),
        .dmem_rsp_rdata(d_rsp_data), .dmem_rsp_error(d_rsp_error), .dmem_fault(dmem_fault),
        .trap_valid(trap_valid), .trap_pc(trap_pc), .trap_cause(trap_cause), .trap_tval(trap_tval)
    );

    function [31:0] itype(input integer imm, input [4:0] rs1,
                          input [2:0] funct3, input [4:0] rd, input [6:0] op);
        itype = {imm[11:0], rs1, funct3, rd, op};
    endfunction
    function [31:0] csr(input [11:0] addr, input [4:0] rs1,
                        input [2:0] funct3, input [4:0] rd);
        csr = {addr, rs1, funct3, rd, 7'h73};
    endfunction
    function [31:0] sw(input integer imm, input [4:0] rs2, input [4:0] rs1);
        sw = {imm[11:5], rs2, rs1, 3'b010, imm[4:0], 7'h23};
    endfunction
    function [31:0] branch(input integer imm, input [4:0] rs2,
                           input [4:0] rs1, input [2:0] funct3);
        branch = {imm[12], imm[10:5], rs2, rs1, funct3, imm[4:1], imm[11], 7'h63};
    endfunction
    function [31:0] jump(input integer imm);
        jump = {imm[20], imm[10:1], imm[11], imm[19:12], 5'd0, 7'h6f};
    endfunction
    task emit(input [31:0] instruction, input integer rd, input [31:0] value);
        begin
            rom[cursor] = instruction; main_expected[cursor] = 1;
            write_expected[cursor] = rd > 0; expected_rd[cursor] = rd[4:0];
            expected_data[cursor] = value; cursor = cursor + 1;
        end
    endtask
    task addi(input integer rd, input integer rs1, input integer imm, input [31:0] value);
        emit(itype(imm, rs1[4:0], 0, rd[4:0], 7'h13), rd, value);
    endtask
    task csrop(input [11:0] addr, input integer rs1, input [2:0] funct3,
               input integer rd, input [31:0] value);
        emit(csr(addr, rs1[4:0], funct3, rd[4:0]), rd, value);
    endtask
    task fault(input [31:0] instruction, input [31:0] cause, input [31:0] tval);
        begin
            rom[cursor] = instruction; fault_expected[cursor] = 1;
            fault_cause[cursor] = cause; fault_tval[cursor] = tval;
            cursor = cursor + 1;
        end
    endtask
    task enable_global;
        csrop(12'h300, 8, 3'b110, 0, 0);
    endtask
    task handler;
        begin
            rom[128] = csr(12'h342, 0, 2, 20);
            rom[129] = csr(12'h341, 0, 2, 21);
            rom[130] = csr(12'h343, 0, 2, 22);
            rom[131] = csr(12'h300, 0, 2, 23);
            rom[132] = branch(48, 0, 20, 5); // BGE mcause,0 -> synchronous path.
            rom[133] = itype(1, 30, 0, 30, 7'h13);
            rom[134] = itype(15, 20, 7, 24, 7'h13);
            rom[135] = itype(3, 0, 0, 26, 7'h13);
            rom[136] = branch(12, 26, 24, 1);
            rom[137] = sw(80, 0, 1); // Software handler acknowledges its own source.
            rom[138] = jump(20);
            rom[139] = itype(7, 0, 0, 26, 7'h13);
            rom[140] = branch(12, 26, 24, 1);
            rom[141] = sw(72, 2, 1);
            rom[142] = sw(76, 2, 1);
            rom[143] = 32'h30200073;
            rom[144] = itype(1, 29, 0, 29, 7'h13);
            rom[145] = itype(4, 21, 0, 21, 7'h13);
            rom[146] = csr(12'h341, 21, 1, 0);
            rom[147] = jump(-16);
        end
    endtask

    initial begin
        for (i = 0; i < 256; i = i + 1) rom[i] = 32'h13;
        for (i = 0; i < 128; i = i + 1) begin
            main_expected[i] = 0; fault_expected[i] = 0; write_expected[i] = 0;
            expected_rd[i] = 0; expected_data[i] = 0; retire_count[i] = 0;
            fault_cause[i] = 0; fault_tval[i] = 0;
        end
        for (i = 0; i < 64; i = i + 1) memory[i] = 0;
        emit(32'h200000b7, 1, 32'h20000000);
        addi(2, 0, -1, 32'hffffffff); addi(3, 0, 1, 1); addi(4, 0, 512, 512);
        csrop(12'h305, 4, 1, 0, 0); addi(29, 0, 0, 0); addi(30, 0, 0, 0);
        irq_external = KIND == 0 || KIND == 1 || KIND == 2 || KIND == 3 || KIND == 4 || KIND == 8 || KIND == 10;
        expected_irqs = (KIND == 2 || KIND == 3) ? 3 : KIND == 4 ? 2 : (KIND == 8 || KIND == 9) ? 0 : 1;
        expected_syncs = KIND == 0 ? 2 : KIND == 7 ? 1 : KIND == 8 ? 4 : KIND == 9 ? 5 : 0;

        if (KIND == 8) begin
            fault(csr(12'h304, 0, 2, 10), 2, csr(12'h304, 0, 2, 10));
            fault(csr(12'h344, 0, 2, 11), 2, csr(12'h344, 0, 2, 11));
            fault(itype(80, 1, 2, 12, 7'h03), 5, 32'h20000050);
            fault(sw(80, 3, 1), 7, 32'h20000050);
        end else if (KIND == 9) begin
            emit(sw(80, 2, 1), 0, 0);
            emit(itype(80, 1, 2, 10, 7'h03), 10, 1);
            fault(itype(80, 1, 0, 11, 7'h03), 5, 32'h20000050);
            fault(itype(81, 1, 2, 11, 7'h03), 4, 32'h20000051);
            fault({7'd2, 5'd0, 5'd1, 3'b000, 5'd16, 7'h23}, 7, 32'h20000050);
            fault({7'd2, 5'd0, 5'd1, 3'b001, 5'd16, 7'h23}, 7, 32'h20000050);
            fault(sw(81, 0, 1), 6, 32'h20000051);
            emit(itype(80, 1, 2, 12, 7'h03), 12, 1);
            csrop(12'h344, 0, 2, 13, 8);
            emit(sw(80, 0, 1), 0, 0);
            emit(itype(80, 1, 2, 14, 7'h03), 14, 0);
        end else if (KIND == 0 || KIND == 1 || KIND == 4 || KIND == 10) begin
            if (KIND == 1) emit(sw(80, 2, 1), 0, 0);
            if (KIND == 10) begin
                emit(sw(72, 2, 1), 0, 0); emit(sw(76, 0, 1), 0, 0); emit(sw(72, 0, 1), 0, 0);
            end
            csrop(12'h304, 0, 2, 10, 0);
            csrop(12'h344, 0, 2, 11, KIND == 1 ? 8 : KIND == 10 ? 128 : 2048);
            csrop(12'h344, 0, 1, 0, 0); // Pending CSR writes are legal but ignored.
            csrop(12'h344, 2, 2, 0, 0); csrop(12'h344, 2, 3, 0, 0);
            csrop(12'h344, 0, 2, 12, KIND == 1 ? 8 : KIND == 10 ? 128 : 2048);
            enable_global;
            addi(13, 0, 54, 54); // Global enable alone cannot defeat a source mask.
            csrop(12'h300, 8, 7, 0, 0);
            csrop(12'h304, 2, 1, 0, 0);
            csrop(12'h304, 0, 2, 14, KIND == 1 ? 8 : KIND == 10 ? 128 : 2048);
            addi(13, 0, 55, 55); // Source enable alone cannot defeat global mask.
            enable_global; critical_pc = cursor * 4;
            addi(15, 13, 1, 56);
            csrop(12'h344, 0, 2, 16, 0);
            if (KIND == 1) emit(itype(80, 1, 2, 17, 7'h03), 17, 0);
            if (KIND == 0) begin
                fault(itype(80, 1, 2, 17, 7'h03), 5, 32'h20000050);
                fault(sw(80, 3, 1), 7, 32'h20000050);
            end
        end else if (KIND == 2 || KIND == 3) begin
            emit(sw(72, 2, 1), 0, 0); emit(sw(76, 0, 1), 0, 0); emit(sw(72, 0, 1), 0, 0);
            emit(sw(80, 3, 1), 0, 0);
            csrop(12'h344, 0, 2, 10, 32'h888);
            csrop(12'h344, 0, 1, 0, 0); csrop(12'h344, 2, 2, 0, 0); csrop(12'h344, 2, 3, 0, 0);
            csrop(12'h344, 0, 2, 11, 32'h888);
            csrop(12'h304, 2, 1, 0, 0); csrop(12'h304, 0, 2, 12, 32'h888);
            enable_global; critical_pc = cursor * 4;
            addi(15, 0, 77, 77); csrop(12'h344, 0, 2, 16, 0);
        end else begin
            emit(32'h000012b7, 5, 32'h1000); // Kept outside the programmed data range below.
            addi(5, 0, 32, 32); addi(6, 0, 77, 77);
            emit(32'h000018b7, 17, 32'h1000); addi(17, 17, -2048, 2048);
            csrop(12'h304, 17, 1, 0, 0); enable_global;
            if (KIND == 7) fault(sw(0, 6, 5), 7, 32'd32);
            else emit(sw(0, 6, 5), 0, 0);
            critical_pc = cursor * 4;
            emit(itype(0, 5, 2, 7, 7'h03), 7, KIND == 7 ? 0 : 77);
            addi(8, 7, 1, KIND == 7 ? 1 : 78);
        end
        terminal_pc = cursor * 4;
        addi(19, 0, 1, 1); rom[cursor] = jump(0); handler;
        #1;
        for (i = 0; i < 256; i = i + 1) dut.u_if_stage.u_instr_mem.mem[i] = rom[i];
        repeat (4) @(negedge clk); rst_n = 1;
    end

    // Test pin changes happen between CPU sampling edges.
    always @(negedge clk) if (rst_n && !external_armed && KIND >= 5 && KIND <= 7) begin
        if ((KIND == 5 && d_req_valid && !d_req_ready) || (KIND != 5 && memory_active)) begin
            irq_external = 1; external_armed = 1;
        end
    end
    always @(posedge clk) begin
        if (!rst_n) begin
            d_rsp_valid <= 0; memory_active <= 0; req_wait <= 0;
        end else if (!done) begin
            if (d_req_valid && !d_req_ready) begin req_wait <= req_wait + 1; blocked_requests = blocked_requests + 1; end
            if (d_rsp_valid && d_rsp_ready) begin d_rsp_valid <= 0; responses = responses + 1; end
            if (d_req_valid && d_req_ready) begin
                if (memory_active || d_rsp_valid) $fatal(1, "Machine IRQ endpoint overlap");
                memory_active <= 1; saved_addr <= d_req_addr; saved_data <= d_req_data;
                saved_strobe <= d_req_strobe; saved_write <= d_req_write;
                rsp_wait <= (requests == 0 && (KIND == 6 || KIND == 7)) ? 70 : 3;
                requests = requests + 1;
            end
            if (memory_active) begin
                response_holds = response_holds + 1;
                if (rsp_wait != 0) rsp_wait <= rsp_wait - 1;
                else begin
                    memory_active <= 0; d_rsp_valid <= 1;
                    d_rsp_error <= KIND == 7 && saved_write;
                    d_rsp_data <= memory[saved_addr[7:2]];
                    if (saved_write && KIND != 7) begin
                        for (lane = 0; lane < 4; lane = lane + 1)
                            if (saved_strobe[lane]) memory[saved_addr[7:2]][lane*8+:8] <= saved_data[lane*8+:8];
                        stores = stores + 1;
                    end
                end
            end
        end
    end
    always @(posedge clk) begin
        if (!rst_n) begin request_held <= 0; response_held <= 0; end
        else if (!done) begin
            if (request_held && (!d_req_valid ||
                {d_req_write,d_req_addr,d_req_size,d_req_data,d_req_strobe} !== held_descriptor))
                $fatal(1, "Machine IRQ changed a blocked memory request");
            if (response_held && (!d_rsp_valid || {d_rsp_error,d_rsp_data} !== held_response))
                $fatal(1, "Machine IRQ endpoint changed a held response");
            request_held <= d_req_valid && !d_req_ready;
            held_descriptor <= {d_req_write,d_req_addr,d_req_size,d_req_data,d_req_strobe};
            response_held <= d_rsp_valid && !d_rsp_ready; held_response <= {d_rsp_error,d_rsp_data};
        end
    end
    always @(posedge clk) if (rst_n && !done) begin
        if (dut.mmio_msip_write_x) msip_writes = msip_writes + 1;
        if (dut.mret_commit_x) begin
            if (!in_handler || dut.csr_mepc !== resume_pc || dut.csr_mstatus[7] !== saved_mie)
                $fatal(1, "Machine IRQ MRET did not preserve the exact resume PC/previous MIE");
            mret_commits = mret_commits + 1; in_handler = 0;
        end
        #1;
        if (imem_fault || dmem_fault) $fatal(1, "Machine IRQ entered a sticky access halt");
        if (!EXT_ENABLE && (dut.external_irq_meta !== 0 || dut.external_irq_sync !== 0))
            $fatal(1, "Disabled external IRQ pin leaked into synchronizer");
        if (trap_valid) begin
            if (in_handler || trap_pc[1:0] != 0 || dut.csr_mepc !== trap_pc ||
                dut.csr_mcause !== trap_cause || dut.csr_mtval !== trap_tval || dut.csr_mstatus[3] !== 0)
                $fatal(1, "Machine IRQ incorrect precise trap descriptor kind=%0d", KIND);
            in_handler = 1; saved_mie = dut.csr_mstatus[7];
            if (trap_cause[31]) begin
                if (trap_tval !== 0 || trap_pc !== critical_pc ||
                    requests != responses || memory_active || d_rsp_valid || dut.mem_active)
                    $fatal(1, "Machine IRQ preempted a memory transaction or saved wrong PC kind=%0d", KIND);
                if (KIND == 2 || KIND == 3) begin
                    if (trap_cause !== (irqs == 0 ? 32'h8000000b : irqs == 1 ? 32'h80000003 : 32'h80000007))
                        $fatal(1, "Machine IRQ priority was not MEI > MSI > MTI");
                end else if (trap_cause !== (KIND == 1 ? 32'h80000003 : KIND == 10 ? 32'h80000007 : 32'h8000000b))
                    $fatal(1, "Machine IRQ selected an unimplemented/wrong source");
                if (KIND == 7 && syncs != 1) $fatal(1, "External IRQ defeated synchronous memory error");
                if (retire_count[critical_pc/4] != 0) $fatal(1, "Machine IRQ interrupted an already retired instruction");
                irqs = irqs + 1; resume_pc = trap_pc;
                if (irqs > expected_irqs) $fatal(1, "Machine IRQ repeated unexpectedly");
                if (trap_cause == 32'h8000000b) begin
                    if (!dut.external_irq_sync || !dut.csr_mip_value[11])
                        $fatal(1, "External level was automatically cleared on entry");
                    if (KIND != 4 || irqs == 2) irq_external = 0;
                end
            end else begin
                if (trap_pc >= 512 || !fault_expected[trap_pc/4] ||
                    trap_cause !== fault_cause[trap_pc/4] || trap_tval !== fault_tval[trap_pc/4])
                    $fatal(1, "Machine IRQ wrong synchronous fault kind=%0d PC=%h cause=%h tval=%h", KIND, trap_pc, trap_cause, trap_tval);
                syncs = syncs + 1; resume_pc = trap_pc + 4;
                if (KIND == 9 && dut.software_msip !== 1) $fatal(1, "Invalid MSIP access changed pending bit");
            end
        end
        if (retire_valid) begin
            if (wb_pc == 572) mret_retired = mret_retired + 1;
            if (wb_pc < 512) begin
                if (!main_expected[wb_pc/4] || fault_expected[wb_pc/4] || retire_count[wb_pc/4] != 0)
                    $fatal(1, "Machine IRQ wrong/duplicate main retirement kind=%0d PC=%h", KIND, wb_pc);
                retire_count[wb_pc/4] = retire_count[wb_pc/4] + 1;
                if (write_expected[wb_pc/4] &&
                    (!wb_we || wb_rd !== expected_rd[wb_pc/4] || wb_data !== expected_data[wb_pc/4]))
                    $fatal(1, "Machine IRQ wrong register result kind=%0d PC=%h got=%h expected=%h", KIND, wb_pc, wb_data, expected_data[wb_pc/4]);
                if (wb_pc == terminal_pc) begin
                    if (irqs != expected_irqs || syncs != expected_syncs || in_handler ||
                        mret_commits != irqs + syncs || mret_retired != irqs + syncs)
                        $fatal(1, "Machine IRQ terminal counts kind=%0d IRQ/sync/MRET=%0d/%0d/%0d", KIND, irqs, syncs, mret_retired);
                    for (i = 0; i < cursor; i = i + 1)
                        if (main_expected[i] && retire_count[i] != 1) $fatal(1, "Machine IRQ missed main PC=%h", i*4);
                    if (SOFT_ENABLE && dut.software_msip !== 0) $fatal(1, "MSIP was not acknowledged by software");
                    if (KIND == 1 || KIND == 2 || KIND == 3 || KIND == 9)
                        if (msip_writes != 2) $fatal(1, "MSIP side effect repeated/missing kind=%0d count=%0d", KIND, msip_writes);
                    if (KIND >= 5 && KIND <= 7 &&
                        (requests != 2 || responses != 2 || stores != (KIND == 7 ? 0 : 1) || memory[8] !== (KIND == 7 ? 0 : 77)))
                        $fatal(1, "Machine IRQ lost/replayed external data side effect");
                    if (KIND == 5 && blocked_requests < 70) $fatal(1, "Request wait case did not hold request");
                    if ((KIND == 6 || KIND == 7) && response_holds < 70) $fatal(1, "Response wait case did not hold response");
                    if (dut.u_regfile.regs[29] !== syncs || dut.u_regfile.regs[30] !== irqs)
                        $fatal(1, "Machine IRQ instruction handler counts do not match observed traps");
                    // Assert reset with the raw external pin high. All CPU
                    // pending/synchronizer/CSR state must reset independently.
                    #1; irq_external = 1; rst_n = 0; #1;
                    if (dut.external_irq_meta !== 0 || dut.external_irq_sync !== 0 ||
                        dut.software_msip !== 0 || dut.csr_mie !== 0 || dut.csr_mstatus !== 32'h1800 ||
                        dut.csr_mtvec !== 0 || dut.mem_active || trap_valid)
                        $fatal(1, "Machine IRQ reset retained pending/protocol/CSR state");
                    done = 1;
                    $display("MACHINE IRQ CPU CASE PASS kind=%0d BTB=%0d IRQ=%0d sync=%0d", KIND, PRED, irqs, syncs);
                end
            end
        end
    end
endmodule
