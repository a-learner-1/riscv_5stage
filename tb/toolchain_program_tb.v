`timescale 1ns/1ps
module toolchain_program_tb;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    wire [31:0] pc_x, instr_x, wb_pc, wb_data;
    wire valid_x, wb_we;
    wire [4:0] wb_rd;
    integer cycles;

    localparam integer TOHOST_WORD = 255; // 0x3fc / 4

    cpu_top #(
        .PROGRAM_FILE("programs/toolchain_demo.hex"),
        .IMEM_WORDS(1024)
    ) dut (
        .clk(clk), .rst_n(rst_n), .uart_rx(1'b1),
        .pc_x(pc_x), .instr_x(instr_x), .valid_x(valid_x),
        .wb_pc(wb_pc), .wb_rd(wb_rd), .wb_data(wb_data), .wb_we(wb_we),
        .retire_valid(), .cycle_count(), .instret_count(), .gpio_in(8'd0), .gpio_out(), .gpio_oe(), .uart_tx(),
        .imem_req_valid(), .imem_req_ready(1'b0), .imem_req_addr(),
        .imem_rsp_valid(1'b0), .imem_rsp_ready(), .imem_rsp_rdata(32'd0),
        .imem_rsp_error(1'b0), .imem_fault(), .imem_fault_pc(),
        .dmem_req_valid(), .dmem_req_ready(1'b0), .dmem_req_write(),
        .dmem_req_addr(), .dmem_req_size(), .dmem_req_wdata(), .dmem_req_wstrb(),
        .dmem_rsp_valid(1'b0), .dmem_rsp_ready(), .dmem_rsp_rdata(32'd0),
        .dmem_rsp_error(1'b0), .dmem_fault(),
        .trap_valid(), .trap_pc(), .trap_cause(), .trap_tval()
    );

    always #5 clk = ~clk;

    initial begin
        cycles = 0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        while ((dut.u_data_mem.mem[TOHOST_WORD] !== 32'd1) &&
               (dut.u_data_mem.mem[TOHOST_WORD] !== 32'd2)) begin
            @(posedge clk);
            #1;
            cycles = cycles + 1;
            if (cycles > 250)
                $fatal(1, "toolchain program timeout pc=%h instr=%h", pc_x, instr_x);
        end

        if (dut.u_data_mem.mem[TOHOST_WORD] !== 32'd1)
            $fatal(1, "program reported failure code=%h",
                   dut.u_data_mem.mem[TOHOST_WORD]);
        if (dut.u_data_mem.mem[128] !== 32'd55)
            $fatal(1, "loop result at 0x200 got=%h expected=00000037",
                   dut.u_data_mem.mem[128]);
        if (dut.u_data_mem.mem[129][7:0] !== 8'hff)
            $fatal(1, "byte load/store result at 0x204 got=%h expected=ff",
                   dut.u_data_mem.mem[129][7:0]);

        $display("PASS: RV32I standalone program completed through tohost");
        $display("PASS: loop, branch, forwarding, word and byte memory checked");
        $display("PASS: tohost=1 cycles=%0d", cycles);
        $stop;
    end
endmodule
