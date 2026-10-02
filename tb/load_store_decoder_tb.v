`timescale 1ns/1ps
module load_store_decoder_tb;
    reg [31:0] instr;
    wire is_lb, is_lh, is_lw, is_lbu, is_lhu;
    wire is_sb, is_sh, is_sw;
    wire [31:0] imm_i, imm_s;
    integer f;

    decoder dut (
        .instr(instr), .rs1_addr(), .rs2_addr(), .rd_addr(),
        .imm_i(imm_i), .imm_u(), .imm_b(), .imm_j(), .imm_s(imm_s),
        .is_addi(), .is_add(), .is_sub(), .is_and(), .is_or(), .is_xor(),
        .is_andi(), .is_ori(), .is_xori(),
        .is_sll(), .is_srl(), .is_sra(),
        .is_slli(), .is_srli(), .is_srai(),
        .is_slt(), .is_sltu(), .is_slti(), .is_sltiu(),
        .is_lui(), .is_auipc(),
        .is_beq(), .is_bne(), .is_blt(), .is_bge(), .is_bltu(), .is_bgeu(),
        .is_jal(), .is_jalr(),
        .is_lb(is_lb), .is_lh(is_lh), .is_lw(is_lw),
        .is_lbu(is_lbu), .is_lhu(is_lhu),
        .is_sb(is_sb), .is_sh(is_sh), .is_sw(is_sw),
        .is_fence(), .is_ecall(), .is_ebreak(), .is_mret(), .is_csr()
    );

    task check_load;
        input [2:0] funct3;
        input [4:0] expected;
        reg [4:0] actual;
        begin
            instr = 32'h00000003 | (funct3 << 12); #1;
            actual = {is_lbu, is_lhu, is_lw, is_lh, is_lb};
            if (actual !== expected)
                $fatal(1, "load funct3=%b decoded=%b expected=%b", funct3, actual, expected);
        end
    endtask

    task check_store;
        input [2:0] funct3;
        input [2:0] expected;
        reg [2:0] actual;
        begin
            instr = 32'h00000023 | (funct3 << 12); #1;
            actual = {is_sw, is_sh, is_sb};
            if (actual !== expected)
                $fatal(1, "store funct3=%b decoded=%b expected=%b", funct3, actual, expected);
        end
    endtask

    initial begin
        check_load(3'b000, 5'b00001);
        check_load(3'b001, 5'b00010);
        check_load(3'b010, 5'b00100);
        check_load(3'b011, 5'b00000);
        check_load(3'b100, 5'b10000);
        check_load(3'b101, 5'b01000);
        check_load(3'b110, 5'b00000);
        check_load(3'b111, 5'b00000);

        check_store(3'b000, 3'b001);
        check_store(3'b001, 3'b010);
        check_store(3'b010, 3'b100);
        for (f = 3; f < 8; f = f + 1) check_store(f[2:0], 3'b000);

        instr = 32'h80000083; #1;
        if (!is_lb || imm_i !== 32'hfffff800) $fatal(1, "LB -2048 immediate");
        instr = 32'h7ff05083; #1;
        if (!is_lhu || imm_i !== 32'd2047) $fatal(1, "LHU +2047 immediate");
        instr = 32'h80100023; #1;
        if (!is_sb || imm_s !== 32'hfffff800) $fatal(1, "SB -2048 immediate");
        instr = 32'h7e101fa3; #1;
        if (!is_sh || imm_s !== 32'd2047) $fatal(1, "SH +2047 immediate");
        instr = 32'h00002013; #1;
        if ({is_lb,is_lh,is_lw,is_lbu,is_lhu,is_sb,is_sh,is_sw} !== 8'd0)
            $fatal(1, "non-memory opcode decoded as memory access");

        $display("PASS: LB/LBU/LH/LHU/LW and SB/SH/SW decoder legality and immediates");
        $stop;
    end
endmodule
