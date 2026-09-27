module if_stage (
    input  wire        clk,
    input  wire        rst_n,

    output reg  [31:0] pc_f,
    output reg  [31:0] pc_x,
    output reg  [31:0] instr_x,
    output reg         valid_x
);

    reg [31:0] instr_f;

    // Instruction ROM.
    always @(*) begin
        case (pc_f)
            32'd0:
                instr_f = 32'h00500093; // addi x1, x0, 5
            32'd4:
                instr_f = 32'h00308113; // addi x2, x1, 3
            32'd8:
                instr_f = 32'h002081b3; // add x3, x1, x2
            32'd12:
                instr_f = 32'h00318233; // add x4, x3, x3
            32'd16:
                instr_f = 32'h403202b3; // sub x5, x4, x3
            32'd20:
                instr_f = 32'h40508333; // sub x6, x1, x5
            32'd24:
                instr_f = 32'h004373b3; // and x7, x6, x4
            32'd28:
                instr_f = 32'h0070e433; // or x8, x1, x7
            32'd32:
                instr_f = 32'h007444b3; // xor x9, x8, x7

            32'd36:
                instr_f = 32'h0094f513; // andi x10, x9, 9
            32'd40:
                instr_f = 32'h00a56593; // ori x11, x10, 10
            32'd44:
                instr_f = 32'h00b5c613; // xori x12, x11, 11
            32'd48:
                instr_f = 32'hfff64693; // xori x13, x12, -1
            32'd52:
                instr_f = 32'h8006f713; // andi x14, x13, -2048
            32'd56:
                instr_f = 32'hfff76793; // ori x15, x14, -1

            32'd60: instr_f = 32'h00a79833; // sll x16, x15, x10
            32'd64: instr_f = 32'h00a858b3; // srl x17, x16, x10
            32'd68: instr_f = 32'h40a85933; // sra x18, x16, x10
            32'd72: instr_f = 32'h02100993; // addi x19, x0, 33
            32'd76: instr_f = 32'h41335a33; // sra x20, x6, x19
            32'd80: instr_f = 32'h01351ab3; // sll x21, x10, x19
            32'd84: instr_f = 32'h00aadb33; // srl x22, x21, x10
            32'd88: instr_f = 32'h016b1bb3; // sll x23, x22, x22
            32'd92: instr_f = 32'h02000c13; // addi x24, x0, 32
            32'd96: instr_f = 32'h01885cb3; // srl x25, x16, x24

            32'd100: instr_f = 32'h001c9d13; // slli x26, x25, 1
            32'd104: instr_f = 32'h001d5d93; // srli x27, x26, 1
            32'd108: instr_f = 32'h401d5e13; // srai x28, x26, 1
            32'd112: instr_f = 32'h01f51e93; // slli x29, x10, 31
            32'd116: instr_f = 32'h01fedf13; // srli x30, x29, 31
            32'd120: instr_f = 32'h41fedf93; // srai x31, x29, 31
            32'd124: instr_f = 32'h000f9d13; // slli x26, x31, 0
            32'd128: instr_f = 32'h000d5d93; // srli x27, x26, 0
            32'd132: instr_f = 32'h400dde13; // srai x28, x27, 0
            32'd136: instr_f = 32'h01ce1e93; // slli x29, x28, 28
            32'd140: instr_f = 32'h01dedf13; // srli x30, x29, 29
            32'd144: instr_f = 32'h41eedf93; // srai x31, x29, 30
            32'd148: instr_f = 32'h001f9013; // slli x0, x31, 1
            32'd152: instr_f = 32'h00106d13; // ori x26, x0, 1
            32'd156: instr_f = 32'h001d5d93; // srli x27, x26, 1
            32'd160: instr_f = 32'h401d5e13; // srai x28, x26, 1

            32'd164: instr_f = 32'h01afa0b3; // slt x1, x31, 26
            32'd168: instr_f = 32'h01afb133; // sltu x2, x31, 26
            32'd172: instr_f = 32'h000fa193; // slti x3, x31, 0
            32'd176: instr_f = 32'h000fb213; // sltiu x4, x31, 0
            32'd180: instr_f = 32'hfffdb293; // sltiu x5, x27, -1
            32'd184: instr_f = 32'hffffa313; // slti x6, x31, -1
            32'd188: instr_f = 32'h01d8a3b3; // slt x7, x17, 29
            32'd192: instr_f = 32'h01d8b433; // sltu x8, x17, 29
            32'd196: instr_f = 32'h800ea493; // slti x9, x29, -2048
            32'd200: instr_f = 32'h800eb513; // sltiu x10, x29, -2048
            32'd204: instr_f = 32'h001d2593; // slti x11, x26, 1
            32'd208: instr_f = 32'h001d3613; // sltiu x12, x26, 1
            32'd212: instr_f = 32'h01fd26b3; // slt x13, x26, 31
            32'd216: instr_f = 32'h01fd3733; // sltu x14, x26, 31
            32'd220: instr_f = 32'h01a727b3; // slt x15, x14, 26
            32'd224: instr_f = 32'h00f73833; // sltu x16, x14, 15
            32'd228: instr_f = 32'h010828b3; // slt x17, x16, 16
            32'd232: instr_f = 32'h0118b913; // sltiu x18, x17, 17
            32'd236: instr_f = 32'h01afa033; // slt x0, x31, 26
            32'd240: instr_f = 32'hffff3993; // sltiu x19, x30, -1
            32'd244: instr_f = 32'h7fff2a13; // slti x20, x30, 2047
            32'd248: instr_f = 32'h011eaab3; // slt x21, x29, 17

            32'd252: instr_f = 32'h115a80b7; // lui x1, 0x115a8
            32'd256: instr_f = 32'h00508113; // addi x2, x1, 5
            32'd260: instr_f = 32'h00000197; // auipc x3, 0x00000
            32'd264: instr_f = 32'hefc18213; // addi x4, x3, -260
            32'd268: instr_f = 32'h800002b7; // lui x5, 0x80000
            32'd272: instr_f = 32'hfe528317; // auipc x6, 0xfe528
            32'd276: instr_f = 32'h00630037; // lui x0, 0x00630
            32'd280: instr_f = 32'h000003b7; // lui x7, 0x00000
            32'd284: instr_f = 32'h7ffff417; // auipc x8, 0x7ffff
            32'd288: instr_f = 32'h80000497; // auipc x9, 0x80000
            32'd292: instr_f = 32'h00000537; // lui x10, 0x00000
            32'd296: instr_f = 32'h12345597; // auipc x11, 0x12345
            32'd300: instr_f = 32'h00758613; // addi x12, x11, 7
            32'd304: instr_f = 32'h00b086b3; // add x13, x1, x11

            default:
                instr_f = 32'h00000013; // NOP
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_f    <= 32'd0;
            pc_x    <= 32'd0;
            instr_x <= 32'h00000013;
            valid_x <= 1'b0;
        end else begin
            pc_x    <= pc_f;
            instr_x <= instr_f;
            valid_x <= 1'b1;
            pc_f    <= pc_f + 32'd4;
        end
    end

endmodule

