`timescale 1ns/1ps
module load_store_decoder_tb;
    reg [31:0] instr;
    wire is_lw,is_sw;
    wire [31:0] imm_i,imm_s;
    integer f;
    decoder dut(.instr(instr),
        .rs1_addr(),
        .rs2_addr(),
        .rd_addr(),
        .imm_i(imm_i),
        .imm_u(),
        .imm_b(),
        .imm_j(),
        .is_addi(),
        .is_add(),
        .is_sub(),
        .is_and(),
        .is_or(),
        .is_xor(),
        .is_andi(),
        .is_ori(),
        .is_xori(),
        .is_sll(),
        .is_srl(),
        .is_sra(),
        .is_slli(),
        .is_srli(),
        .is_srai(),
        .is_slt(),
        .is_sltu(),
        .is_slti(),
        .is_sltiu(),
        .is_lui(),
        .is_auipc(),
        .is_beq(),
        .is_bne(),
        .is_blt(),
        .is_bge(),
        .is_bltu(),
        .is_bgeu(),
        .is_jal(),
        .is_jalr(),
        .is_lw(is_lw),
        .is_sw(is_sw),
        .imm_s(imm_s));
    initial begin
        for(f=0;f<8;f=f+1) begin
            instr=32'h00000003 | (f<<12); #1;
            if (is_lw !== (f==2) || is_sw !== 0) $fatal(1,"Load funct3 decode");
            instr=32'h00000023 | (f<<12); #1;
            if (is_sw !== (f==2) || is_lw !== 0) $fatal(1,"Store funct3 decode");
        end
        instr=32'h80002083; #1;
        if(is_lw !== 1 || imm_i !== 32'hfffff800) $fatal(1,"LW -2048 immediate");
        instr=32'h7ff02083; #1;
        if(is_lw !== 1 || imm_i !== 2047) $fatal(1,"LW +2047 immediate");
        instr=32'h80102023; #1;
        if(is_sw !== 1 || imm_s !== 32'hfffff800) $fatal(1,"SW -2048 immediate");
        instr=32'h7e102fa3; #1;
        if(is_sw !== 1 || imm_s !== 2047) $fatal(1,"SW +2047 immediate");
        instr=32'h00002013; #1;
        if(is_sw !== 0 || is_lw !== 0) $fatal(1,"Wrong opcode decoded as memory");
        $display("PASS: LW/SW decoder 21 cases, legal widths and signed I/S immediates");
        $stop;
    end
endmodule
