`timescale 1ns/1ps
module load_store_tb;
    reg clk = 0;
    reg rst_n = 0;
    wire [31:0] pc_x, instr_x, wb_pc, wb_data;
    wire [4:0] wb_rd;
    wire valid_x, wb_we;
    localparam N = 49;
    reg [31:0] pcs[0:N-1], insns[0:N-1], results[0:N-1];
    reg [31:0] addresses[0:N-1], store_data[0:N-1];
    reg [4:0] dests[0:N-1];
    reg [1:0] kinds[0:N-1];
    integer forwards[0:N-1];
    integer i, warm, bubbles, loads, stores;
    cpu_top dut(.clk(clk),.rst_n(rst_n),.pc_x(pc_x),.instr_x(instr_x),
        .valid_x(valid_x),.wb_pc(wb_pc),.wb_rd(wb_rd),
        .wb_data(wb_data),.wb_we(wb_we),
        .retire_valid(),.cycle_count(),.instret_count());
    always #5 clk=~clk;
    task tick;
        begin @(posedge clk); #1; end
    endtask
    task set_case;
        input integer n;
        input [31:0] pc, insn;
        input [4:0] rd;
        input [31:0] result, addr, data;
        input [1:0] kind;
        input integer fwd;
        begin
            pcs[n]=pc; insns[n]=insn; dests[n]=rd; results[n]=result;
            addresses[n]=addr; store_data[n]=data; kinds[n]=kind;
            forwards[n]=fwd;
        end
    endtask
    initial begin
        set_case(0,32'd704,32'h04000093,5'd1,32'h00000040,32'd0,32'h00000000,2'd0,-1);
        set_case(1,32'd708,32'h07b00113,5'd2,32'h0000007b,32'd0,32'h00000000,2'd0,-1);
        set_case(2,32'd712,32'h0020a023,5'd0,32'h00000000,32'd64,32'h0000007b,2'd2,1);
        set_case(3,32'd716,32'h0000a183,5'd3,32'h0000007b,32'd64,32'h00000000,2'd1,0);
        set_case(4,32'd720,32'h00118213,5'd4,32'h0000007c,32'd0,32'h00000000,2'd0,2);
        set_case(5,32'd724,32'h0040a223,5'd0,32'h00000000,32'd68,32'h0000007c,2'd2,1);
        set_case(6,32'd728,32'h0040a283,5'd5,32'h0000007c,32'd68,32'h00000000,2'd1,-1);
        set_case(7,32'd732,32'h0050a423,5'd0,32'h00000000,32'd72,32'h0000007c,2'd2,1);
        set_case(8,32'd736,32'h00408313,5'd6,32'h00000044,32'd0,32'h00000000,2'd0,-1);
        set_case(9,32'd740,32'hffc32383,5'd7,32'h0000007b,32'd64,32'h00000000,2'd1,2);
        set_case(10,32'd744,32'h00732423,5'd0,32'h00000000,32'd76,32'h0000007b,2'd2,1);
        set_case(11,32'd748,32'hfff00413,5'd8,32'hffffffff,32'd0,32'h00000000,2'd0,-1);
        set_case(12,32'd752,32'hfe832e23,5'd0,32'h00000000,32'd64,32'hffffffff,2'd2,1);
        set_case(13,32'd756,32'h0000a483,5'd9,32'hffffffff,32'd64,32'h00000000,2'd1,-1);
        set_case(14,32'd760,32'h80000537,5'd10,32'h80000000,32'd0,32'h00000000,2'd0,-1);
        set_case(15,32'd764,32'h00a0a823,5'd0,32'h00000000,32'd80,32'h80000000,2'd2,1);
        set_case(16,32'd768,32'h0100a583,5'd11,32'h80000000,32'd80,32'h00000000,2'd1,-1);
        set_case(17,32'd772,32'h08000613,5'd12,32'h00000080,32'd0,32'h00000000,2'd0,-1);
        set_case(18,32'd776,32'h00c62023,5'd0,32'h00000000,32'd128,32'h00000080,2'd2,3);
        set_case(19,32'd780,32'h00062683,5'd13,32'h00000080,32'd128,32'h00000000,2'd1,-1);
        set_case(20,32'd784,32'h0026a223,5'd0,32'h00000000,32'd132,32'h0000007b,2'd2,2);
        set_case(21,32'd788,32'h0046a703,5'd14,32'h0000007b,32'd132,32'h00000000,2'd1,-1);
        set_case(22,32'd792,32'h00062783,5'd15,32'h00000080,32'd128,32'h00000000,2'd1,-1);
        set_case(23,32'd796,32'h0047a803,5'd16,32'h0000007b,32'd132,32'h00000000,2'd1,2);
        set_case(24,32'd800,32'h0040a003,5'd0,32'h0000007c,32'd68,32'h00000000,2'd1,-1);
        set_case(25,32'd804,32'h00700893,5'd17,32'h00000007,32'd0,32'h00000000,2'd0,0);
        set_case(26,32'd808,32'h0000aa23,5'd0,32'h00000000,32'd84,32'h00000000,2'd2,-1);
        set_case(27,32'd812,32'h0140a903,5'd18,32'h00000000,32'd84,32'h00000000,2'd1,-1);
        set_case(28,32'd816,32'h3fc00993,5'd19,32'h000003fc,32'd0,32'h00000000,2'd0,-1);
        set_case(29,32'd820,32'h0089a023,5'd0,32'h00000000,32'd1020,32'hffffffff,2'd2,2);
        set_case(30,32'd824,32'h0009aa03,5'd20,32'hffffffff,32'd1020,32'h00000000,2'd1,-1);
        set_case(31,32'd828,32'h01102023,5'd0,32'h00000000,32'd0,32'h00000007,2'd2,-1);
        set_case(32,32'd832,32'h00002a83,5'd21,32'h00000007,32'd0,32'h00000000,2'd1,-1);
        set_case(33,32'd836,32'h0000ac23,5'd0,32'h00000000,32'd88,32'h00000000,2'd2,-1);
        set_case(34,32'd840,32'h0040ab03,5'd22,32'h0000007c,32'd68,32'h00000000,2'd1,-1);
        set_case(35,32'd844,32'h005b0463,5'd0,32'h00000000,32'd0,32'h00000000,2'd0,2);
        set_case(36,32'd852,32'h0180ab83,5'd23,32'h00000000,32'd88,32'h00000000,2'd1,-1);
        set_case(37,32'd856,32'h0080006f,5'd0,32'h00000000,32'd0,32'h00000000,2'd0,-1);
        set_case(38,32'd864,32'h00900c13,5'd24,32'h00000009,32'd0,32'h00000000,2'd0,-1);
        set_case(39,32'd868,32'h0180ae23,5'd0,32'h00000000,32'd92,32'h00000009,2'd2,1);
        set_case(40,32'd872,32'h01c0ac83,5'd25,32'h00000009,32'd92,32'h00000000,2'd1,-1);
        set_case(41,32'd876,32'h001c8c93,5'd25,32'h0000000a,32'd0,32'h00000000,2'd0,2);
        set_case(42,32'd880,32'h0190ae23,5'd0,32'h00000000,32'd92,32'h0000000a,2'd2,1);
        set_case(43,32'd884,32'h01c0ad03,5'd26,32'h0000000a,32'd92,32'h00000000,2'd1,-1);
        set_case(44,32'd888,32'h7ff00d93,5'd27,32'h000007ff,32'd0,32'h00000000,2'd0,-1);
        set_case(45,32'd892,32'h001d8d93,5'd27,32'h00000800,32'd0,32'h00000000,2'd0,-1);
        set_case(46,32'd896,32'h811da023,5'd0,32'h00000000,32'd0,32'h00000007,2'd2,2);
        set_case(47,32'd900,32'h800dae03,5'd28,32'h00000007,32'd0,32'h00000000,2'd1,-1);
        set_case(48,32'd904,32'h06300e93,5'd29,32'h00000063,32'd0,32'h00000000,2'd0,-1);
        #11; rst_n=1;
        warm=0;
        while ((pc_x !== 704 || valid_x !== 1'b1) && warm<230) begin
            tick; warm=warm+1;
        end
        if (warm==230) $fatal(1,"Memory program not reached");
        loads=0; stores=0; bubbles=0;
        for(i=0;i<N;i=i+1) begin
            if (valid_x === 1'b0) begin
                if (dut.mem_we_x !== 0 || dut.mem_re_x !== 0)
                    $fatal(1,"Squashed instruction accessed memory");
                bubbles=bubbles+1;
                tick;
            end
            if (valid_x !== 1'b1 || pc_x !== pcs[i] || instr_x !== insns[i])
                $fatal(1,"Trace mismatch case=%0d pc=%0d expected=%0d",i,pc_x,pcs[i]);
            if (forwards[i]>=0 &&
                {dut.forward_rs1_x,dut.forward_rs2_x} !== forwards[i][1:0])
                $fatal(1,"Forwarding mismatch at PC=%0d",pc_x);
            if (dut.mem_re_x !== (kinds[i]==1) || dut.mem_we_x !== (kinds[i]==2))
                $fatal(1,"Memory enables mismatch at PC=%0d",pc_x);
            if (kinds[i]!=0) begin
                if (dut.mem_addr_x !== addresses[i] || dut.mem_access_ok_x !== 1)
                    $fatal(1,"Address mismatch at PC=%0d addr=%h",pc_x,dut.mem_addr_x);
                if (kinds[i]==1) begin
                    loads=loads+1;
                    if (dut.forward_rs2_x !== 0)
                        $fatal(1,"False rs2 forwarding on load at PC=%0d",pc_x);
                end else begin
                    stores=stores+1;
                    if (dut.mem_wdata_x !== store_data[i] || dut.writes_rd_x !== 0)
                        $fatal(1,"Store data or register write control at PC=%0d",pc_x);
                end
            end
            if (kinds[i]==1) begin
                tick;
                if (dut.load_pending !== 1'b1 || pc_x !== pcs[i] ||
                    dut.mem_re_x !== 1'b0)
                    $fatal(1,"Load wait cycle mismatch at PC=%0d",pcs[i]);
                if (dut.mem_rdata_x !== results[i])
                    $fatal(1,"Synchronous load response mismatch at PC=%0d",pcs[i]);
                tick;
            end else begin
                tick;
            end
            if (wb_pc !== pcs[i] || wb_we !== (dests[i]!=0))
                $fatal(1,"WB control mismatch at PC=%0d",pcs[i]);
            if (dests[i]!=0 && (wb_rd !== dests[i] || wb_data !== results[i]))
                $fatal(1,"WB data mismatch pc=%0d got=%h expected=%h",pcs[i],wb_data,results[i]);
            if(kinds[i]==2 && dut.u_data_mem.mem[addresses[i]>>2] !== store_data[i])
                $fatal(1,"Store did not update RAM at PC=%0d",pcs[i]);
        end
        tick;
        if (bubbles!=2 || dut.u_regfile.regs[29] !== 99 ||
            dut.u_regfile.regs[26] !== 10 || dut.u_regfile.regs[28] !== 7 ||
            dut.u_data_mem.mem[22] !== 0 || dut.u_data_mem.mem[23] !== 10 ||
            dut.u_data_mem.mem[255] !== 32'hffffffff ||
            dut.u_data_mem.mem[0] !== 7)
            $fatal(1,"Final RAM/register state or squash count mismatch");
        $display("PASS: LW/SW %0d instructions, %0d loads, %0d stores",N,loads,stores);
        $display("PASS: load-use, store address/data forwarding, signed offsets, x0 and squash");
        $stop;
    end
    initial begin #4000; $fatal(1,"Memory test timeout"); end
endmodule


