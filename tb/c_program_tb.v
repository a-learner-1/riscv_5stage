`timescale 1ns/1ps
module c_program_tb;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    wire [31:0] pc_x, instr_x, wb_pc, wb_data;
    wire valid_x, wb_we;
    wire [4:0] wb_rd;
    integer cycles;

    localparam integer TOHOST_WORD = 4095;

    cpu_top #(
        .PROGRAM_FILE("programs/c_demo.hex"),
        .DATA_FILE("programs/c_demo_data.hex"),
        .IMEM_WORDS(8192),
        .DMEM_WORDS(4096),
        .DMEM_BASE_ADDR(32'h00010000)
    ) dut (
        .clk(clk), .rst_n(rst_n), .uart_rx(1'b1),
        .pc_x(pc_x), .instr_x(instr_x), .valid_x(valid_x),
        .wb_pc(wb_pc), .wb_rd(wb_rd), .wb_data(wb_data), .wb_we(wb_we),
        .retire_valid(), .cycle_count(), .instret_count(), .gpio_in(8'd0), .gpio_out(), .gpio_oe(), .uart_tx()
    );

    always #5 clk = ~clk;

    initial begin
        cycles = 0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        while ((dut.u_data_mem.mem[TOHOST_WORD] !== 32'd1) &&
               (dut.u_data_mem.mem[TOHOST_WORD] !== 32'd2) &&
               (dut.u_data_mem.mem[TOHOST_WORD] !== 32'd3) &&
               (dut.u_data_mem.mem[TOHOST_WORD] !== 32'd4)) begin
            @(posedge clk);
            #1;
            cycles = cycles + 1;
            if (cycles > 1000)
                $fatal(1, "C program timeout pc=%h instr=%h", pc_x, instr_x);
        end

        if (dut.u_data_mem.mem[TOHOST_WORD] !== 32'd1)
            $fatal(1, "C program reported failure code=%h",
                   dut.u_data_mem.mem[TOHOST_WORD]);
        if (dut.u_data_mem.mem[0] !== 32'h12345678)
            $fatal(1, "Initialized .data word was not loaded correctly: %h",
                   dut.u_data_mem.mem[0]);

        $display("PASS: freestanding C program completed through tohost");
        $display("PASS: separate instruction/data HEX images checked");
        $display("PASS: tohost=1 cycles=%0d", cycles);
        $stop;
    end
endmodule
