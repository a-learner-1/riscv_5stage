`timescale 1ns/1ps

module coremark_tb;
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

    cpu_top #(
        .PROGRAM_FILE("programs/coremark.hex"),
        .DATA_FILE("programs/coremark_data.hex"),
        .IMEM_WORDS(8192),
        .DMEM_WORDS(4096),
        .DMEM_BASE_ADDR(32'h0001_0000),
        // Faster UART only for this smoke test, not the board baud rate.
        .UART_CLOCK_HZ(100000000), .UART_BAUD(5000000)
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
        cpi_milli = 0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        while ((dut.u_data_mem.mem[TOHOST_WORD] !== 32'd1) &&
               (dut.u_data_mem.mem[TOHOST_WORD] !== 32'd2)) begin
            @(posedge clk);
            #1;
            watchdog_cycles = watchdog_cycles + 1;

            if (watchdog_cycles > 5000000)
                $fatal(1, "CoreMark timeout pc=%h instr=%h cycles=%0d",
                       pc_x, instr_x, cycle_count);
        end

        @(posedge clk);
        #1;

        if (dut.u_data_mem.mem[TOHOST_WORD] !== 32'd1)
            $fatal(1, "CoreMark validation failed: tohost=%0d",
                   dut.u_data_mem.mem[TOHOST_WORD]);

        if (instret_count == 0)
            $fatal(1, "CoreMark retired no instructions");

        cpi_milli = (cycle_count * 64'd1000) / instret_count;

        $display("");
        $display("PASS: CoreMark official algorithms validated");
        $display("COREMARK: cycles=%0d", cycle_count);
        $display("COREMARK: retired instructions=%0d", instret_count);
        $display("COREMARK: CPI=%0d.%03d",
                 cpi_milli / 1000, cpi_milli % 1000);
        $display("NOTE: ITERATIONS=1 is a smoke test, not an official score");
        $stop;
    end
endmodule
