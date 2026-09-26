`timescale 1ns/1ps

module cpu_top_tb;

    reg         clk;
    reg         rst_n;

    wire [31:0] pc_x;
    wire [31:0] instr_x;
    wire        valid_x;
    wire [31:0] wb_pc;
    wire [4:0]  wb_rd;
    wire [31:0] wb_data;
    wire        wb_we;

    cpu_top dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .pc_x    (pc_x),
        .instr_x (instr_x),
        .valid_x (valid_x),
        .wb_pc   (wb_pc),
        .wb_rd   (wb_rd),
        .wb_data (wb_data),
        .wb_we   (wb_we)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    initial begin
        rst_n = 1'b0;
        #12 rst_n = 1'b1;

        // 15 ns edge: first ADDI enters EX.
        @(posedge clk);
        #1;
        if (valid_x !== 1'b1 ||
            pc_x !== 32'd0 ||
            instr_x !== 32'h00500093 ||
            wb_we !== 1'b0 ||
            dut.forward_rs1_x !== 1'b0 ||
            dut.alu_a_x !== 32'd0 ||
            dut.alu_b_x !== 32'd5 ||
            dut.alu_result_x !== 32'd5) begin
            $display("FAIL: first ADDI in EX");
            $fatal(1);
        end

        // 25 ns edge: second ADDI uses rs1 forwarding.
        @(posedge clk);
        #1;
        if (valid_x !== 1'b1 ||
            pc_x !== 32'd4 ||
            instr_x !== 32'h00308113 ||
            wb_we !== 1'b1 ||
            wb_pc !== 32'd0 ||
            wb_rd !== 5'd1 ||
            wb_data !== 32'd5 ||
            dut.forward_rs1_x !== 1'b1 ||
            dut.forward_rs2_x !== 1'b0 ||
            dut.alu_a_x !== 32'd5 ||
            dut.alu_b_x !== 32'd3 ||
            dut.alu_result_x !== 32'd8) begin
            $display("FAIL: second ADDI or rs1 forwarding");
            $fatal(1);
        end

        $display("PASS: ADDI rs1 forwarding, 5 + 3 = 8");

        // 35 ns edge: x1 is written.
        // ADD x3 reads x1 from regfile and forwards x2 from WB.
        @(posedge clk);
        #1;
        if (valid_x !== 1'b1 ||
            pc_x !== 32'd8 ||
            instr_x !== 32'h002081b3 ||
            dut.u_regfile.regs[1] !== 32'd5 ||
            wb_we !== 1'b1 ||
            wb_pc !== 32'd4 ||
            wb_rd !== 5'd2 ||
            wb_data !== 32'd8 ||
            dut.is_add_x !== 1'b1 ||
            dut.is_addi_x !== 1'b0 ||
            dut.forward_rs1_x !== 1'b0 ||
            dut.forward_rs2_x !== 1'b1 ||
            dut.rs1_data_x !== 32'd5 ||
            dut.rs2_value_x !== 32'd8 ||
            dut.alu_a_x !== 32'd5 ||
            dut.alu_b_x !== 32'd8 ||
            dut.alu_result_x !== 32'd13) begin
            $display("FAIL: ADD x3 or rs2 forwarding");
            $fatal(1);
        end

        $display("PASS: ADD rs2 forwarding, 5 + 8 = 13");

        // 45 ns edge: x2 is written; x3 result enters WB.
        // ADD x4, x3, x3 needs the same WB value on BOTH inputs.
        @(posedge clk);
        #1;
        if (valid_x !== 1'b1 ||
            pc_x !== 32'd12 ||
            instr_x !== 32'h00318233 ||
            dut.u_regfile.regs[1] !== 32'd5 ||
            dut.u_regfile.regs[2] !== 32'd8 ||
            wb_we !== 1'b1 ||
            wb_pc !== 32'd8 ||
            wb_rd !== 5'd3 ||
            wb_data !== 32'd13 ||
            dut.is_add_x !== 1'b1 ||
            dut.is_addi_x !== 1'b0 ||
            dut.rs1_addr_x !== 5'd3 ||
            dut.rs2_addr_x !== 5'd3 ||
            dut.rd_addr_x !== 5'd4 ||
            dut.forward_rs1_x !== 1'b1 ||
            dut.forward_rs2_x !== 1'b1 ||
            dut.rs2_value_x !== 32'd13 ||
            dut.alu_a_x !== 32'd13 ||
            dut.alu_b_x !== 32'd13 ||
            dut.alu_result_x !== 32'd26) begin
            $display("FAIL: simultaneous rs1 and rs2 forwarding");
            $display("WB: we=%b rd=%d data=%h",
                     wb_we, wb_rd, wb_data);
            $display("forward_rs1=%b forward_rs2=%b",
                     dut.forward_rs1_x, dut.forward_rs2_x);
            $display("ALU: a=%h b=%h result=%h",
                     dut.alu_a_x, dut.alu_b_x, dut.alu_result_x);
            $fatal(1);
        end

        $display("PASS: dual-source forwarding, 13 + 13 = 26");

        // 55 ns edge: x3 is written; x4 result enters WB.
        @(posedge clk);
        #1;
        if (dut.u_regfile.regs[1] !== 32'd5 ||
            dut.u_regfile.regs[2] !== 32'd8 ||
            dut.u_regfile.regs[3] !== 32'd13 ||
            wb_we !== 1'b1 ||
            wb_pc !== 32'd12 ||
            wb_rd !== 5'd4 ||
            wb_data !== 32'd26) begin
            $display("FAIL: x3 writeback or x4 result in WB");
            $fatal(1);
        end

        // 65 ns edge: x4 is written; NOP must not write.
        @(posedge clk);
        #1;
        if (dut.u_regfile.regs[1] !== 32'd5 ||
            dut.u_regfile.regs[2] !== 32'd8 ||
            dut.u_regfile.regs[3] !== 32'd13 ||
            dut.u_regfile.regs[4] !== 32'd26 ||
            wb_we !== 1'b0) begin
            $display("FAIL: final registers or NOP write enable");
            $display("x1=%h x2=%h x3=%h x4=%h",
                     dut.u_regfile.regs[1],
                     dut.u_regfile.regs[2],
                     dut.u_regfile.regs[3],
                     dut.u_regfile.regs[4]);
            $fatal(1);
        end

        $display("PASS: cpu_top dual-source test passed, x1=5, x2=8, x3=13, x4=26");
        $stop;
    end

endmodule