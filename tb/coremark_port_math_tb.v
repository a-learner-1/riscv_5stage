`timescale 1ns/1ps
`include "programs/coremark_math_symbols.vh"
module coremark_port_math_case #(
    parameter PROGRAM_FILE = "", parameter DATA_FILE = "",
    parameter [31:0] CASES_ADDR = 0, FAILURE_ADDR = 0
)(output reg done = 0);
    reg clk = 0, rst_n = 0;
    wire trap_valid, imem_fault, dmem_fault;
    wire [31:0] pc, cause;
    integer watchdog = 0;
    cpu_top #(.PROGRAM_FILE(PROGRAM_FILE), .DATA_FILE(DATA_FILE),
        .IMEM_WORDS(8192), .DMEM_WORDS(4096), .DMEM_BASE_ADDR(32'h10000),
        .UART_CLOCK_HZ(100000000), .UART_BAUD(5000000), .SIM_CONSOLE_ECHO(0),
        .ENABLE_TRAPS(1), .ENABLE_TIMER_IRQ(1)) dut (
        .clk(clk), .rst_n(rst_n), .pc_x(pc), .instr_x(), .valid_x(),
        .wb_pc(), .wb_rd(), .wb_data(), .wb_we(), .retire_valid(),
        .cycle_count(), .instret_count(), .uart_tx(), .uart_rx(1'b1),
        .gpio_in(8'd0), .gpio_out(), .gpio_oe(),
        .imem_req_valid(), .imem_req_ready(1'b0), .imem_req_addr(),
        .imem_rsp_valid(1'b0), .imem_rsp_ready(), .imem_rsp_rdata(32'd0),
        .imem_rsp_error(1'b0), .imem_fault(imem_fault), .imem_fault_pc(),
        .dmem_req_valid(), .dmem_req_ready(1'b0), .dmem_req_write(),
        .dmem_req_addr(), .dmem_req_size(), .dmem_req_wdata(), .dmem_req_wstrb(),
        .dmem_rsp_valid(1'b0), .dmem_rsp_ready(), .dmem_rsp_rdata(32'd0),
        .dmem_rsp_error(1'b0), .dmem_fault(dmem_fault),
        .trap_valid(trap_valid), .trap_pc(), .trap_cause(cause), .trap_tval()
    );
    always #5 clk=~clk;
    always @(posedge clk) if (rst_n && (trap_valid || imem_fault || dmem_fault))
        $fatal(1,"Port fixture fault %s pc=%h cause=%h",PROGRAM_FILE,pc,cause);
    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk); rst_n=1;
        while (dut.u_data_mem.mem[4095] !== 32'd1 && dut.u_data_mem.mem[4095] !== 32'd2) begin
            @(posedge clk); #1;
            watchdog=watchdog+1;
            if (watchdog>5000000) $fatal(1,"Port fixture timeout %s pc=%h",PROGRAM_FILE,pc);
        end
        if (dut.u_data_mem.mem[4095] !== 1)
            $fatal(1,"Port fixture FAIL %s code=%0d",PROGRAM_FILE,dut.u_data_mem.mem[(FAILURE_ADDR-32'h10000)>>2]);
        if (dut.u_data_mem.mem[(CASES_ADDR-32'h10000)>>2] !== 13)
            $fatal(1,"Port fixture missing cases %s",PROGRAM_FILE);
        $display("PASS: %s 13 deterministic checks, mock timing is not a score",PROGRAM_FILE);
        done=1;
    end
endmodule
module coremark_port_math_tb;
    reg test_pass=0;
    wire [3:0] done;
    coremark_port_math_case #(.PROGRAM_FILE("programs/coremark_math_50_smoke.hex"),.DATA_FILE("programs/coremark_math_50_smoke_data.hex"),
        .CASES_ADDR(`COREMARK_MATH_50_SMOKE_CASES),.FAILURE_ADDR(`COREMARK_MATH_50_SMOKE_FAILURE)) f50s(done[0]);
    coremark_port_math_case #(.PROGRAM_FILE("programs/coremark_math_50_formal.hex"),.DATA_FILE("programs/coremark_math_50_formal_data.hex"),
        .CASES_ADDR(`COREMARK_MATH_50_FORMAL_CASES),.FAILURE_ADDR(`COREMARK_MATH_50_FORMAL_FAILURE)) f50f(done[1]);
    coremark_port_math_case #(.PROGRAM_FILE("programs/coremark_math_100_smoke.hex"),.DATA_FILE("programs/coremark_math_100_smoke_data.hex"),
        .CASES_ADDR(`COREMARK_MATH_100_SMOKE_CASES),.FAILURE_ADDR(`COREMARK_MATH_100_SMOKE_FAILURE)) f100s(done[2]);
    coremark_port_math_case #(.PROGRAM_FILE("programs/coremark_math_100_formal.hex"),.DATA_FILE("programs/coremark_math_100_formal_data.hex"),
        .CASES_ADDR(`COREMARK_MATH_100_FORMAL_CASES),.FAILURE_ADDR(`COREMARK_MATH_100_FORMAL_FAILURE)) f100f(done[3]);
    initial begin
        wait (&done);
        test_pass=1;
        $display("COREMARK PORT MATH PASS: 52 checks on RV32 CPU, including coherent rollover, 64-bit elapsed, fractional seconds, 50/100 MHz, strict failures; MOCK, NO SCORE");
        $stop;
    end
endmodule
