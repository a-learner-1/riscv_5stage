`timescale 1ns/1ps
module program_load_tb;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    wire [31:0] pc_x, instr_x, wb_pc, wb_data;
    wire valid_x, wb_we;
    wire [4:0] wb_rd;
    integer cycles, loads, stores;

    cpu_top #(
        .PROGRAM_FILE("programs/program_load_test.hex"),
        .IMEM_WORDS(16)
    ) dut (
        .clk(clk), .rst_n(rst_n), .uart_rx(1'b1),
        .pc_x(pc_x), .instr_x(instr_x), .valid_x(valid_x),
        .wb_pc(wb_pc), .wb_rd(wb_rd), .wb_data(wb_data), .wb_we(wb_we),
        .retire_valid(), .cycle_count(), .instret_count(), .gpio_in(8'd0), .gpio_out(), .gpio_oe(), .uart_tx()
    );

    always #5 clk = ~clk;

    task check_reg;
        input [4:0] index;
        input [31:0] expected;
        begin
            if (dut.u_regfile.regs[index] !== expected)
                $fatal(1, "x%0d got=%h expected=%h",
                       index, dut.u_regfile.regs[index], expected);
        end
    endtask

    always @(posedge clk) begin
        #1;
        if (rst_n && valid_x) begin
            if (pc_x == 32'd28 || pc_x == 32'd36)
                $fatal(1, "wrong-path instruction executed at pc=%0d", pc_x);
            if (dut.load_issue_x) loads = loads + 1;
            if (dut.is_store_x) stores = stores + 1;
            if (pc_x == 32'd4 && dut.forward_rs1_x !== 1'b1)
                $fatal(1, "ALU forwarding missing");
            if (pc_x == 32'd20 && dut.forward_rs1_x !== 1'b1)
                $fatal(1, "LW-use forwarding missing");
            if (pc_x == 32'd48 && dut.forward_rs1_x !== 1'b1)
                $fatal(1, "LBU-use forwarding missing");
        end
    end

    initial begin
        cycles = 0; loads = 0; stores = 0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        while (!(wb_pc == 32'd48 && wb_we && wb_rd == 5'd10)) begin
            @(posedge clk); #1;
            cycles = cycles + 1;
            if (cycles > 80) $fatal(1, "external program timeout");
        end
        // Commit the final EX/WB value to the register file.
        @(posedge clk); #1;

        check_reg(5'd1,  32'd5);
        check_reg(5'd2,  32'd8);
        check_reg(5'd3,  32'd13);
        check_reg(5'd4,  32'd13);
        check_reg(5'd5,  32'd14);
        check_reg(5'd7,  32'd36);
        check_reg(5'd9,  32'd14);
        check_reg(5'd10, 32'd15);
        if (dut.u_data_mem.mem[0] !== 32'h00000e0d)
            $fatal(1, "external program data memory mismatch: %h",
                   dut.u_data_mem.mem[0]);
        if (loads !== 2 || stores !== 2)
            $fatal(1, "memory operation count loads=%0d stores=%0d", loads, stores);

        $display("PASS: CPU executed external HEX program with ALU, memory, branch and jump");
        $display("PASS: external program forwarding and wrong-path squash checked");
        $stop;
    end
endmodule


