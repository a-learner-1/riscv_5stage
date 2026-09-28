`timescale 1ns/1ps
module subword_mem_tb;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    wire [31:0] pc_x, instr_x, wb_pc, wb_data;
    wire valid_x, wb_we;
    wire [4:0] wb_rd;
    integer loads, stores, cycles;

    cpu_top dut (
        .clk(clk), .rst_n(rst_n),
        .pc_x(pc_x), .instr_x(instr_x), .valid_x(valid_x),
        .wb_pc(wb_pc), .wb_rd(wb_rd), .wb_data(wb_data), .wb_we(wb_we),
        .retire_valid(), .cycle_count(), .instret_count()
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

    task check_load_value;
        input [31:0] expected;
        begin
            if (dut.load_data_x !== expected)
                $fatal(1, "load pc=%0d got=%h expected=%h addr=%h",
                       pc_x, dut.load_data_x, expected, dut.mem_addr_x);
        end
    endtask

    always @(posedge clk) begin
        #1;
        if (rst_n && valid_x && pc_x >= 32'd928) begin
            if (pc_x == 32'd1120 || pc_x == 32'd1132)
                $fatal(1, "wrong-path memory instruction executed at pc=%0d", pc_x);

            if (dut.is_load_x) begin
                loads = loads + 1;
                if (dut.mem_access_ok_x !== 1'b1)
                    $fatal(1, "legal load rejected at pc=%0d", pc_x);
                case (pc_x)
                    32'd944:  check_load_value(32'h00000001);
                    32'd948:  check_load_value(32'h0000007f);
                    32'd952:  check_load_value(32'hffffffff);
                    32'd956:  check_load_value(32'hffffff80);
                    32'd960:  check_load_value(32'h000000ff);
                    32'd964:  check_load_value(32'h00000080);
                    32'd968:  check_load_value(32'h00007f01);
                    32'd972:  check_load_value(32'hffff80ff);
                    32'd976:  check_load_value(32'h000080ff);
                    32'd1000: check_load_value(32'h1122aa44);
                    32'd1012: check_load_value(32'hfe22aa44);
                    32'd1020: check_load_value(32'h0000fffe);
                    32'd1024: check_load_value(32'hfffffffe);
                    32'd1040: check_load_value(32'h8001fffe);
                    32'd1064: check_load_value(32'h00000055);
                    32'd1072: check_load_value(32'h00000055);
                    32'd1084: check_load_value(32'h800155aa);
                    32'd1096: check_load_value(32'h000000aa);
                    32'd1108: check_load_value(32'h00008001);
                    32'd1124: check_load_value(32'h00000000);
                    32'd1136: check_load_value(32'hffffff80);
                    default: $fatal(1, "unexpected load pc=%0d", pc_x);
                endcase
            end

            if (dut.is_store_x) begin
                stores = stores + 1;
                if (dut.mem_access_ok_x !== 1'b1)
                    $fatal(1, "legal store rejected at pc=%0d", pc_x);
                if (dut.is_sb_x && dut.mem_wstrb_x !== (4'b0001 << dut.mem_addr_x[1:0]))
                    $fatal(1, "SB byte strobe mismatch pc=%0d", pc_x);
                if (dut.is_sh_x && dut.mem_wstrb_x !== (4'b0011 << dut.mem_addr_x[1:0]))
                    $fatal(1, "SH byte strobe mismatch pc=%0d", pc_x);
                if (dut.is_sw_x && dut.mem_wstrb_x !== 4'b1111)
                    $fatal(1, "SW byte strobe mismatch pc=%0d", pc_x);
            end

            if (pc_x == 32'd940 && dut.forward_rs2_x !== 1'b1)
                $fatal(1, "SW data forwarding missing");
            if (pc_x == 32'd1052 && dut.forward_rs1_x !== 1'b1)
                $fatal(1, "SB address forwarding missing");
            if (pc_x == 32'd1060 && dut.forward_rs2_x !== 1'b1)
                $fatal(1, "SB data forwarding missing");
            if (pc_x == 32'd1068 && dut.forward_rs2_x !== 1'b1)
                $fatal(1, "load-to-store forwarding missing");
            if (pc_x == 32'd1076 && dut.forward_rs1_x !== 1'b1)
                $fatal(1, "load-use forwarding missing");
        end
    end

    initial begin
        loads = 0; stores = 0; cycles = 0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        while (!(wb_pc == 32'd1140 && wb_we && wb_rd == 5'd31)) begin
            @(posedge clk); #1;
            cycles = cycles + 1;
            if (cycles > 600) $fatal(1, "subword integration timeout");
        end
        // One more edge commits the final EX/WB value into the register file.
        @(posedge clk); #1;

        check_reg(5'd1,  32'h00000040);
        check_reg(5'd2,  32'h80ff7f01);
        check_reg(5'd3,  32'h00000001);
        check_reg(5'd4,  32'h0000007f);
        check_reg(5'd5,  32'hffffffff);
        check_reg(5'd6,  32'hffffff80);
        check_reg(5'd7,  32'h000000ff);
        check_reg(5'd8,  32'h00000080);
        check_reg(5'd9,  32'h00007f01);
        check_reg(5'd10, 32'hffff80ff);
        check_reg(5'd11, 32'h000080ff);
        check_reg(5'd12, 32'h11223344);
        check_reg(5'd13, 32'h000000aa);
        check_reg(5'd14, 32'hfe22aa44);
        check_reg(5'd15, 32'hfffffffe);
        check_reg(5'd16, 32'h0000fffe);
        check_reg(5'd17, 32'hfffffffe);
        check_reg(5'd18, 32'h00008001);
        check_reg(5'd19, 32'h8001fffe);
        check_reg(5'd20, 32'h00000048);
        check_reg(5'd21, 32'h00000055);
        check_reg(5'd22, 32'h00000055);
        check_reg(5'd23, 32'h00000055);
        check_reg(5'd24, 32'h00000056);
        check_reg(5'd25, 32'h800155aa);
        check_reg(5'd26, 32'h000003ff);
        check_reg(5'd27, 32'h000000aa);
        check_reg(5'd28, 32'h000003fe);
        check_reg(5'd29, 32'h00008001);
        check_reg(5'd30, 32'h00000000);
        check_reg(5'd31, 32'h00000009);

        if (dut.u_data_mem.mem[16] !== 32'h80ff7f01) $fatal(1, "memory[64] mismatch");
        if (dut.u_data_mem.mem[17] !== 32'h8001fffe) $fatal(1, "memory[68] mismatch");
        if (dut.u_data_mem.mem[18] !== 32'h800155aa) $fatal(1, "memory[72] mismatch");
        if (dut.u_data_mem.mem[19] !== 32'h00000000) $fatal(1, "squashed SB modified memory[76]");
        if (dut.u_data_mem.mem[255] !== 32'h8001ffff) $fatal(1, "last RAM word mismatch");
        if (loads !== 21 || stores !== 14)
            $fatal(1, "memory operation count loads=%0d stores=%0d", loads, stores);

        $display("PASS: LB/LBU/LH/LHU/SB/SH signedness, little-endian lanes and boundaries");
        $display("PASS: subword forwarding, x0 suppression and branch/jump squash");
        $display("PASS: CPU subword memory integration, 54 instructions");
        $stop;
    end
endmodule
