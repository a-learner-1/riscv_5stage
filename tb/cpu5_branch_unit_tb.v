`timescale 1ns/1ps
module cpu5_branch_unit_tb;
    reg [31:0] instr, pc, rs1_value, rs2_value;
    wire supported, is_branch, is_jal, is_jalr, uses_rs1, uses_rs2, writes_rd;
    wire [4:0] rs1, rs2, rd;
    wire [31:0] imm, target, actual_next_pc, link_value;
    wire taken, misaligned;
    reg test_pass = 0;
    integer checks = 0, known_checks = 0;
    integer bchecks = 0, jchecks = 0, jrchecks = 0, unsupported_checks = 0;
    integer taken_checks = 0, not_taken_checks = 0, misaligned_checks = 0;
    integer i, j, k, offset, kind;
    reg [31:0] state = 32'hc501_5a41;
    reg [31:0] enc, a, b, p;
    integer summary_file;
    cpu5_branch_unit dut (.*);

    function [31:0] random_word;
        input [31:0] old;
        reg [31:0] x;
        begin
            x = old ^ (old << 13);
            x = x ^ (x >> 17);
            random_word = x ^ (x << 5);
        end
    endfunction
    function [31:0] corner;
        input integer index;
        begin
            case (index % 8)
                0: corner = 32'h0000_0000;
                1: corner = 32'h0000_0001;
                2: corner = 32'hffff_ffff;
                3: corner = 32'h8000_0000;
                4: corner = 32'h7fff_ffff;
                5: corner = 32'h8000_0001;
                6: corner = 32'hffff_fffe;
                7: corner = 32'h0000_0002;
            endcase
        end
    endfunction
    // Encoders consume signed byte offsets. The oracle below receives the
    // original offset and does not reconstruct it from the encoded fields.
    function [31:0] encode_b;
        input integer delta, funct3, s1, s2;
        reg [12:0] bits;
        begin
            bits = delta;
            encode_b = (bits[12] << 31) | (bits[10:5] << 25) |
                       (s2 << 20) | (s1 << 15) | (funct3 << 12) |
                       (bits[4:1] << 8) | (bits[11] << 7) | 32'h63;
        end
    endfunction
    function [31:0] encode_j;
        input integer delta, dest;
        reg [20:0] bits;
        begin
            bits = delta;
            encode_j = (bits[20] << 31) | (bits[10:1] << 21) |
                       (bits[11] << 20) | (bits[19:12] << 12) |
                       (dest << 7) | 32'h6f;
        end
    endfunction
    function [31:0] encode_jr;
        input integer delta, funct3, s1, dest;
        reg [11:0] bits;
        begin
            bits = delta;
            encode_jr = (bits << 20) | (s1 << 15) | (funct3 << 12) |
                        (dest << 7) | 32'h67;
        end
    endfunction
    function legal_b;
        input integer f;
        begin legal_b = (f == 0 || f == 1 || f == 4 || f == 5 || f == 6 || f == 7); end
    endfunction
    function signed_less;
        input [31:0] lhs, rhs;
        // Use sign-bit ordering plus unsigned magnitude, independently of the
        // RTL's signed operators.
        begin signed_less = lhs[31] != rhs[31] ? lhs[31] : lhs < rhs; end
    endfunction

    task check;
        input [31:0] word, address, lhs, rhs;
        input integer expected_kind, funct3, signed_delta;
        reg etaken, eless, emisaligned;
        reg [31:0] etarget, enext, eimm;
        reg [4:0] erd;
        reg [15:0] expected_control, actual_control;
        begin
            instr = word; pc = address; rs1_value = lhs; rs2_value = rhs;
            etaken = 0; eimm = expected_kind == 0 ? 0 : signed_delta;
            erd = (expected_kind == 2 || expected_kind == 3) ? word[11:7] : 0;
            eless = signed_less(lhs, rhs);
            if (expected_kind == 1) begin
                case (funct3)
                    0: etaken = lhs == rhs;
                    1: etaken = lhs != rhs;
                    4: etaken = eless;
                    5: etaken = !eless;
                    6: etaken = lhs < rhs;
                    7: etaken = !(lhs < rhs);
                    default: $fatal(1, "oracle branch kind has invalid funct3");
                endcase
            end
            if (expected_kind == 2 || expected_kind == 3) etaken = 1;
            etarget = expected_kind == 0 ? address + 4 :
                      expected_kind == 3 ? ((lhs + eimm) & 32'hffff_fffe) : address + eimm;
            enext = etaken ? etarget : address + 4;
            emisaligned = etaken && (etarget % 4 != 0);
            expected_control = {7'd0, expected_kind != 0, expected_kind == 1,
                                expected_kind == 2, expected_kind == 3,
                                (expected_kind == 1 || expected_kind == 3),
                                expected_kind == 1,
                                ((expected_kind == 2 || expected_kind == 3) && erd != 0),
                                etaken, emisaligned};
            #1;
            actual_control = {7'd0, supported, is_branch, is_jal, is_jalr,
                              uses_rs1, uses_rs2, writes_rd, taken, misaligned};
            if (actual_control !== expected_control || rs1 !== word[19:15] ||
                rs2 !== word[24:20] || rd !== erd || imm !== eimm ||
                target !== etarget || actual_next_pc !== enext || link_value !== address + 32'd4)
                $fatal(1, "branch check %0d word=%08x pc=%08x a=%08x b=%08x kind=%0d f3=%0d delta=%0d ctrl=%04x/%04x rd=%0d/%0d imm=%08x/%08x target=%08x/%08x next=%08x/%08x link=%08x",
                       checks, word, address, lhs, rhs, expected_kind, funct3, signed_delta,
                       actual_control, expected_control, rd, erd, imm, eimm, target,
                       etarget, actual_next_pc, enext, link_value);
            checks = checks + 1;
            if (expected_kind == 0) unsupported_checks = unsupported_checks + 1;
            if (expected_kind == 1) bchecks = bchecks + 1;
            if (expected_kind == 2) jchecks = jchecks + 1;
            if (expected_kind == 3) jrchecks = jrchecks + 1;
            if (etaken) taken_checks = taken_checks + 1;
            else not_taken_checks = not_taken_checks + 1;
            if (emisaligned) misaligned_checks = misaligned_checks + 1;
        end
    endtask

    initial begin
        instr=0; pc=0; rs1_value=0; rs2_value=0;
        // Hand-written machine words: these do not use the encoders above.
        check(32'h0000_0463,32'h100,0,0,1,0,8); // BEQ x0,x0,+8
        check(32'h0020_9463,32'h100,1,2,1,1,8); // BNE x1,x2,+8
        check(32'h0020_c463,32'h100,32'h80000000,0,1,4,8);
        check(32'h0020_d463,32'h100,32'h80000000,0,1,5,8);
        check(32'h0020_e463,32'h100,32'h80000000,0,1,6,8);
        check(32'h0020_f463,32'h100,32'h80000000,0,1,7,8);
        check(32'hfe20_8ee3,32'h100,2,2,1,0,-4);
        check(32'h8000_0063,32'h100,0,0,1,0,-4096);
        check(32'h7e00_0fe3,32'h100,0,0,1,0,4094);
        check(32'h0080_00ef,32'h100,0,0,2,0,8);
        check(32'h0000_006f,32'h100,0,0,2,0,0);
        check(32'hffdf_f0ef,32'h100,0,0,2,0,-4);
        check(32'h8000_00ef,32'h100,0,0,2,0,-1048576);
        check(32'h7fff_f0ef,32'h100,0,0,2,0,1048574);
        check(32'h0001_00e7,32'h100,32'h101,0,3,0,0);
        check(32'h0010_8067,32'h100,32'h101,0,3,0,1);
        check(32'h8003_02e7,32'h100,32'h801,0,3,0,-2048);
        check(32'h7ff3_02e7,32'hfffffffc,1,0,3,0,2047);
        check(32'h0001_10e7,32'h100,0,0,0,1,0); // invalid JALR funct3
        check(32'h0020_a463,32'h100,0,0,0,2,0); // reserved branch funct3
        check(32'h0020_b463,32'h100,0,0,0,3,0);
        check(32'h0000_0013,32'hfffffffc,0,0,0,0,0); // ordinary ADDI
        known_checks = checks;

        // Every B immediate and every funct3, including both reserved values.
        // Cycling signed boundary operands and PC alignment exercises both
        // taken and untaken misaligned targets (only taken is an error).
        for (offset=-4096; offset<=4094; offset=offset+2) begin
            for (i=0; i<8; i=i+1) begin
                j = (offset+4096)/2;
                a = corner(j); b = corner(j/8);
                p = 32'hffff_f000 + (j % 4);
                enc = encode_b(offset,i,j%32,(j/32)%32);
                check(enc,p,a,b,legal_b(i)?1:0,i,offset);
            end
        end
        // Every I immediate and every JALR funct3; odd bases check bit-zero
        // clearing, and rd=x0 must suppress the architectural write.
        for (offset=-2048; offset<=2047; offset=offset+1) begin
            for (i=0; i<8; i=i+1) begin
                j = offset+2048;
                check(encode_jr(offset,i,j%32,(j/32)%32),corner(j),corner(j/8),0,
                      i==0?3:0,i,offset);
            end
        end
        // Boundary PCs/operands crossed with all branch relations.
        for (i=0; i<8; i=i+1)
            for (j=0; j<8; j=j+1)
                for (k=0; k<8; k=k+1)
                    check(encode_b(2,k,31,30),corner(i),corner(i),corner(j),legal_b(k)?1:0,k,2);
        // Random J immediates and wrap-around additions. The offset is sampled
        // as an integer first, then encoded; the reference retains that value.
        for (i=0; i<10000; i=i+1) begin
            state=random_word(state); offset=(state%1048576)*2-1048576;
            state=random_word(state); p=state;
            check(encode_j(offset,i%32),p,0,0,2,0,offset);
        end
        // All opcodes other than the three control-flow opcodes, for all
        // funct3 values, must have zero controls and a sequential next PC.
        for (i=0; i<128; i=i+1) begin
            if (i!=99 && i!=103 && i!=111) begin
                for (j=0; j<8; j=j+1) begin
                    state=random_word(state); enc=(state & 32'hffff_8f80) | (j<<12) | i;
                    check(enc,corner(j),state,~state,0,j,0);
                end
            end
        end
        summary_file=$fopen("build/cpu5_s4_branch_unit/verification.json","w");
        $fdisplay(summary_file,"{\"checks\":%0d,\"hand_encoded_checks\":%0d,\"branch_checks\":%0d,\"jal_checks\":%0d,\"jalr_checks\":%0d,\"unsupported_checks\":%0d,\"taken_checks\":%0d,\"not_taken_checks\":%0d,\"misaligned_taken_checks\":%0d,\"pass\":true}",checks,known_checks,bchecks,jchecks,jrchecks,unsupported_checks,taken_checks,not_taken_checks,misaligned_checks);
        $fclose(summary_file);
        $display("CPU5 BRANCH UNIT PASS checks=%0d hand=%0d B=%0d JAL=%0d JALR=%0d unsupported=%0d taken=%0d not_taken=%0d misaligned=%0d",checks,known_checks,bchecks,jchecks,jrchecks,unsupported_checks,taken_checks,not_taken_checks,misaligned_checks);
        test_pass=1;
        $stop;
    end
endmodule
