`timescale 1ns/1ps

module jump_tb;
    reg clk;
    reg rst_n;
    wire [31:0] pc_x, instr_x, wb_pc, wb_data;
    wire valid_x, wb_we;
    wire [4:0] wb_rd;

    localparam integer STEPS = 25;
    reg [31:0] exp_pc [0:STEPS-1];
    reg [31:0] exp_instr [0:STEPS-1];
    reg exp_valid [0:STEPS-1];
    reg exp_redirect [0:STEPS-1];
    reg [31:0] exp_target [0:STEPS-1];
    integer i, warm;

    cpu_top dut (
        .clk(clk), .rst_n(rst_n), .uart_rx(1'b1), .pc_x(pc_x), .instr_x(instr_x),
        .valid_x(valid_x), .wb_pc(wb_pc), .wb_rd(wb_rd),
        .wb_data(wb_data), .wb_we(wb_we),
        .retire_valid(), .cycle_count(), .instret_count(), .gpio_in(8'd0), .gpio_out(), .gpio_oe(), .uart_tx(),
        .imem_req_valid(), .imem_req_ready(1'b0), .imem_req_addr(),
        .imem_rsp_valid(1'b0), .imem_rsp_ready(), .imem_rsp_rdata(32'd0),
        .imem_rsp_error(1'b0), .imem_fault(), .imem_fault_pc(),
        .dmem_req_valid(), .dmem_req_ready(1'b0), .dmem_req_write(),
        .dmem_req_addr(), .dmem_req_size(), .dmem_req_wdata(), .dmem_req_wstrb(),
        .dmem_rsp_valid(1'b0), .dmem_rsp_ready(), .dmem_rsp_rdata(32'd0),
        .dmem_rsp_error(1'b0), .dmem_fault()
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task step;
        input integer n;
        input [31:0] pc, insn;
        input valid, redirect;
        input [31:0] target;
        begin
            exp_pc[n] = pc;
            exp_instr[n] = insn;
            exp_valid[n] = valid;
            exp_redirect[n] = redirect;
            exp_target[n] = target;
        end
    endtask

    initial begin
        rst_n = 1'b0;
        // The trace includes the one-cycle bubble after each redirect.
        step( 0, 408, 32'h008002ef, 1, 1, 416); // jal x5, +8
        step( 1, 412, 32'h00000013, 0, 0,   0); // x16 poison squashed
        step( 2, 416, 32'h00128413, 1, 0,   0); // x8 = link + 1
        step( 3, 420, 32'h1b500313, 1, 0,   0); // x6 = 437
        step( 4, 424, 32'h000303e7, 1, 1, 436); // jalr x7, 0(x6)
        step( 5, 428, 32'h00000013, 0, 0,   0);
        step( 6, 436, 32'h00138a93, 1, 0,   0); // x21 = link + 1
        step( 7, 440, 32'h0080006f, 1, 1, 448); // jal x0, +8
        step( 8, 444, 32'h00000013, 0, 0,   0);
        step( 9, 448, 32'h00600b13, 1, 0,   0);
        step(10, 452, 32'h00000497, 1, 0,   0); // auipc x9, 0
        step(11, 456, 32'h00d48067, 1, 1, 464); // 452+13=465; clear bit 0
        step(12, 460, 32'h00000013, 0, 0,   0);
        step(13, 464, 32'h00200513, 1, 0,   0);
        step(14, 468, 32'h00000593, 1, 0,   0);
        step(15, 472, 32'h00158593, 1, 0,   0); // x11 = 1
        step(16, 476, 32'h00a58663, 1, 0,   0); // BEQ not taken
        step(17, 480, 32'hff9ff66f, 1, 1, 472); // jal x12, -8
        step(18, 484, 32'h00000013, 0, 0,   0);
        step(19, 472, 32'h00158593, 1, 0,   0); // x11 = 2
        step(20, 476, 32'h00a58663, 1, 1, 488); // BEQ taken, squash JAL
        step(21, 480, 32'h00000013, 0, 0,   0);
        step(22, 488, 32'h00b606b3, 1, 0,   0); // x13 = 484 + 2
        step(23, 492, 32'h00000013, 1, 0,   0);
        step(24, 496, 32'h00000013, 1, 0,   0);

        #11;
        rst_n = 1'b1;
        warm = 0;
        while ((pc_x !== 32'd408 || valid_x !== 1'b1) && warm < 150) begin
            tick;
            warm = warm + 1;
        end
        if (warm == 150) $fatal(1, "Jump program was not reached");

        for (i=0; i<STEPS; i=i+1) begin
            if (pc_x !== exp_pc[i] || instr_x !== exp_instr[i] ||
                valid_x !== exp_valid[i] ||
                dut.redirect_x !== exp_redirect[i]) begin
                $display("FAIL step=%0d pc=%h instr=%h valid=%b redirect=%b",
                         i, pc_x, instr_x, valid_x, dut.redirect_x);
                $fatal(1, "Jump EX trace mismatch");
            end
            if (exp_redirect[i] && dut.redirect_pc_x !== exp_target[i])
                $fatal(1, "Wrong redirect target at PC=%0d", pc_x);
            if (exp_valid[i] && (instr_x[6:0] == 7'h6f ||
                                 instr_x[6:0] == 7'h67)) begin
                if (!dut.writes_rd_x || dut.uses_rs2_x || dut.forward_rs2_x ||
                    (instr_x[6:0] == 7'h6f && dut.uses_rs1_x) ||
                    (instr_x[6:0] == 7'h67 && !dut.uses_rs1_x))
                    $fatal(1, "Jump source/write-enable decode mismatch at PC=%0d", pc_x);
            end
            if (i == 4 || i == 11)
                if (!dut.forward_rs1_x)
                    $fatal(1, "JALR base register was not forwarded at PC=%0d", pc_x);
            if (i == 17 && dut.imm_j_x !== 32'hfffffff8)
                $fatal(1, "Backward JAL immediate was not sign extended");
            if (wb_we && (wb_pc == 412 || wb_pc == 428 || wb_pc == 432 ||
                          wb_pc == 444 || wb_pc == 460 || wb_pc == 484))
                $fatal(1, "Wrong-path instruction committed at PC=%0d", wb_pc);
            if (i > 0 && exp_valid[i-1] &&
                (exp_instr[i-1][6:0] == 7'h6f || exp_instr[i-1][6:0] == 7'h67)) begin
                if (wb_pc !== exp_pc[i-1] || wb_data !== exp_pc[i-1]+32'd4 ||
                    wb_rd !== exp_instr[i-1][11:7] ||
                    wb_we !== (exp_instr[i-1][11:7] != 5'd0))
                    $fatal(1, "Jump link writeback mismatch at PC=%0d", exp_pc[i-1]);
            end
            tick;
        end

        if (dut.u_regfile.regs[5] !== 412 ||
            dut.u_regfile.regs[6] !== 437 ||
            dut.u_regfile.regs[7] !== 428 ||
            dut.u_regfile.regs[8] !== 413 ||
            dut.u_regfile.regs[9] !== 452 ||
            dut.u_regfile.regs[10] !== 2 ||
            dut.u_regfile.regs[11] !== 2 ||
            dut.u_regfile.regs[12] !== 484 ||
            dut.u_regfile.regs[13] !== 486 ||
            dut.u_regfile.regs[16] !== 0 ||
            dut.u_regfile.regs[19] !== 1 ||
            dut.u_regfile.regs[20] !== 1 ||
            dut.u_regfile.regs[21] !== 429 ||
            dut.u_regfile.regs[22] !== 6 ||
            dut.u_regfile.regs[24] !== 32) begin
            $display("regs x0=%h x5=%h x6=%h x7=%h x8=%h x9=%h x10=%h x11=%h x12=%h x13=%h x16=%h x19=%h x20=%h x21=%h x22=%h x24=%h",
                     dut.u_regfile.regs[0], dut.u_regfile.regs[5],
                     dut.u_regfile.regs[6], dut.u_regfile.regs[7],
                     dut.u_regfile.regs[8], dut.u_regfile.regs[9],
                     dut.u_regfile.regs[10], dut.u_regfile.regs[11],
                     dut.u_regfile.regs[12], dut.u_regfile.regs[13],
                     dut.u_regfile.regs[16], dut.u_regfile.regs[19],
                     dut.u_regfile.regs[20], dut.u_regfile.regs[21],
                     dut.u_regfile.regs[22], dut.u_regfile.regs[24]);
            $fatal(1, "Jump final register or wrong-path squash mismatch");
        end

        $display("PASS: JAL/JALR link, forwarding, bit-0 clear, backward jump and squash");
        $display("PASS: original 77 instructions and BEQ/BNE segment preserved");
        $stop;
    end

    initial begin
        #2000;
        $fatal(1, "Jump test timeout");
    end
endmodule
