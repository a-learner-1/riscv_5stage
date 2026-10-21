`timescale 1ns/1ps
module cpu5_hazard_tb;
    reg consumer_valid, uses_rs1, uses_rs2;
    reg [4:0] rs1, rs2;
    reg [31:0] rf_rs1_value, rf_rs2_value;
    reg ex_valid, ex_writes_rd, ex_result_ready;
    reg [4:0] ex_rd;
    reg mem_valid, mem_writes_rd, mem_result_ready;
    reg [4:0] mem_rd;
    reg [31:0] mem_result_value;
    reg wb_valid, wb_writes_rd, wb_result_ready;
    reg [4:0] wb_rd;
    reg [31:0] wb_result_value;
    wire [31:0] data1[0:1], data2[0:1];
    wire [2:0] sel1[0:1], sel2[0:1];
    wire hold1[0:1], hold2[0:1], hold_all[0:1];
    wire exhold1[0:1], exhold2[0:1], exhold_all[0:1];
    reg test_pass = 0;
    integer cases = 0, checks = 0, named_cases = 0;
    integer flagbits, shape, pattern, consumerbits, regnumber, mode, p;
    integer writer_seq[0:2];
    integer writer_kind[0:2];
    reg writer_valid[0:2], writer_writes[0:2], writer_ready[0:2];
    reg [4:0] writer_rd[0:2];
    reg [31:0] writer_value[0:2];
    integer newest, chosen, source_index;
    reg [36:0] expected1, expected2;
    reg [255:0] named_label;

    genvar g;
    generate for (g=0; g<2; g=g+1) begin: gen_dut
        cpu5_hazard #(.CHECK_EX_PRODUCER(g)) dut (
            .consumer_valid(consumer_valid), .uses_rs1(uses_rs1), .uses_rs2(uses_rs2),
            .rs1(rs1), .rs2(rs2), .rf_rs1_value(rf_rs1_value), .rf_rs2_value(rf_rs2_value),
            .ex_valid(ex_valid), .ex_writes_rd(ex_writes_rd), .ex_rd(ex_rd),
            .ex_result_ready(ex_result_ready), .mem_valid(mem_valid),
            .mem_writes_rd(mem_writes_rd), .mem_rd(mem_rd), .mem_result_ready(mem_result_ready),
            .mem_result_value(mem_result_value), .wb_valid(wb_valid),
            .wb_writes_rd(wb_writes_rd), .wb_rd(wb_rd), .wb_result_ready(wb_result_ready),
            .wb_result_value(wb_result_value), .rs1_value(data1[g]), .rs2_value(data2[g]),
            .fwd1(sel1[g]), .fwd2(sel2[g]), .stall1(hold1[g]), .stall2(hold2[g]),
            .stall(hold_all[g]), .ex_block1(exhold1[g]), .ex_block2(exhold2[g]),
            .ex_block(exhold_all[g])
        );
    end endgenerate

    // Independent scoreboard: producers are an unordered set of register
    // versions with dynamic age tags. Pick the largest older age, then ask
    // whether that version can be read at the consumer's resolution point.
    function [36:0] model;
        input integer id_resolution;
        input used;
        input [4:0] source;
        input [31:0] saved_value;
        integer k, latest_age, latest_index;
        reg can_read;
        reg [2:0] selection;
        begin
            model = {1'b0, 1'b0, 3'd0, saved_value};
            if (consumer_valid && used) begin
                if (source == 0)
                    model = {1'b0, 1'b0, 3'd1, 32'd0};
                else begin
                    latest_age = -1;
                    latest_index = -1;
                    for (k=0; k<3; k=k+1) begin
                        if ((id_resolution || writer_kind[k] != 4) &&
                            writer_valid[k] && writer_writes[k] &&
                            writer_rd[k] != 0 && writer_rd[k] == source &&
                            writer_seq[k] > latest_age) begin
                            latest_age = writer_seq[k];
                            latest_index = k;
                        end
                    end
                    if (latest_index >= 0) begin
                        can_read = writer_ready[latest_index] && writer_kind[latest_index] != 4;
                        selection = writer_kind[latest_index];
                        if (can_read)
                            model = {1'b0, 1'b0, selection, writer_value[latest_index]};
                        else
                            model = {1'b1, (writer_kind[latest_index] == 4), 3'd4, 32'd0};
                    end
                end
            end
        end
    endfunction

    task check;
        begin
            #1;
            // Deliberately unordered enumeration WB, EX, MEM.
            writer_seq[0]=10; writer_kind[0]=3; writer_valid[0]=wb_valid;
            writer_writes[0]=wb_writes_rd; writer_rd[0]=wb_rd;
            writer_ready[0]=wb_result_ready; writer_value[0]=wb_result_value;
            writer_seq[1]=30; writer_kind[1]=4; writer_valid[1]=ex_valid;
            writer_writes[1]=ex_writes_rd; writer_rd[1]=ex_rd;
            writer_ready[1]=ex_result_ready; writer_value[1]=32'hbad0feed;
            writer_seq[2]=20; writer_kind[2]=2; writer_valid[2]=mem_valid;
            writer_writes[2]=mem_writes_rd; writer_rd[2]=mem_rd;
            writer_ready[2]=mem_result_ready; writer_value[2]=mem_result_value;
            for (mode=0; mode<2; mode=mode+1) begin
                expected1=model(mode,uses_rs1,rs1,rf_rs1_value);
                expected2=model(mode,uses_rs2,rs2,rf_rs2_value);
                if ({hold1[mode],exhold1[mode],sel1[mode],data1[mode]} !== expected1 ||
                    {hold2[mode],exhold2[mode],sel2[mode],data2[mode]} !== expected2 ||
                    hold_all[mode] !== (expected1[36] || expected2[36]) ||
                    exhold_all[mode] !== (expected1[35] || expected2[35])) begin
                    $display("HAZARD FAIL case=%0d named=%0s mode=%0d flags=%0d shape=%0d pattern=%0d consumer=%0d rs=%0d/%0d",
                             cases,named_label,mode,flagbits,shape,pattern,consumerbits,rs1,rs2);
                    $display("s1 expected=%h actual=%h s2 expected=%h actual=%h",expected1,
                             {hold1[mode],exhold1[mode],sel1[mode],data1[mode]},expected2,
                             {hold2[mode],exhold2[mode],sel2[mode],data2[mode]});
                    $fatal(1,"CPU5 HAZARD oracle disagreement");
                end
                checks=checks+2;
            end
            cases=cases+1;
        end
    endtask

    task defaults;
        begin
            consumer_valid=1; uses_rs1=1; uses_rs2=1; rs1=5; rs2=6;
            rf_rs1_value=32'h11112222; rf_rs2_value=32'h33334444;
            ex_valid=0; ex_writes_rd=1; ex_result_ready=1; ex_rd=5;
            mem_valid=0; mem_writes_rd=1; mem_result_ready=1; mem_rd=5;
            mem_result_value=32'h55556666;
            wb_valid=0; wb_writes_rd=1; wb_result_ready=1; wb_rd=5;
            wb_result_value=32'h77778888;
        end
    endtask

    task named_check;
        input [255:0] label_text;
        begin
            named_label=label_text;
            check;
            named_cases=named_cases+1;
        end
    endtask

    initial begin
        defaults; named_check("RF only");
        mem_valid=1; named_check("ALU MEM to EX");
        mem_result_ready=0; named_check("load waits for response");
        wb_valid=1; named_check("newest blocks older WB");
        mem_result_ready=1; named_check("newest ready beats older WB");
        ex_valid=1; named_check("EX blocks ID even ready");
        ex_result_ready=0; named_check("M owner not ready");
        mem_result_ready=0; named_check("CSR not ready");
        defaults; wb_valid=1; named_check("WB to ID EX bypass");
        defaults; mem_valid=1; wb_valid=1; wb_rd=6; named_check("two independent sources");
        mem_result_ready=0; named_check("rs1 blocks rs2 still selects");
        defaults; ex_valid=1; mem_valid=1; wb_valid=1;
        rs1=0; rs2=0; ex_rd=0; mem_rd=0; wb_rd=0;
        ex_result_ready=0; mem_result_ready=0; wb_result_ready=0;
        named_check("x0 masks every producer");
        defaults; ex_valid=1; mem_valid=1; wb_valid=1;
        uses_rs1=0; uses_rs2=0; named_check("unused operands ignore RAW");
        uses_rs1=1; uses_rs2=1; consumer_valid=0; named_check("invalid consumer ignores RAW");
        defaults; mem_valid=1; mem_writes_rd=0; named_check("store is not GPR writer");
        defaults; ex_valid=1; ex_rd=6; mem_valid=1; mem_rd=5; wb_valid=1;
        wb_rd=6; named_check("two ages opposite sources");
        defaults; rs2=5; mem_valid=1; mem_result_ready=0; wb_valid=1;
        named_check("both sources blocked by newest");
        defaults; wb_valid=1; wb_result_ready=0; named_check("WB readiness honored");

        named_label="cross product";
        // All producer valid/write/ready flags, all source-use/valid flags,
        // x0/rs1/rs2 producer-name classes, and four source relationship shapes.
        for (pattern=0; pattern<4; pattern=pattern+1) begin
            case (pattern)
                0: begin rs1=5; rs2=6; end
                1: begin rs1=31; rs2=31; end
                2: begin rs1=0; rs2=6; end
                3: begin rs1=5; rs2=0; end
            endcase
            for (shape=0; shape<27; shape=shape+1) begin
                case (shape%3) 0: ex_rd=0; 1: ex_rd=rs1; 2: ex_rd=rs2; endcase
                case ((shape/3)%3) 0: mem_rd=0; 1: mem_rd=rs1; 2: mem_rd=rs2; endcase
                case ((shape/9)%3) 0: wb_rd=0; 1: wb_rd=rs1; 2: wb_rd=rs2; endcase
                for (flagbits=0; flagbits<512; flagbits=flagbits+1) begin
                    {ex_valid,ex_writes_rd,ex_result_ready,
                     mem_valid,mem_writes_rd,mem_result_ready,
                     wb_valid,wb_writes_rd,wb_result_ready}=flagbits;
                    for (consumerbits=0; consumerbits<8; consumerbits=consumerbits+1) begin
                        {consumer_valid,uses_rs1,uses_rs2}=consumerbits;
                        check;
                    end
                end
            end
        end
        // Every architectural register also appears as a producer hit/non-hit.
        for (regnumber=0; regnumber<32; regnumber=regnumber+1) begin
            defaults; rs1=regnumber; rs2=31-regnumber;
            ex_valid=1; mem_valid=1; wb_valid=1;
            ex_rd=regnumber; mem_rd=31-regnumber; wb_rd=regnumber;
            named_check("architectural GPR sweep");
        end
        $display("CPU5 HAZARD PASS cases=%0d source_checks=%0d named_cases=%0d modes=2",cases,checks,named_cases);
        test_pass=1;
        $finish;
    end
endmodule
