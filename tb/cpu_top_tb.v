`timescale 1ns/1ps

module cpu_top_tb;

    reg clk;
    reg rst_n;

    wire [31:0] pc_x;
    wire [31:0] instr_x;
    wire valid_x;

    wire [31:0] wb_pc;
    wire [4:0]  wb_rd;
    wire [31:0] wb_data;
    wire wb_we;

    localparam [2:0] ALU_ADD = 3'b000;
    localparam [2:0] ALU_SUB = 3'b001;
    localparam [2:0] ALU_AND = 3'b010;
    localparam [2:0] ALU_OR  = 3'b011;
    localparam [2:0] ALU_XOR = 3'b100;

    localparam [2:0] ALU_SLL = 3'b101;
    localparam [2:0] ALU_SRL = 3'b110;
    localparam [2:0] ALU_SRA = 3'b111;
    // Flag order: ADDI ADD SUB AND OR XOR ANDI ORI XORI SLL SRL SRA SLLI SRLI SRAI.
    localparam [14:0] F_ADDI = 15'b100000000000000;
    localparam [14:0] F_ADD  = 15'b010000000000000;
    localparam [14:0] F_SUB  = 15'b001000000000000;
    localparam [14:0] F_AND  = 15'b000100000000000;
    localparam [14:0] F_OR   = 15'b000010000000000;
    localparam [14:0] F_XOR  = 15'b000001000000000;
    localparam [14:0] F_ANDI = 15'b000000100000000;
    localparam [14:0] F_ORI  = 15'b000000010000000;
    localparam [14:0] F_XORI = 15'b000000001000000;

    localparam [14:0] F_SLL = 15'b000000000100000;
    localparam [14:0] F_SRL = 15'b000000000010000;
    localparam [14:0] F_SRA = 15'b000000000001000;
    localparam [14:0] F_SLLI = 15'b000000000000100;
    localparam [14:0] F_SRLI = 15'b000000000000010;
    localparam [14:0] F_SRAI = 15'b000000000000001;
    localparam integer NUM_INSTR = 41;

    wire [14:0] decode_flags;

    // Explicit expected values for each instruction.
    reg [31:0] expected_instr  [0:NUM_INSTR-1];
    reg [14:0]  expected_flags  [0:NUM_INSTR-1];
    reg [2:0]  expected_op     [0:NUM_INSTR-1];
    reg [1:0]  expected_fwd    [0:NUM_INSTR-1];
    reg [31:0] expected_a      [0:NUM_INSTR-1];
    reg [31:0] expected_b      [0:NUM_INSTR-1];
    reg [31:0] expected_result [0:NUM_INSTR-1];

    integer i;
    reg expected_use_imm;

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

    assign decode_flags = {
        dut.is_addi_x,
        dut.is_add_x,
        dut.is_sub_x,
        dut.is_and_x,
        dut.is_or_x,
        dut.is_xor_x,
        dut.is_andi_x,
        dut.is_ori_x,
        dut.is_xori_x,
        dut.is_sll_x,
        dut.is_srl_x,
        dut.is_sra_x, dut.is_slli_x, dut.is_srli_x, dut.is_srai_x
    };

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    // Populate one row of the expected-value table.
    // fwd[1] = rs1 forwarding; fwd[0] = rs2 forwarding.
    task set_case;
        input integer index;
        input [31:0] instruction;
        input [14:0] flags;
        input [2:0] op;
        input [1:0] fwd;
        input [31:0] a;
        input [31:0] b;
        input [31:0] result;
        begin
            expected_instr[index]  = instruction;
            expected_flags[index]  = flags;
            expected_op[index]     = op;
            expected_fwd[index]    = fwd;
            expected_a[index]      = a;
            expected_b[index]      = b;
            expected_result[index] = result;
        end
    endtask


    reg [31:0] committed [0:31];
    reg [31:0] known_regs;
    reg expected_shift_imm;
    integer cycle, j, idx;
    reg [4:0] dest;
    reg expected_we;

    initial begin
        rst_n = 0;
        known_regs = 32'd1;
        committed[0] = 0;
        set_case(0, 32'h00500093, F_ADDI, ALU_ADD, 2'b00, 32'd0, 32'd5, 32'd5);
        set_case(1, 32'h00308113, F_ADDI, ALU_ADD, 2'b10, 32'd5, 32'd3, 32'd8);
        set_case(2, 32'h002081b3, F_ADD, ALU_ADD, 2'b01, 32'd5, 32'd8, 32'd13);
        set_case(3, 32'h00318233, F_ADD, ALU_ADD, 2'b11, 32'd13, 32'd13, 32'd26);
        set_case(4, 32'h403202b3, F_SUB, ALU_SUB, 2'b10, 32'd26, 32'd13, 32'd13);
        set_case(5, 32'h40508333, F_SUB, ALU_SUB, 2'b01, 32'd5, 32'd13, 32'hfffffff8);
        set_case(6, 32'h004373b3, F_AND, ALU_AND, 2'b10, 32'hfffffff8, 32'd26, 32'd24);
        set_case(7, 32'h0070e433, F_OR, ALU_OR, 2'b01, 32'd5, 32'd24, 32'd29);
        set_case(8, 32'h007444b3, F_XOR, ALU_XOR, 2'b10, 32'd29, 32'd24, 32'd5);
        set_case(9, 32'h0094f513, F_ANDI, ALU_AND, 2'b10, 32'd5, 32'd9, 32'd1);
        set_case(10, 32'h00a56593, F_ORI, ALU_OR, 2'b10, 32'd1, 32'd10, 32'd11);
        set_case(11, 32'h00b5c613, F_XORI, ALU_XOR, 2'b10, 32'd11, 32'd11, 32'd0);
        set_case(12, 32'hfff64693, F_XORI, ALU_XOR, 2'b10, 32'd0, 32'hffffffff, 32'hffffffff);
        set_case(13, 32'h8006f713, F_ANDI, ALU_AND, 2'b10, 32'hffffffff, 32'hfffff800, 32'hfffff800);
        set_case(14, 32'hfff76793, F_ORI, ALU_OR, 2'b10, 32'hfffff800, 32'hffffffff, 32'hffffffff);
        set_case(15, 32'h00a79833, F_SLL, ALU_SLL, 2'b10, 32'hffffffff, 32'd1, 32'hfffffffe);
        set_case(16, 32'h00a858b3, F_SRL, ALU_SRL, 2'b10, 32'hfffffffe, 32'd1, 32'h7fffffff);
        set_case(17, 32'h40a85933, F_SRA, ALU_SRA, 2'b00, 32'hfffffffe, 32'd1, 32'hffffffff);
        set_case(18, 32'h02100993, F_ADDI, ALU_ADD, 2'b00, 32'd0, 32'd33, 32'd33);
        set_case(19, 32'h41335a33, F_SRA, ALU_SRA, 2'b01, 32'hfffffff8, 32'd33, 32'hfffffffc);
        set_case(20, 32'h01351ab3, F_SLL, ALU_SLL, 2'b00, 32'd1, 32'd33, 32'd2);
        set_case(21, 32'h00aadb33, F_SRL, ALU_SRL, 2'b10, 32'd2, 32'd1, 32'd1);
        set_case(22, 32'h016b1bb3, F_SLL, ALU_SLL, 2'b11, 32'd1, 32'd1, 32'd2);
        set_case(23, 32'h02000c13, F_ADDI, ALU_ADD, 2'b00, 32'd0, 32'd32, 32'd32);
        set_case(24, 32'h01885cb3, F_SRL, ALU_SRL, 2'b01, 32'hfffffffe, 32'd32, 32'hfffffffe);
        set_case(25, 32'h001c9d13, F_SLLI, ALU_SLL, 2'b10, 32'hfffffffe, 32'd1, 32'hfffffffc);
        set_case(26, 32'h001d5d93, F_SRLI, ALU_SRL, 2'b10, 32'hfffffffc, 32'd1, 32'h7ffffffe);
        set_case(27, 32'h401d5e13, F_SRAI, ALU_SRA, 2'b00, 32'hfffffffc, 32'd1, 32'hfffffffe);
        set_case(28, 32'h01f51e93, F_SLLI, ALU_SLL, 2'b00, 32'h00000001, 32'd31, 32'h80000000);
        set_case(29, 32'h01fedf13, F_SRLI, ALU_SRL, 2'b10, 32'h80000000, 32'd31, 32'h00000001);
        set_case(30, 32'h41fedf93, F_SRAI, ALU_SRA, 2'b00, 32'h80000000, 32'd31, 32'hffffffff);
        set_case(31, 32'h000f9d13, F_SLLI, ALU_SLL, 2'b10, 32'hffffffff, 32'd0, 32'hffffffff);
        set_case(32, 32'h000d5d93, F_SRLI, ALU_SRL, 2'b10, 32'hffffffff, 32'd0, 32'hffffffff);
        set_case(33, 32'h400dde13, F_SRAI, ALU_SRA, 2'b10, 32'hffffffff, 32'd0, 32'hffffffff);
        set_case(34, 32'h01ce1e93, F_SLLI, ALU_SLL, 2'b10, 32'hffffffff, 32'd28, 32'hf0000000);
        set_case(35, 32'h01dedf13, F_SRLI, ALU_SRL, 2'b10, 32'hf0000000, 32'd29, 32'h00000007);
        set_case(36, 32'h41eedf93, F_SRAI, ALU_SRA, 2'b00, 32'hf0000000, 32'd30, 32'hffffffff);
        set_case(37, 32'h001f9013, F_SLLI, ALU_SLL, 2'b10, 32'hffffffff, 32'd1, 32'hfffffffe);
        set_case(38, 32'h00106d13, F_ORI, ALU_OR, 2'b00, 32'h00000000, 32'd1, 32'h00000001);
        set_case(39, 32'h001d5d93, F_SRLI, ALU_SRL, 2'b10, 32'h00000001, 32'd1, 32'h00000000);
        set_case(40, 32'h401d5e13, F_SRAI, ALU_SRA, 2'b00, 32'h00000001, 32'd1, 32'h00000000);

        #1;
        if (valid_x !== 0 || wb_we !== 0 || wb_pc !== 0 ||
            wb_rd !== 0 || wb_data !== 0)
            $fatal(1, "Reset mismatch");
        #11;
        rst_n = 1;

        // At sample cycle i: EX=i, WB=i-1, committed=i-2.
        for (cycle=0; cycle<NUM_INSTR+2; cycle=cycle+1) begin
            tick;
            if (cycle < NUM_INSTR) begin
                i = cycle;
                expected_shift_imm = (expected_flags[i] == F_SLLI) ||
                                     (expected_flags[i] == F_SRLI) ||
                                     (expected_flags[i] == F_SRAI);
                expected_use_imm = expected_shift_imm ||
                    (expected_flags[i] == F_ADDI) || (expected_flags[i] == F_ANDI) ||
                    (expected_flags[i] == F_ORI) || (expected_flags[i] == F_XORI);
                if (valid_x !== 1'b1 || pc_x !== (i*4) ||
                    instr_x !== expected_instr[i] || decode_flags !== expected_flags[i] ||
                    dut.use_imm_x !== expected_use_imm ||
                    dut.use_shift_imm_x !== expected_shift_imm ||
                    dut.uses_rs2_x !== (!expected_use_imm) || dut.writes_rd_x !== 1'b1 ||
                    dut.alu_op_x !== expected_op[i] ||
                    {dut.forward_rs1_x,dut.forward_rs2_x} !== expected_fwd[i] ||
                    dut.alu_a_x !== expected_a[i] || dut.alu_b_x !== expected_b[i] ||
                    dut.alu_result_x !== expected_result[i]) begin
                    $display("FAIL: EX case=%0d pc=%h instr=%h flags=%b op=%b",i+1,
                             pc_x,instr_x,decode_flags,dut.alu_op_x);
                    $display("expected flags=%b op=%b fwd=%b A=%h B=%h result=%h",
                        expected_flags[i],expected_op[i],expected_fwd[i],
                        expected_a[i],expected_b[i],expected_result[i]);
                    $display("actual fwd=%b A=%h B=%h result=%h use_imm=%b shift_imm=%b",
                        {dut.forward_rs1_x,dut.forward_rs2_x},dut.alu_a_x,dut.alu_b_x,
                        dut.alu_result_x,dut.use_imm_x,dut.use_shift_imm_x);
                    $fatal(1,"EX mismatch");
                end
                if (expected_use_imm && !expected_shift_imm &&
                    dut.imm_x !== expected_b[i]) $fatal(1,"Sign extension mismatch");
                if (expected_shift_imm && dut.shamt_imm_x !== expected_b[i])
                    $fatal(1,"Shift immediate extraction mismatch");
                if (((i>=9)&&(i<=11)) || ((i>=34)&&(i<=36))) begin
                    if (dut.rs2_addr_x !== wb_rd || dut.forward_rs2_x !== 1'b0)
                        $fatal(1,"False rs2 dependency test failed");
                end
                $display("PASS: case=%0d pc=%0d instr=%h result=%h",i+1,pc_x,instr_x,dut.alu_result_x);
            end else begin
                if (valid_x !== 1'b1 || pc_x !== cycle*4 || instr_x !== 32'h00000013 ||
                    decode_flags !== F_ADDI || dut.alu_result_x !== 0)
                    $fatal(1,"Trailing NOP mismatch");
            end

            idx = cycle-1;
            if ((idx>=0)&&(idx<NUM_INSTR)) begin
                dest = expected_instr[idx][11:7];
                expected_we = (dest != 0);
                if (wb_pc !== idx*4 || wb_rd !== dest ||
                    wb_data !== expected_result[idx] || wb_we !== expected_we) begin
                    $display("FAIL: WB index=%0d pc=%h rd=%0d data=%h we=%b",idx,wb_pc,wb_rd,wb_data,wb_we);
                    $fatal(1,"WB mismatch");
                end
            end else if (wb_we !== 1'b0) $fatal(1,"Unexpected write enable");

            // Update the independent committed-value table, then check every
            // register that the program has initialized. Repeated rd is legal.
            idx = cycle-2;
            if ((idx>=0)&&(idx<NUM_INSTR)) begin
                dest = expected_instr[idx][11:7];
                if (dest != 0) begin
                    committed[dest] = expected_result[idx];
                    known_regs[dest] = 1'b1;
                end
            end
            for (j=1;j<32;j=j+1)
                if (known_regs[j] && dut.u_regfile.regs[j] !== committed[j]) begin
                    $display("FAIL: x%0d actual=%h expected=%h",j,dut.u_regfile.regs[j],committed[j]);
                    $fatal(1,"Committed register mismatch");
                end
            // x0 is hardwired on read ports; regs[0] is not initialized storage.
            if ((dut.rs1_addr_x == 0) && (dut.rs1_data_x !== 0))
                $fatal(1,"x0 rs1 read mismatch");
            if ((dut.rs2_addr_x == 0) && (dut.rs2_data_x !== 0))
                $fatal(1,"x0 rs2 read mismatch");
        end
        $display("PASS: original 25 instructions preserved");
        $display("PASS: SLLI/SRLI/SRAI shamt 0/1/31, rs1 forwarding, no rs2 forwarding");
        $display("PASS: writes to x0 suppressed, repeated destination writeback checked");
        $display("PASS: cpu_top immediate shift integration test passed, 41 instructions");
        $display("PASS: x26=1 x27=0 x28=0 x29=f0000000 x30=7 x31=ffffffff");
        $stop;
    end
    initial begin
        #2000;
        $fatal(1,"CPU test timeout");
    end
endmodule
