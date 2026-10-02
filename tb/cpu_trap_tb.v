`timescale 1ns/1ps

// All programs below execute real CPU instructions.  The testbench only installs
// ROM contents during reset and supplies an independent delayed memory endpoint.
// The common handler reads the architectural trap CSRs, advances mepc and MRETs.
module cpu_trap_tb;
    wire [7:0] done;
    reg test_pass = 0;
    trap_program_case #(.CASE_ID(0), .KIND(0)) csr_fast(done[0]);
    trap_program_case #(.CASE_ID(1), .KIND(0), .WAIT_MODE(1)) csr_wait(done[1]);
    trap_program_case #(.CASE_ID(2), .KIND(1)) local_fast(done[2]);
    trap_program_case #(.CASE_ID(3), .KIND(1), .WAIT_MODE(1)) local_wait(done[3]);
    trap_program_case #(.CASE_ID(4), .KIND(1), .EXT_DATA(1)) external_fast(done[4]);
    trap_program_case #(.CASE_ID(5), .KIND(1), .EXT_DATA(1), .WAIT_MODE(2)) external_random(done[5]);
    trap_program_case #(.CASE_ID(6), .KIND(2), .EXT_DATA(1), .EXT_FETCH(1)) fetch_fast(done[6]);
    trap_program_case #(.CASE_ID(7), .KIND(2), .EXT_DATA(1), .EXT_FETCH(1), .WAIT_MODE(2)) fetch_random(done[7]);
    initial begin
        wait (&done);
        test_pass = 1;
        $display("PASS: synchronous traps: CSR forms/WARL, FENCE, ECALL/EBREAK/MRET, precise exceptions, delayed endpoints, stale fetch errors and reset recovery");
        $stop;
    end
    initial begin
        #400000;
        $fatal(1, "Trap tests timeout done=%h", done);
    end
endmodule

module trap_program_case #(
    parameter integer CASE_ID = 0,
    parameter integer KIND = 0,
    parameter integer WAIT_MODE = 0,
    parameter integer EXT_DATA = 0,
    parameter integer EXT_FETCH = 0
) (output reg done = 0);
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    wire [31:0] pc_x, instr_x, wb_pc, wb_data;
    wire [4:0] wb_rd;
    wire wb_we, retire_valid, trap_valid, dmem_fault, imem_fault;
    wire [31:0] trap_pc, trap_cause, trap_tval;
    wire [63:0] instret_count;
    wire [7:0] gpio_out, gpio_oe;
    wire dr_valid, dr_write, ds_ready, ir_valid, is_ready;
    wire [31:0] dr_addr, dr_wdata, ir_addr;
    wire [1:0] dr_size;
    wire [3:0] dr_wstrb;
    reg ds_valid = 0, ds_error = 0, is_valid = 0, is_error = 0;
    reg [31:0] ds_data = 0, is_data = 0;
    reg d_active = 0, i_active = 0;
    reg [31:0] random_q = 32'h8a17d527 ^ CASE_ID;
    integer d_req_wait = 0, d_rsp_wait = 0, i_req_wait = 0, i_rsp_wait = 0;
    integer d_requests = 0, d_responses = 0, stale_errors = 0;
    integer blocked_data = 0, blocked_fetch = 0, held_fetch = 0;
    reg [31:0] memory [0:63];
    reg [31:0] rom [0:255];
    reg rom_error [0:255];
    reg expected_retire [0:255], forbidden_retire [0:255];
    reg expected_we [0:255];
    reg [4:0] expected_rd [0:255];
    reg [31:0] expected_data [0:255];
    integer retired_seen [0:255];
    reg [31:0] expected_trap_pc [0:63], expected_cause [0:63];
    reg [31:0] expected_tval [0:63], expected_status [0:63];
    integer cursor = 0, expected_traps = 0, traps = 0;
    integer main_retirements = 0, handler_returns = 0, terminal_pc = 0;
    integer older_store_pc = -1, fence_pc = -1, special_fetch_pc = -1;
    integer k, lane, saved_traps, saved_retirements, saved_requests;
    reg finished = 0;
    reg [63:0] counter_score = 0;
    reg held_dreq = 0, held_ireq = 0, held_drsp = 0, held_irsp = 0;
    reg [70:0] held_ddesc;
    reg [31:0] held_iaddr;
    reg [32:0] held_dpayload, held_ipayload;
    reg [31:0] current_status = 32'h00001880;
    reg [31:0] last_pc = 0, last_cause = 0, last_tval = 0, last_status = 0;
    // Deliberately hold the old-path PC 36 request through a redirect.
    wire dr_ready = rst_n && !d_active && !ds_valid &&
        (WAIT_MODE == 0 || (WAIT_MODE == 1 ? d_req_wait >= 3 : random_q[1]));
    wire ir_ready = rst_n && !i_active && !is_valid &&
        ((KIND != 2 || ir_addr != 36 || i_req_wait >= 6) &&
         (WAIT_MODE == 0 || (WAIT_MODE == 1 ? i_req_wait >= 2 : random_q[4])));

    cpu_top #(
        .PROGRAM_FILE("programs/data_handshake_blank.hex"),
        .IMEM_WORDS(256), .DMEM_WORDS(64), .DMEM_BASE_ADDR(0),
        .SIM_CONSOLE_ECHO(0), .ENABLE_TRAPS(1),
        .EXTERNAL_DMEM(EXT_DATA), .EXTERNAL_IMEM(EXT_FETCH),
        .DMEM_REQ_WAIT_CYCLES(WAIT_MODE == 0 ? 0 : 3),
        .DMEM_RSP_WAIT_CYCLES(WAIT_MODE == 0 ? 0 : 7),
        .IMEM_REQ_WAIT_CYCLES(WAIT_MODE == 0 ? 0 : 2),
        .IMEM_RSP_WAIT_CYCLES(WAIT_MODE == 0 ? 0 : 3)
    ) dut (
        .clk(clk), .rst_n(rst_n), .pc_x(pc_x), .instr_x(instr_x), .valid_x(),
        .wb_pc(wb_pc), .wb_rd(wb_rd), .wb_data(wb_data), .wb_we(wb_we),
        .retire_valid(retire_valid), .cycle_count(), .instret_count(instret_count),
        .uart_rx(1'b1), .uart_tx(), .gpio_in(8'd0), .gpio_out(gpio_out), .gpio_oe(gpio_oe),
        .dmem_req_valid(dr_valid), .dmem_req_ready(dr_ready), .dmem_req_write(dr_write),
        .dmem_req_addr(dr_addr), .dmem_req_size(dr_size), .dmem_req_wdata(dr_wdata),
        .dmem_req_wstrb(dr_wstrb), .dmem_rsp_valid(ds_valid), .dmem_rsp_ready(ds_ready),
        .dmem_rsp_rdata(ds_data), .dmem_rsp_error(ds_error), .dmem_fault(dmem_fault),
        .imem_req_valid(ir_valid), .imem_req_ready(ir_ready), .imem_req_addr(ir_addr),
        .imem_rsp_valid(is_valid), .imem_rsp_ready(is_ready), .imem_rsp_rdata(is_data),
        .imem_rsp_error(is_error), .imem_fault(imem_fault), .imem_fault_pc(),
        .trap_valid(trap_valid), .trap_pc(trap_pc), .trap_cause(trap_cause), .trap_tval(trap_tval)
    );

    function [31:0] itype;
        input integer imm;
        input [4:0] rs1;
        input [2:0] f3;
        input [4:0] rd;
        input [6:0] op;
        begin itype = {imm[11:0], rs1, f3, rd, op}; end
    endfunction
    function [31:0] csr;
        input [11:0] addr;
        input [4:0] source;
        input [2:0] f3;
        input [4:0] rd;
        begin csr = {addr, source, f3, rd, 7'h73}; end
    endfunction
    function [31:0] stype;
        input integer imm;
        input [4:0] rs2, rs1;
        input [2:0] f3;
        begin stype = {imm[11:5], rs2, rs1, f3, imm[4:0], 7'h23}; end
    endfunction
    function [31:0] btype;
        input integer imm;
        input [4:0] rs2, rs1;
        input [2:0] f3;
        begin btype = {imm[12], imm[10:5], rs2, rs1, f3, imm[4:1], imm[11], 7'h63}; end
    endfunction
    function [31:0] jtype;
        input integer imm;
        input [4:0] rd;
        begin jtype = {imm[20], imm[10:1], imm[11], imm[19:12], rd, 7'h6f}; end
    endfunction
    task emit;
        input [31:0] instruction;
        input integer rd;
        input [31:0] data;
        begin
            if (cursor >= 192) $fatal(1, "Test program overlaps trap handler");
            rom[cursor] = instruction;
            expected_retire[cursor] = 1;
            expected_we[cursor] = rd > 0;
            expected_rd[cursor] = rd[4:0];
            expected_data[cursor] = data;
            cursor = cursor + 1;
        end
    endtask
    task addi;
        input integer rd, rs1, immediate;
        input [31:0] result;
        begin emit(itype(immediate, rs1[4:0], 0, rd[4:0], 7'h13), rd, result); end
    endtask
    task csr_op;
        input [11:0] address;
        input integer source;
        input [2:0] f3;
        input integer rd;
        input [31:0] old_value;
        begin emit(csr(address, source[4:0], f3, rd[4:0]), rd, old_value); end
    endtask
    task exception;
        input [31:0] instruction, cause, tval;
        begin
            rom[cursor] = instruction;
            forbidden_retire[cursor] = 1;
            expected_trap_pc[expected_traps] = cursor * 4;
            expected_cause[expected_traps] = cause;
            expected_tval[expected_traps] = tval;
            expected_status[expected_traps] = current_status;
            expected_traps = expected_traps + 1;
            cursor = cursor + 1;
        end
    endtask
    task illegal;
        input [31:0] instruction;
        begin exception(instruction, 2, instruction); end
    endtask
    task wrong_path;
        input [31:0] instruction;
        begin rom[cursor] = instruction; forbidden_retire[cursor] = 1; cursor = cursor + 1; end
    endtask
    task clear_program;
        integer n;
        begin
            cursor = 0; expected_traps = 0; finished = 0;
            older_store_pc = -1; fence_pc = -1; special_fetch_pc = -1;
            for (n=0; n<256; n=n+1) begin
                rom[n] = 32'h00000013; rom_error[n] = 0;
                expected_retire[n] = 0; forbidden_retire[n] = 0;
                expected_we[n] = 0; expected_rd[n] = 0; expected_data[n] = 0;
                retired_seen[n] = 0;
            end
        end
    endtask
    task install_handler;
        begin
            rom[192] = csr(12'h342, 0, 2, 26);
            rom[193] = csr(12'h341, 0, 2, 27);
            rom[194] = csr(12'h343, 0, 2, 28);
            rom[195] = csr(12'h300, 0, 2, 29);
            rom[196] = itype(4, 27, 0, 27, 7'h13);
            rom[197] = csr(12'h341, 27, 1, 0);
            rom[198] = 32'h30200073;
        end
    endtask
    task terminal;
        begin
            terminal_pc = cursor * 4;
            addi(24, 0, 1, 1);
            rom[cursor] = jtype(0, 0);
        end
    endtask
    task install_rom;
        integer n;
        begin for (n=0; n<256; n=n+1) dut.u_if_stage.u_instr_mem.mem[n] = rom[n]; end
    endtask

    // CSR expectations are explicit architectural before/after values rather
    // than a reimplementation of the DUT's CSR logic.
    task build_csr_program;
        begin
            addi(1, 0, 16'h303, 32'h303); csr_op(12'h305, 1, 1, 0, 0);
            csr_op(12'h305, 0, 2, 2, 32'h300);
            addi(1, 0, 16'h456, 32'h456); csr_op(12'h340, 1, 1, 3, 0);
            addi(4, 3, 5, 5); // Adjacent CSR read result -> ALU forwarding.
            csr_op(12'h340, 0, 2, 5, 32'h456); addi(6, 5, 1, 32'h457);
            addi(1, 0, 10, 10);
            csr_op(12'h340, 1, 2, 7, 32'h456); // 456 | A = 45E.
            csr_op(12'h340, 1, 3, 8, 32'h45e); // 45E & ~A = 454.
            csr_op(12'h340, 3, 5, 9, 32'h454);
            csr_op(12'h340, 4, 6, 10, 3);
            csr_op(12'h340, 1, 7, 11, 7);
            csr_op(12'h340, 0, 2, 12, 6);
            csr_op(12'h340, 0, 6, 13, 6);
            csr_op(12'h340, 0, 3, 14, 6);
            csr_op(12'h340, 0, 7, 15, 6);
            csr_op(12'h340, 0, 1, 0, 0); // rd=x0 does not suppress WRITE.
            csr_op(12'h340, 0, 2, 16, 0);
            csr_op(12'h340, 0, 5, 17, 0); // CSRRWI zimm=0 still writes.
            csr_op(12'h301, 0, 2, 18, 32'h40000100);
            addi(1, 0, 0, 0);
            csr_op(12'h301, 1, 2, 19, 32'h40000100); // misa fixed WARL, legal write intent.
            csr_op(12'h301, 0, 1, 0, 0);
            csr_op(12'h301, 0, 5, 20, 32'h40000100);
            csr_op(12'h301, 0, 3, 21, 32'h40000100);
            csr_op(12'hf14, 0, 2, 22, 0);
            csr_op(12'hf14, 0, 7, 23, 0);
            addi(1, 0, 16'h123, 32'h123); csr_op(12'h341, 1, 1, 0, 0);
            csr_op(12'h341, 0, 2, 2, 32'h120);
            addi(1, 0, 16'h77, 32'h77); csr_op(12'h342, 1, 1, 0, 0);
            csr_op(12'h342, 0, 2, 3, 32'h77);
            addi(1, 0, 16'h666, 32'h666); csr_op(12'h343, 1, 1, 0, 0);
            csr_op(12'h343, 0, 2, 4, 32'h666);
            addi(1, 0, -1, 32'hffffffff); csr_op(12'h300, 1, 1, 5, 32'h1800);
            csr_op(12'h300, 0, 2, 6, 32'h1888);
            // Reserved fm/rd/rs1 and pred/succ=0 are legal FENCE hints.
            emit(itype(-1, 31, 0, 31, 7'h0f), 0, 0);
            emit(itype(0, 31, 0, 31, 7'h0f), 0, 0);
            current_status = 32'h1880;
            exception(32'h00000073, 11, 0);
            csr_op(12'h300, 0, 2, 7, 32'h1888);
            exception(32'h00100073, 3, cursor*4);
            csr_op(12'h300, 0, 2, 8, 32'h1888);
            csr_op(12'h300, 8, 7, 0, 0); // Clear MIE only.
            current_status = 32'h1800;
            exception(32'h00000073, 11, 0);
            csr_op(12'h300, 0, 2, 9, 32'h1880);
            illegal(32'h0000100f); // FENCE.I is deliberately unsupported.
            illegal(32'h00008073); // ECALL with nonzero rs1.
            illegal(32'h302000f3); // MRET with nonzero rd.
            illegal(csr(12'h7ff, 0, 2, 10));
            illegal(csr(12'hf14, 0, 5, 0)); // readonly CSRRWI(0) still WRITE.
            addi(1, 0, 0, 0);
            illegal(csr(12'hf14, 1, 2, 11)); // rs1!=x0, value zero: WRITE intent.
            illegal(csr(12'hf11, 1, 3, 12));
            illegal(csr(12'hf12, 1, 1, 0));
            illegal(csr(12'hf13, 1, 6, 0));
            illegal(csr(12'hf15, 1, 7, 0));
            csr_op(12'hf14, 0, 2, 0, 0); // rs1=x0, rd=x0 suppresses WRITE.
            csr_op(12'hf11, 0, 2, 13, 0);
            csr_op(12'hf12, 0, 2, 14, 0);
            csr_op(12'hf13, 0, 2, 15, 0);
            csr_op(12'hf15, 0, 2, 16, 0);
            csr_op(12'h340, 0, 2, 17, 0);
            terminal();
        end
    endtask

    task build_exception_program;
        begin
            addi(1, 0, 16'h303, 32'h303); csr_op(12'h305, 1, 1, 0, 0);
            addi(1, 0, 8, 8); csr_op(12'h300, 1, 1, 0, 0);
            current_status = 32'h1880;
            addi(3, 0, 77, 77);
            exception(32'h00000073, 11, 0); // Older ADDI must still write x3.
            exception(32'h00100073, 3, cursor*4);
            exception(jtype(2, 4), 0, cursor*4+2);
            exception(btype(2, 0, 0, 0), 0, cursor*4+2);
            addi(5, 0, 2, 2); exception(itype(0, 5, 0, 6, 7'h67), 0, 2);
            emit(btype(2, 3, 0, 0), 0, 0); // Not taken: no target-alignment trap.
            addi(5, 0, (cursor+2)*4+1, (cursor+2)*4+1);
            emit(itype(0, 5, 0, 6, 7'h67), 6, (cursor+1)*4); // JALR clears bit0.
            emit(32'h20000a37, 20, 32'h20000000);
            emit(btype(16, 0, 0, 0), 0, 0);
            wrong_path(32'h00000073);
            wrong_path(csr(12'h340, 3, 1, 0));
            wrong_path(stype(16'h34, 3, 20, 2));
            emit(jtype(12, 0), 0, 0);
            wrong_path(stype(4, 3, 0, 2));
            wrong_path(csr(12'h300, 0, 1, 0));
            csr_op(12'h340, 0, 2, 7, 0);
            csr_op(12'h300, 0, 2, 8, 32'h1888);
            older_store_pc = cursor*4;
            emit(stype(0, 3, 0, 2), 0, 0);
            fence_pc = cursor*4; emit(32'h0ff0000f, 0, 0);
            emit(itype(0, 0, 2, 9, 7'h03), 9, 77);
            exception(itype(1, 0, 1, 10, 7'h03), 4, 1);
            exception(itype(3, 0, 5, 10, 7'h03), 4, 3);
            exception(itype(2, 0, 2, 10, 7'h03), 4, 2);
            exception(stype(1, 3, 0, 1), 6, 1);
            exception(stype(2, 3, 0, 2), 6, 2);
            emit(itype(1, 0, 0, 11, 7'h03), 11, 0); // Byte accesses need no alignment.
            exception(itype(256, 0, 2, 12, 7'h03), 5, 256);
            exception(stype(256, 3, 0, 2), 7, 256);
            exception(itype(64, 20, 2, 13, 7'h03), 5, 32'h20000040);
            exception(stype(0, 3, 20, 2), 7, 32'h20000000);
            illegal(32'h04000033); // Unsupported OP funct7.
            illegal(32'h02001013); // Reserved SLLI upper immediate.
            illegal(itype(0, 0, 1, 14, 7'h67));
            illegal(itype(0, 0, 3, 14, 7'h03));
            illegal(stype(0, 3, 0, 3));
            illegal(32'h00000001); // No compressed ISA.
            emit(itype(0, 0, 2, 15, 7'h03), 15, 77);
            emit(itype(4, 0, 2, 16, 7'h03), 16, 0); // Wrong-path STORE stayed suppressed.
            csr_op(12'h340, 0, 2, 17, 0);
            terminal();
        end
    endtask

    task build_fetch_program;
        begin
            addi(1, 0, 16'h300, 32'h300); csr_op(12'h305, 1, 1, 0, 0);
            addi(1, 0, 8, 8); csr_op(12'h300, 1, 1, 0, 0);
            current_status = 32'h1880;
            addi(3, 0, 77, 77);
            older_store_pc = cursor*4; emit(stype(0, 3, 0, 2), 0, 0);
            special_fetch_pc = cursor*4;
            exception(itype(99, 0, 0, 4, 7'h13), 1, cursor*4);
            rom_error[6] = 1;
            emit(itype(0, 0, 2, 4, 7'h03), 4, 77);
            emit(btype(12, 0, 0, 0), 0, 0);
            wrong_path(32'h00000073); rom_error[9] = 1;
            wrong_path(stype(4, 3, 0, 2));
            csr_op(12'h300, 0, 2, 5, 32'h1888);
            emit(itype(4, 0, 2, 6, 7'h03), 6, 0);
            terminal();
        end
    endtask

    // The independent external endpoint accepts each request once, commits a
    // valid STORE at acceptance and snapshots read data then.  Errors do not
    // mutate memory.  It retains memory across a shared protocol reset.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d_active <= 0; ds_valid <= 0; ds_error <= 0; ds_data <= 0;
            i_active <= 0; is_valid <= 0; is_error <= 0; is_data <= 0;
            d_req_wait <= 0; d_rsp_wait <= 0; i_req_wait <= 0; i_rsp_wait <= 0;
            d_requests = 0; d_responses = 0; stale_errors = 0;
            blocked_data = 0; blocked_fetch = 0; held_fetch = 0;
            random_q <= 32'h8a17d527 ^ CASE_ID;
        end else begin
            random_q <= {random_q[30:0], random_q[31]^random_q[21]^random_q[1]^random_q[0]};
            if (dr_valid && !dr_ready) begin d_req_wait <= d_req_wait+1; blocked_data = blocked_data+1; end
            else d_req_wait <= 0;
            if (ir_valid && !ir_ready) begin i_req_wait <= i_req_wait+1; blocked_fetch = blocked_fetch+1; end
            else i_req_wait <= 0;
            if (dr_valid && dr_ready) begin
                if (d_active || ds_valid) $fatal(1, "Case %0d overlapping data request", CASE_ID);
                if ((dr_size == 2 && dr_addr[1:0] != 0) || (dr_size == 1 && dr_addr[0]))
                    $fatal(1, "Case %0d misaligned request escaped CPU addr=%h", CASE_ID, dr_addr);
                if (dr_addr[31:16] == 16'h2000) $fatal(1, "MMIO escaped local CPU");
                ds_error <= dr_addr >= 256;
                ds_data <= dr_addr < 256 ? memory[dr_addr[7:2]] : 0;
                if (dr_write && dr_addr < 256)
                    for (lane=0; lane<4; lane=lane+1)
                        if (dr_wstrb[lane]) memory[dr_addr[7:2]][lane*8 +: 8] = dr_wdata[lane*8 +: 8];
                d_requests = d_requests + 1;
                d_active <= 1;
                d_rsp_wait <= KIND == 2 && dr_write ? 32 : (WAIT_MODE == 0 ? 1 : 5+random_q[3:1]);
            end
            if (d_active && !ds_valid) begin
                if (d_rsp_wait == 0) ds_valid <= 1;
                else d_rsp_wait <= d_rsp_wait-1;
            end
            if (ds_valid && ds_ready) begin ds_valid <= 0; d_active <= 0; d_responses = d_responses+1; end
            if (ir_valid && ir_ready) begin
                if (i_active || is_valid) $fatal(1, "Case %0d overlapping instruction request", CASE_ID);
                if (ir_addr >= 1024 || ir_addr[1:0]) $fatal(1, "Unexpected instruction address=%h", ir_addr);
                is_data <= rom[ir_addr[9:2]];
                is_error <= rom_error[ir_addr[9:2]];
                if (ir_addr == 36 && rom_error[9]) stale_errors = stale_errors+1;
                i_active <= 1;
                i_rsp_wait <= WAIT_MODE == 0 ? 1 : 2+random_q[8:6];
            end
            if (i_active && !is_valid) begin
                if (i_rsp_wait == 0) is_valid <= 1;
                else i_rsp_wait <= i_rsp_wait-1;
            end
            if (is_valid && !is_ready) held_fetch = held_fetch+1;
            if (is_valid && is_ready) begin is_valid <= 0; i_active <= 0; end
        end
    end

    // Handshake stability and architectural retirement monitor.  Trapped and
    // wrong-path instructions are never permitted to retire or modify GPRs.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            held_dreq = 0; held_ireq = 0; held_drsp = 0; held_irsp = 0;
            traps = 0; handler_returns = 0; main_retirements = 0; counter_score = 0;
            last_pc = 0; last_cause = 0; last_tval = 0; last_status = 0;
        end else begin
            if (retire_valid) counter_score = counter_score+1;
            if (held_dreq && (!dr_valid || {dr_write,dr_addr,dr_size,dr_wdata,dr_wstrb} !== held_ddesc))
                $fatal(1, "Case %0d unstable data descriptor", CASE_ID);
            held_dreq = dr_valid && !dr_ready;
            if (held_dreq) held_ddesc = {dr_write,dr_addr,dr_size,dr_wdata,dr_wstrb};
            if (held_ireq && (!ir_valid || ir_addr !== held_iaddr)) $fatal(1, "Case %0d unstable fetch request", CASE_ID);
            held_ireq = ir_valid && !ir_ready;
            if (held_ireq) held_iaddr = ir_addr;
            if (held_drsp && (!ds_valid || {ds_error,ds_data} !== held_dpayload)) $fatal(1, "Endpoint data response unstable");
            held_drsp = ds_valid && !ds_ready;
            if (held_drsp) held_dpayload = {ds_error,ds_data};
            if (held_irsp && (!is_valid || {is_error,is_data} !== held_ipayload)) $fatal(1, "Endpoint fetch response unstable");
            held_irsp = is_valid && !is_ready;
            if (held_irsp) held_ipayload = {is_error,is_data};
            if (EXT_DATA && (dut.mem_re_x || dut.mem_we_x)) $fatal(1, "External data used internal RAM");
            #1;
            if (instret_count !== counter_score) $fatal(1, "Case %0d instret includes exception or lost retirement got=%0d expected=%0d", CASE_ID, instret_count, counter_score);
            if (dmem_fault) $fatal(1, "Case %0d enabled trap left sticky data fault", CASE_ID);
            if (trap_valid) begin
                if (traps >= expected_traps || trap_pc !== expected_trap_pc[traps] ||
                    trap_cause !== expected_cause[traps] || trap_tval !== expected_tval[traps])
                    $fatal(1, "Case %0d trap%0d descriptor got pc=%h cause=%0d tval=%h expected pc=%h cause=%0d tval=%h",
                        CASE_ID, traps, trap_pc, trap_cause, trap_tval,
                        expected_trap_pc[traps], expected_cause[traps], expected_tval[traps]);
                if (retired_seen[trap_pc[9:2]] != 0) $fatal(1, "Faulting PC already retired");
                if (special_fetch_pc >= 0 && trap_pc == special_fetch_pc &&
                    (retired_seen[older_store_pc/4] != 1 || memory[0] !== 77))
                    $fatal(1, "Younger fetch error overtook older accepted STORE");
                last_pc = trap_pc; last_cause = trap_cause; last_tval = trap_tval;
                last_status = expected_status[traps]; traps = traps+1;
            end
            if (retire_valid) begin
                if (wb_pc >= 32'h300 && wb_pc <= 32'h318) begin
                    case (wb_pc)
                        32'h300: if (!wb_we || wb_rd != 26 || wb_data !== last_cause) $fatal(1, "Handler mcause read wrong");
                        32'h304: if (!wb_we || wb_rd != 27 || wb_data !== last_pc) $fatal(1, "Handler mepc read wrong");
                        32'h308: if (!wb_we || wb_rd != 28 || wb_data !== last_tval) $fatal(1, "Handler mtval read wrong");
                        32'h30c: if (!wb_we || wb_rd != 29 || wb_data !== last_status) $fatal(1, "Handler mstatus read got=%h expected=%h", wb_data, last_status);
                        32'h310: if (!wb_we || wb_rd != 27 || wb_data !== last_pc+4) $fatal(1, "Handler CSR->ALU forwarding wrong");
                        32'h318: handler_returns = handler_returns+1;
                        default: ;
                    endcase
                end else if (wb_pc != terminal_pc+4) begin
                    if (wb_pc[1:0] != 0 || wb_pc >= 1024 || forbidden_retire[wb_pc[9:2]] || !expected_retire[wb_pc[9:2]])
                        $fatal(1, "Case %0d wrong-path/fault/unknown PC retired=%h", CASE_ID, wb_pc);
                    if (retired_seen[wb_pc[9:2]] != 0) $fatal(1, "Case %0d repeated retirement PC=%h", CASE_ID, wb_pc);
                    retired_seen[wb_pc[9:2]] = retired_seen[wb_pc[9:2]]+1;
                    main_retirements = main_retirements+1;
                    if (expected_we[wb_pc[9:2]]) begin
                        if (!wb_we || wb_rd !== expected_rd[wb_pc[9:2]] || wb_data !== expected_data[wb_pc[9:2]])
                            $fatal(1, "Case %0d WB PC=%h rd=%0d data=%h expected rd=%0d data=%h", CASE_ID, wb_pc, wb_rd, wb_data,
                                expected_rd[wb_pc[9:2]], expected_data[wb_pc[9:2]]);
                    end else if (wb_we && wb_rd != 0) $fatal(1, "Unexpected architectural GPR write PC=%h rd=%0d", wb_pc, wb_rd);
                    if (wb_pc == fence_pc && retired_seen[older_store_pc/4] != 1) $fatal(1, "FENCE overtook older STORE");
                    if (wb_pc == terminal_pc) finished = 1;
                end
            end
        end
    end

    initial begin
        #1;
        for (k=0; k<64; k=k+1) begin memory[k] = 0; dut.u_data_mem.mem[k] = 0; end
        clear_program(); install_handler();
        if (KIND == 0) build_csr_program();
        else if (KIND == 1) build_exception_program();
        else build_fetch_program();
        install_rom(); repeat(3) @(negedge clk); rst_n = 1;
        wait (finished); @(negedge clk);
        if (traps != expected_traps || handler_returns != expected_traps)
            $fatal(1, "Case %0d lost/repeated exception traps=%0d expected=%0d returns=%0d", CASE_ID, traps, expected_traps, handler_returns);
        if (gpio_out !== 0 || gpio_oe !== 0) $fatal(1, "Wrong-path GPIO side effect");
        if (KIND != 0) begin
            if (EXT_DATA ? (memory[0] !== 77 || memory[1] !== 0) :
                           (dut.u_data_mem.mem[0] !== 77 || dut.u_data_mem.mem[1] !== 0))
                $fatal(1, "Older STORE lost or wrong-path/misaligned STORE changed RAM");
        end
        if (KIND == 2 && (stale_errors != 1 || blocked_fetch == 0 || held_fetch == 0))
            $fatal(1, "Fetch precision setup lacked held stale/current responses errors=%0d blocked=%0d held=%0d", stale_errors, blocked_fetch, held_fetch);
        if (EXT_DATA && d_requests != d_responses) $fatal(1, "External transaction count mismatch");
        saved_traps = traps; saved_retirements = main_retirements; saved_requests = d_requests;

        // A joint reset clears all architectural CSR and protocol state.  RAM
        // retention is checked separately from the reset CSR program below.
        rst_n = 0; repeat(3) @(negedge clk);
        if (trap_valid || dr_valid || ir_valid || ds_valid || is_valid || dmem_fault || imem_fault)
            $fatal(1, "Case %0d reset did not cancel trap/protocol state", CASE_ID);
        clear_program();
        csr_op(12'h300, 0, 2, 2, 32'h1800);
        csr_op(12'h305, 0, 2, 3, 0);
        csr_op(12'h340, 0, 2, 4, 0);
        csr_op(12'h341, 0, 2, 5, 0);
        csr_op(12'h342, 0, 2, 6, 0);
        csr_op(12'h343, 0, 2, 7, 0);
        terminal(); install_rom(); rst_n = 1;
        wait (finished); @(negedge clk);
        if (traps != 0 || instret_count < 6) $fatal(1, "Reset recovery failed");
        if (KIND != 0 && (EXT_DATA ? memory[0] !== 77 : dut.u_data_mem.mem[0] !== 77))
            $fatal(1, "Shared reset incorrectly cleared RAM");
        $display("TRAP case %0d PASS: kind=%0d wait=%0d external data/fetch=%0d/%0d exceptions=%0d main retirements=%0d external transactions=%0d, handler return and CSR/reset recovery",
            CASE_ID, KIND, WAIT_MODE, EXT_DATA, EXT_FETCH, saved_traps, saved_retirements, saved_requests);
        done = 1;
    end
endmodule
