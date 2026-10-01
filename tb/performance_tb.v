`timescale 1ns/1ps
module performance_tb;
    reg clk = 1'b0;
    reg rst_n = 1'b0;

    wire [31:0] pc_x;
    wire [31:0] instr_x;
    wire        valid_x;
    wire [31:0] wb_pc;
    wire [4:0]  wb_rd;
    wire [31:0] wb_data;
    wire        wb_we;
    wire        retire_valid;
    wire [63:0] cycle_count;
    wire [63:0] instret_count;

    integer watchdog_cycles;
    reg [63:0] cpi_milli;

    localparam integer TOHOST_WORD = 4095;
    // This fixed c_demo image executes exactly 155 architectural
    // instructions through the store to tohost.  Checking the exact value
    // catches accidental counting of branch bubbles or squashed instructions.
    localparam [63:0] EXPECTED_INSTRET = 64'd155;

    cpu_top #(
        .PROGRAM_FILE("programs/c_demo.hex"),
        .DATA_FILE("programs/c_demo_data.hex"),
        .IMEM_WORDS(8192),
        .DMEM_WORDS(4096),
        .DMEM_BASE_ADDR(32'h00010000)
    ) dut (
        .clk(clk),
        .rst_n(rst_n), .uart_rx(1'b1),
        .pc_x(pc_x),
        .instr_x(instr_x),
        .valid_x(valid_x),
        .wb_pc(wb_pc),
        .wb_rd(wb_rd),
        .wb_data(wb_data),
        .wb_we(wb_we),
        .retire_valid(retire_valid),
        .cycle_count(cycle_count),
        .instret_count(instret_count), .gpio_in(8'd0), .gpio_out(), .gpio_oe(), .uart_tx(),
        .imem_req_valid(), .imem_req_ready(1'b0), .imem_req_addr(),
        .imem_rsp_valid(1'b0), .imem_rsp_ready(), .imem_rsp_rdata(32'd0),
        .imem_rsp_error(1'b0), .imem_fault(), .imem_fault_pc(),
        .dmem_req_valid(), .dmem_req_ready(1'b0), .dmem_req_write(),
        .dmem_req_addr(), .dmem_req_size(), .dmem_req_wdata(), .dmem_req_wstrb(),
        .dmem_rsp_valid(1'b0), .dmem_rsp_ready(), .dmem_rsp_rdata(32'd0),
        .dmem_rsp_error(1'b0), .dmem_fault()
    );

    always #5 clk = ~clk;

    initial begin
        watchdog_cycles = 0;
        cpi_milli = 64'd0;

        // Release reset away from an active clock edge to avoid a TB/DUT race.
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // The store updates RAM at request acceptance. Wait for its response
        // and then the retire counter edge before taking this snapshot.
        while ((dut.u_data_mem.mem[TOHOST_WORD] !== 32'd1) &&
               (dut.u_data_mem.mem[TOHOST_WORD] !== 32'd2) &&
               (dut.u_data_mem.mem[TOHOST_WORD] !== 32'd3) &&
               (dut.u_data_mem.mem[TOHOST_WORD] !== 32'd4)) begin
            @(posedge clk);
            #1;
            watchdog_cycles = watchdog_cycles + 1;
            if (watchdog_cycles > 1000)
                $fatal(1, "Performance test timeout pc=%h instr=%h",
                       pc_x, instr_x);
        end

        if (dut.u_data_mem.mem[TOHOST_WORD] !== 32'd1)
            $fatal(1, "C program reported failure code=%h",
                   dut.u_data_mem.mem[TOHOST_WORD]);

        repeat (2) begin
            @(posedge clk);
            #1;
        end

        if (cycle_count == 64'd0)
            $fatal(1, "cycle_count did not start");
        if (instret_count == 64'd0)
            $fatal(1, "instret_count did not count retired instructions");
        if (instret_count != EXPECTED_INSTRET)
            $fatal(1, "Unexpected retired count: got=%0d expected=%0d",
                   instret_count, EXPECTED_INSTRET);
        if (instret_count > cycle_count)
            $fatal(1, "Invalid counters: instret=%0d cycles=%0d",
                   instret_count, cycle_count);

        cpi_milli = (cycle_count * 64'd1000) / instret_count;

        $display("PASS: performance counters and C program completed");
        $display("PERF: tohost=%0d", dut.u_data_mem.mem[TOHOST_WORD]);
        $display("PERF: cycles=%0d", cycle_count);
        $display("PERF: retired instructions=%0d", instret_count);
        $display("PERF: CPI=%0d.%03d",
                 cpi_milli / 64'd1000, cpi_milli % 64'd1000);
        $stop;
    end
endmodule
