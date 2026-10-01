`timescale 1ns/1ps

// No software toolchain is needed: each case installs its directed program
// into the synchronous instruction ROM while reset is asserted.
module data_handshake_tb;
    wire [4:0] done;
    reg test_pass = 0;
    handshake_ram_case #(.CASE_ID(0), .WAIT_MODE(0)) ram_fast(done[0]);
    handshake_ram_case #(.CASE_ID(1), .WAIT_MODE(1)) ram_fixed(done[1]);
    handshake_ram_case #(.CASE_ID(2), .WAIT_MODE(2)) ram_random(done[2]);
    handshake_mmio_case mmio_wait(done[3]);
    handshake_reset_error_case reset_error(done[4]);
    initial begin
        wait (&done);
        $display("PASS: data handshake: RAM backpressure/latency, byte lanes, forwarding, retirement, MMIO once, reset and fault recovery");
        test_pass = 1;
        $stop;
    end
    initial begin
        #300000;
        $fatal(1, "Data handshake timeout done=%b", done);
    end
endmodule

module handshake_ram_case #(
    parameter integer CASE_ID = 0,
    parameter integer WAIT_MODE = 0
) (output reg done = 0);
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    wire req_valid, req_write, rsp_ready;
    wire [31:0] req_addr, req_wdata;
    wire [1:0] req_size;
    wire [3:0] req_wstrb;
    wire [31:0] pc_x, instr_x, wb_pc, wb_data;
    wire [4:0] wb_rd;
    wire wb_we, retire_valid, fault;
    reg rsp_valid = 0;
    reg [31:0] rsp_rdata = 0;
    reg [31:0] mem [0:63];
    reg active = 0;
    reg [31:0] random_q = 32'h15a4e35b ^ CASE_ID;
    integer req_wait = 0, rsp_wait = 0;
    integer requests = 0, responses = 0, retirements = 0;
    integer stalled_requests = 0, response_wait_cycles = 0;
    integer retire_seen [0:29];
    integer i, lane;
    reg held = 0;
    reg [70:0] held_desc = 0;
    wire req_ready = rst_n && !active &&
        ((WAIT_MODE == 0) || ((WAIT_MODE == 1) && req_wait >= 3) ||
         ((WAIT_MODE == 2) && random_q[0]));
    wire [70:0] descriptor = {req_write, req_addr, req_size, req_wdata, req_wstrb};

    cpu_top #(
        .PROGRAM_FILE("programs/data_handshake_blank.hex"),
        // All directed external addresses are outside the internal RAM's
        // range. The external endpoint alone decides access legality.
        .IMEM_WORDS(256), .DMEM_WORDS(1), .DMEM_BASE_ADDR(32'h00010000), .SIM_CONSOLE_ECHO(0),
        .EXTERNAL_DMEM(1)
    ) dut (
        .clk(clk), .rst_n(rst_n), .pc_x(pc_x), .instr_x(instr_x), .valid_x(),
        .wb_pc(wb_pc), .wb_rd(wb_rd), .wb_data(wb_data), .wb_we(wb_we),
        .retire_valid(retire_valid), .cycle_count(), .instret_count(),
        .uart_rx(1'b1), .uart_tx(), .gpio_in(8'd0), .gpio_out(), .gpio_oe(),
        .dmem_req_valid(req_valid), .dmem_req_ready(req_ready),
        .dmem_req_write(req_write), .dmem_req_addr(req_addr),
        .dmem_req_size(req_size), .dmem_req_wdata(req_wdata),
        .dmem_req_wstrb(req_wstrb), .dmem_rsp_valid(rsp_valid),
        .dmem_rsp_ready(rsp_ready), .dmem_rsp_rdata(rsp_rdata),
        .dmem_rsp_error(1'b0), .dmem_fault(fault)
    );

    function [31:0] itype;
        input integer imm;
        input [4:0] rs1;
        input [2:0] f3;
        input [4:0] rd;
        input [6:0] op;
        begin itype = {imm[11:0], rs1, f3, rd, op}; end
    endfunction
    function [31:0] stype;
        input integer imm;
        input [4:0] rs2, rs1;
        input [2:0] f3;
        begin stype = {imm[11:5], rs2, rs1, f3, imm[4:0], 7'h23}; end
    endfunction
    function [31:0] btype;
        input integer imm;
        input [4:0] rs2, rs1;
        begin btype = {imm[12], imm[10:5], rs2, rs1, 3'b000,
                       imm[4:1], imm[11], 7'h63}; end
    endfunction
    function [31:0] jtype;
        input integer imm;
        input [4:0] rd;
        begin jtype = {imm[20], imm[10:1], imm[11], imm[19:12], rd, 7'h6f}; end
    endfunction

    task check_request;
        input integer n;
        reg [31:0] addr, data;
        reg [1:0] size;
        reg [3:0] strb;
        reg write_access;
        begin
            addr = 0; data = 0; size = 2; strb = 0; write_access = 0;
            case (n)
                0: begin write_access=1; data=32'h80ff7f01; strb=15; end
                1,2: begin addr=2; size=0; end
                3,4: begin addr=2; size=1; end
                5: ;
                6: begin addr=1; size=0; write_access=1; data=32'h00006600; strb=2; end
                7: begin addr=2; size=1; write_access=1; data=32'hfabc0000; strb=12; end
                8: ;
                9: begin addr=4; write_access=1; data=16; strb=15; end
                10: addr=4;
                11: begin addr=16; write_access=1; data=32'hfabc6601; strb=15; end
                12: addr=16;
                13: ; // LW x0 still performs a real read.
                14: begin addr=28; write_access=1; data=1; strb=15; end
                default: $fatal(1, "Case %0d repeated/extra RAM request %0d addr=%h", CASE_ID, n, req_addr);
            endcase
            if (req_addr !== addr || req_size !== size || req_write !== write_access ||
                req_wstrb !== strb || (write_access && req_wdata !== data))
                $fatal(1, "Case %0d request %0d mismatch addr=%h size=%0d write=%b strb=%b data=%h",
                       CASE_ID, n, req_addr, req_size, req_write, req_wstrb, req_wdata);
        end
    endtask

    // A responder with one outstanding operation. Writes take effect exactly
    // at request acceptance; read data is captured at that same point.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 0;
            rsp_valid <= 0;
            rsp_rdata <= 0;
            req_wait <= 0;
            rsp_wait <= 0;
            requests = 0;
            responses = 0;
            random_q <= 32'h15a4e35b ^ CASE_ID;
            for (i=0; i<64; i=i+1) mem[i] = 0;
        end else begin
            random_q <= {random_q[30:0], random_q[31] ^ random_q[21] ^ random_q[1] ^ random_q[0]};
            if (req_valid && !req_ready) req_wait <= req_wait + 1;
            else req_wait <= 0;
            if (req_valid && req_ready) begin
                if (active || rsp_valid) $fatal(1, "Case %0d overlapping request", CASE_ID);
                check_request(requests);
                if (req_addr >= 256) $fatal(1, "Wrong-path/MMIO request leaked to external RAM");
                rsp_rdata <= mem[req_addr[7:2]];
                if (req_write)
                    for (lane=0; lane<4; lane=lane+1)
                        if (req_wstrb[lane]) mem[req_addr[7:2]][lane*8 +: 8] = req_wdata[lane*8 +: 8];
                requests = requests + 1;
                active <= 1;
                rsp_wait <= (WAIT_MODE == 0) ? 0 : (WAIT_MODE == 1) ? 7 : random_q[4:2];
                // Zero additional wait: present the response just after this
                // acceptance edge so it can be consumed on the NEXT edge.
                rsp_valid <= (WAIT_MODE == 0) || ((WAIT_MODE == 2) && random_q[4:2] == 0);
            end else if (active && !rsp_valid) begin
                if (rsp_wait <= 1) rsp_valid <= 1;
                else rsp_wait <= rsp_wait - 1;
            end
            if (active) response_wait_cycles = response_wait_cycles + 1;
            if (rsp_valid && rsp_ready) begin
                responses = responses + 1;
                rsp_valid <= 0;
                active <= 0;
            end
        end
    end

    // The master must keep the complete descriptor stable under request
    // backpressure, including on the edge that finally accepts the request.
    always @(posedge clk) begin
        if (!rst_n) begin
            held = 0;
            retirements = 0;
            stalled_requests = 0;
            response_wait_cycles = 0;
            for (i=0; i<30; i=i+1) retire_seen[i] = 0;
        end else if (!done) begin
            if (held && (!req_valid || descriptor !== held_desc))
                $fatal(1, "Case %0d request changed while waiting", CASE_ID);
            held = req_valid && !req_ready;
            if (held) begin held_desc = descriptor; stalled_requests = stalled_requests + 1; end
            if (dut.mem_req_fire && dut.mem_req_mmio)
                $fatal(1, "Case %0d wrong-path MMIO side effect", CASE_ID);
            if (dut.mem_re_x || dut.mem_we_x)
                $fatal(1,"External request also accessed internal RAM case %0d",CASE_ID);
            if (fault) $fatal(1, "Unexpected bus fault case %0d", CASE_ID);
        end
        #1;
        if (rst_n && !done && retire_valid) begin
            if (wb_pc[1:0] != 0 || wb_pc >= 120)
                $fatal(1, "Case %0d unexpected retirement pc=%h", CASE_ID, wb_pc);
            retire_seen[wb_pc[6:2]] = retire_seen[wb_pc[6:2]] + 1;
            retirements = retirements + 1;
            if (retire_seen[wb_pc[6:2]] != 1)
                $fatal(1, "Case %0d instruction retired twice pc=%h", CASE_ID, wb_pc);
            case (wb_pc)
                12,44,52,64,72,112: if (wb_we) $fatal(1,"RAM STORE wrote register file pc=%h",wb_pc);
                16: if (!wb_we || wb_rd != 3 || wb_data !== 32'hffffffff) $fatal(1, "LB sign extension");
                20: if (!wb_we || wb_rd != 4 || wb_data !== 1) $fatal(1, "Load-use forwarding");
                24: if (!wb_we || wb_rd != 5 || wb_data !== 255) $fatal(1, "LBU zero extension");
                28: if (!wb_we || wb_rd != 6 || wb_data !== 32'hffff80ff) $fatal(1, "LH sign extension");
                32: if (!wb_we || wb_rd != 7 || wb_data !== 32'h000080ff) $fatal(1, "LHU zero extension");
                36: if (!wb_we || wb_rd != 8 || wb_data !== 32'h80ff7f01) $fatal(1, "LW data");
                56: if (!wb_we || wb_rd != 10 || wb_data !== 32'hfabc6601) $fatal(1, "Subword write lanes");
                68: if (!wb_we || wb_rd != 12 || wb_data !== 16) $fatal(1, "Loaded store address");
                76: if (!wb_we || wb_rd != 13 || wb_data !== 32'hfabc6601) $fatal(1, "Store data forwarding");
                80: if (wb_we) $fatal(1, "LW x0 wrote register file");
                100: if (!wb_we || wb_rd != 15 || wb_data !== 104) $fatal(1, "JAL link");
                116: begin
                    if (!wb_we || wb_rd != 16 || wb_data !== 42) $fatal(1, "Completion sentinel");
                    if (requests != 15 || responses != 15 || retirements != 26)
                        $fatal(1, "Case %0d counts requests=%0d responses=%0d retired=%0d", CASE_ID, requests, responses, retirements);
                    for (i=0; i<30; i=i+1) begin
                        if (i == 23 || i == 24 || i == 26 || i == 27) begin
                            if (retire_seen[i] != 0) $fatal(1, "Wrong-path instruction retired");
                        end else if (retire_seen[i] != 1) $fatal(1, "Instruction skipped pc=%0d", i*4);
                    end
                    if (mem[0] !== 32'hfabc6601 || mem[1] !== 16 ||
                        mem[4] !== 32'hfabc6601 || mem[5] !== 0 || mem[6] !== 0 || mem[7] !== 1)
                        $fatal(1, "Case %0d final RAM contents", CASE_ID);
                    if (WAIT_MODE != 0 && stalled_requests == 0) $fatal(1, "No request backpressure exercised");
                    if (response_wait_cycles < 15) $fatal(1, "No response wait exercised");
                    $display("RAM case %0d PASS: 15 requests, 26 unique retirements; blocked request cycles=%0d response wait cycles=%0d",
                             CASE_ID, stalled_requests, response_wait_cycles);
                    done = 1;
                end
                default: ;
            endcase
        end
    end

    initial begin
        #1;
        dut.u_if_stage.u_instr_mem.mem[0] = itype(0,0,0,1,7'h13);
        dut.u_if_stage.u_instr_mem.mem[1] = {20'h80ff8,5'd2,7'h37};
        dut.u_if_stage.u_instr_mem.mem[2] = itype(-255,2,0,2,7'h13);
        dut.u_if_stage.u_instr_mem.mem[3] = stype(0,2,1,2);
        dut.u_if_stage.u_instr_mem.mem[4] = itype(2,1,0,3,7'h03);
        dut.u_if_stage.u_instr_mem.mem[5] = itype(2,3,0,4,7'h13);
        dut.u_if_stage.u_instr_mem.mem[6] = itype(2,1,4,5,7'h03);
        dut.u_if_stage.u_instr_mem.mem[7] = itype(2,1,1,6,7'h03);
        dut.u_if_stage.u_instr_mem.mem[8] = itype(2,1,5,7,7'h03);
        dut.u_if_stage.u_instr_mem.mem[9] = itype(0,1,2,8,7'h03);
        dut.u_if_stage.u_instr_mem.mem[10] = itype(102,0,0,9,7'h13);
        dut.u_if_stage.u_instr_mem.mem[11] = stype(1,9,1,0);
        dut.u_if_stage.u_instr_mem.mem[12] = itype(-1348,0,0,9,7'h13);
        dut.u_if_stage.u_instr_mem.mem[13] = stype(2,9,1,1);
        dut.u_if_stage.u_instr_mem.mem[14] = itype(0,1,2,10,7'h03);
        dut.u_if_stage.u_instr_mem.mem[15] = itype(16,0,0,11,7'h13);
        dut.u_if_stage.u_instr_mem.mem[16] = stype(4,11,1,2);
        dut.u_if_stage.u_instr_mem.mem[17] = itype(4,1,2,12,7'h03);
        dut.u_if_stage.u_instr_mem.mem[18] = stype(0,10,12,2);
        dut.u_if_stage.u_instr_mem.mem[19] = itype(16,1,2,13,7'h03);
        dut.u_if_stage.u_instr_mem.mem[20] = itype(0,1,2,0,7'h03);
        dut.u_if_stage.u_instr_mem.mem[21] = {20'h20000,5'd14,7'h37};
        dut.u_if_stage.u_instr_mem.mem[22] = btype(12,10,13);
        dut.u_if_stage.u_instr_mem.mem[23] = stype(52,9,14,2);
        dut.u_if_stage.u_instr_mem.mem[24] = stype(20,9,1,2);
        dut.u_if_stage.u_instr_mem.mem[25] = jtype(12,15);
        dut.u_if_stage.u_instr_mem.mem[26] = itype(24,14,2,0,7'h03);
        dut.u_if_stage.u_instr_mem.mem[27] = stype(24,9,1,2);
        dut.u_if_stage.u_instr_mem.mem[28] = stype(28,4,1,2);
        dut.u_if_stage.u_instr_mem.mem[29] = itype(42,0,0,16,7'h13);
        dut.u_if_stage.u_instr_mem.mem[30] = jtype(0,0);
        repeat (5) @(negedge clk);
        rst_n = 1;
    end
endmodule

module handshake_mmio_case(output reg done = 0);
    reg clk=0, rst_n=0, rx=1;
    reg [7:0] gpio_in=0;
    always #5 clk=~clk;
    localparam integer BIT_NS=200;
    wire tx, retire_valid, wb_we, fault;
    wire [31:0] wb_pc, wb_data;
    wire [4:0] wb_rd;
    wire [7:0] gpio_out, gpio_oe;
    integer gpio_toggle_writes=0, gpio_oe_writes=0;
    integer rx_reads=0, real_pops=0, w1c_writes=0, tx_accepts=0;
    integer tx_frames=0, k, decode_bit;
    integer retired_once[4:15];
    reg [7:0] decoded;
    reg software_done=0;
    reg held=0;
    reg [70:0] held_desc=0;
    wire [70:0] descriptor={dut.mem_req_write,dut.mem_addr_x,dut.mem_size_x,dut.mem_wdata_x,dut.mem_wstrb_x};
    cpu_top #(
        .PROGRAM_FILE("programs/data_handshake_blank.hex"),
        .IMEM_WORDS(256), .DMEM_WORDS(64), .SIM_CONSOLE_ECHO(0),
        .UART_CLOCK_HZ(100000000), .UART_BAUD(5000000),
        .UART_RX_FIFO_DEPTH(4), .DMEM_REQ_WAIT_CYCLES(3), .DMEM_RSP_WAIT_CYCLES(7)
    ) dut (
        .clk(clk), .rst_n(rst_n), .pc_x(), .instr_x(), .valid_x(),
        .wb_pc(wb_pc), .wb_rd(wb_rd), .wb_data(wb_data), .wb_we(wb_we),
        .retire_valid(retire_valid), .cycle_count(), .instret_count(),
        .uart_rx(rx), .uart_tx(tx), .gpio_in(gpio_in), .gpio_out(gpio_out), .gpio_oe(gpio_oe),
        .dmem_req_valid(), .dmem_req_ready(1'b0), .dmem_req_write(), .dmem_req_addr(),
        .dmem_req_size(), .dmem_req_wdata(), .dmem_req_wstrb(),
        .dmem_rsp_valid(1'b0), .dmem_rsp_ready(), .dmem_rsp_rdata(32'd0),
        .dmem_rsp_error(1'b0), .dmem_fault(fault)
    );
    function [31:0] itype;
        input integer imm; input [4:0] rs1; input [2:0] f3; input [4:0] rd; input [6:0] op;
        begin itype={imm[11:0],rs1,f3,rd,op}; end
    endfunction
    function [31:0] stype;
        input integer imm; input [4:0] rs2,rs1; input [2:0] f3;
        begin stype={imm[11:5],rs2,rs1,f3,imm[4:0],7'h23}; end
    endfunction
    function [31:0] btype;
        input integer imm; input [4:0] rs2,rs1;
        begin btype={imm[12],imm[10:5],rs2,rs1,3'b000,imm[4:1],imm[11],7'h63}; end
    endfunction
    task send_frame;
        input [7:0] value; input good_stop; integer b;
        begin
            @(negedge clk); #3; rx=0; #(BIT_NS);
            for (b=0;b<8;b=b+1) begin rx=value[b]; #(BIT_NS); end
            rx=good_stop; #(BIT_NS); rx=1; #(BIT_NS*2);
        end
    endtask
    initial begin
        #1;
        for (k=4;k<16;k=k+1) retired_once[k]=0;
        dut.u_if_stage.u_instr_mem.mem[0]={20'h20000,5'd1,7'h37};
        dut.u_if_stage.u_instr_mem.mem[1]=itype(36,1,2,2,7'h03);
        dut.u_if_stage.u_instr_mem.mem[2]=itype(1,2,7,2,7'h13);
        dut.u_if_stage.u_instr_mem.mem[3]=btype(-8,0,2);
        dut.u_if_stage.u_instr_mem.mem[4]=itype(1,0,0,3,7'h13);
        dut.u_if_stage.u_instr_mem.mem[5]=stype(40,3,1,2);
        dut.u_if_stage.u_instr_mem.mem[6]=stype(52,3,1,2);
        dut.u_if_stage.u_instr_mem.mem[7]=itype(32,1,2,4,7'h03);
        dut.u_if_stage.u_instr_mem.mem[8]=itype(24,1,2,0,7'h03);
        dut.u_if_stage.u_instr_mem.mem[9]=itype(24,1,2,5,7'h03);
        dut.u_if_stage.u_instr_mem.mem[10]=stype(16,5,1,2);
        dut.u_if_stage.u_instr_mem.mem[11]=itype(28,1,2,6,7'h03);
        dut.u_if_stage.u_instr_mem.mem[12]=itype(8,0,0,7,7'h13);
        dut.u_if_stage.u_instr_mem.mem[13]=stype(28,7,1,2);
        dut.u_if_stage.u_instr_mem.mem[14]=itype(28,1,2,8,7'h03);
        dut.u_if_stage.u_instr_mem.mem[15]=itype(77,0,0,9,7'h13);
        dut.u_if_stage.u_instr_mem.mem[16]=32'h0000006f;
        repeat (5) @(negedge clk); rst_n=1;
        send_frame(8'h00,0);
        send_frame(8'h55,1);
        send_frame(8'haa,1);
        if (dut.u_uart_rx_mmio.fifo_count !== 2 || !dut.u_uart_rx_mmio.frame_error_sticky)
            $fatal(1,"MMIO serial preparation failed");
        @(negedge clk); gpio_in=1;
        wait (software_done);
        wait (tx_frames==1);
        #(BIT_NS);
        if (gpio_toggle_writes!=1 || gpio_oe_writes!=1 || gpio_out!==1 || gpio_oe!==1 ||
            rx_reads!=2 || real_pops!=2 || w1c_writes!=1 || tx_accepts!=1 ||
            dut.u_uart_rx_mmio.fifo_count!==0 || dut.u_uart_rx_mmio.frame_error_sticky ||
            dut.uart_busy || tx!==1)
            $fatal(1,"MMIO once failure toggle=%0d RXreads=%0d pops=%0d W1C=%0d TX=%0d",
                   gpio_toggle_writes,rx_reads,real_pops,w1c_writes,tx_accepts);
        for (k=4;k<16;k=k+1)
            if (retired_once[k]!=1) $fatal(1,"MMIO instruction retirement count pc=%0d count=%0d",k*4,retired_once[k]);
        $display("MMIO PASS: request wait=3 response wait=7; one GPIO toggle, one TX frame, two RX pops including LW x0, one W1C");
        done=1;
    end
    always @(posedge clk) begin
        if (rst_n && !done) begin
            if (held && (!dut.mem_req_valid || descriptor !== held_desc))
                $fatal(1,"MMIO descriptor changed under request backpressure");
            held=dut.mem_req_valid&&!dut.mem_req_ready;
            if (held) held_desc=descriptor;
            if (fault) $fatal(1,"Unexpected local MMIO fault");
            if (dut.u_uart_rx_mmio.u_fifo.do_pop) real_pops=real_pops+1;
            if (dut.mem_req_fire) begin
                if (!dut.mem_req_mmio) $fatal(1,"MMIO test unexpectedly requested RAM");
                if (dut.mem_req_write) begin
                    case (dut.mem_addr_x)
                        32'h20000028: gpio_oe_writes=gpio_oe_writes+1;
                        32'h20000034: gpio_toggle_writes=gpio_toggle_writes+1;
                        32'h2000001c: w1c_writes=w1c_writes+1;
                        32'h20000010: ;
                        default: $fatal(1,"Unexpected MMIO store");
                    endcase
                end else if (dut.mem_addr_x==32'h20000018) begin
                    if (rx_reads>=2 || dut.mmio_read_data_x !== ((rx_reads==0)?32'h55:32'haa))
                        $fatal(1,"RX FIFO popped wrong byte index=%0d data=%h",rx_reads,dut.mmio_read_data_x);
                    rx_reads=rx_reads+1;
                end
            end
        end
        #1;
        if (rst_n && !done) begin
            if (dut.mmio_putchar_valid) begin
                tx_accepts=tx_accepts+1;
                if (tx_accepts!=1 || dut.mmio_putchar_data!==8'haa) $fatal(1,"Repeated/incorrect UART store");
            end
            if (retire_valid && wb_pc>=16 && wb_pc<=60) begin
                retired_once[wb_pc[5:2]]=retired_once[wb_pc[5:2]]+1;
                case (wb_pc)
                    20,24,40,52: if (wb_we) $fatal(1,"MMIO STORE wrote register file pc=%h",wb_pc);
                    28: if (!wb_we || wb_rd!=4 || wb_data!==1) $fatal(1,"GPIO toggle/readback");
                    32: if (wb_we) $fatal(1,"MMIO LW x0 wrote register");
                    36: if (!wb_we || wb_rd!=5 || wb_data!==32'haa) $fatal(1,"Delayed RX response lost pre-pop snapshot");
                    44: if (!wb_we || wb_rd!=6 || wb_data!==8) $fatal(1,"Frame-error status before W1C");
                    56: if (!wb_we || wb_rd!=8 || wb_data!==0) $fatal(1,"W1C status not cleared");
                    60: begin
                        if (!wb_we || wb_rd!=9 || wb_data!==77) $fatal(1,"MMIO completion sentinel");
                        software_done=1;
                    end
                    default: ;
                endcase
            end
        end
    end
    initial begin
        forever begin
            @(negedge tx);
            if (rst_n) begin
                #(BIT_NS/2);
                if (tx!==0) $fatal(1,"UART start bit");
                for (decode_bit=0;decode_bit<8;decode_bit=decode_bit+1) begin
                    #(BIT_NS); decoded[decode_bit]=tx;
                end
                #(BIT_NS);
                if (tx!==1 || decoded!==8'haa || tx_frames!=0) $fatal(1,"UART physical frame under MMIO wait");
                tx_frames=tx_frames+1;
            end
        end
    end
endmodule

module handshake_reset_error_case(output reg done=0);
    reg clk=0, rst_n=0;
    always #5 clk=~clk;
    reg allow_request=0, allow_response=0, inject_error=0, error_on_store=0;
    wire req_valid, req_write, rsp_ready, fault, retire_valid, wb_we;
    wire [31:0] req_addr, req_wdata, wb_pc, wb_data;
    wire [1:0] req_size;
    wire [3:0] req_wstrb;
    wire [4:0] wb_rd;
    reg active=0, rsp_valid=0, rsp_error=0;
    reg [31:0] rsp_rdata=0;
    reg [31:0] mem0=5, mem1=0;
    integer delay_count=0, requests=0, completions=0;
    integer phase=0, successes=0;
    reg normal_done=0;
    wire req_ready=rst_n && allow_request && !active;
    cpu_top #(
        .PROGRAM_FILE("programs/data_handshake_blank.hex"),
        .IMEM_WORDS(256), .DMEM_WORDS(64), .SIM_CONSOLE_ECHO(0), .EXTERNAL_DMEM(1)
    ) dut (
        .clk(clk),.rst_n(rst_n),.pc_x(),.instr_x(),.valid_x(),
        .wb_pc(wb_pc),.wb_rd(wb_rd),.wb_data(wb_data),.wb_we(wb_we),
        .retire_valid(retire_valid),.cycle_count(),.instret_count(),
        .uart_rx(1'b1),.uart_tx(),.gpio_in(8'd0),.gpio_out(),.gpio_oe(),
        .dmem_req_valid(req_valid),.dmem_req_ready(req_ready),.dmem_req_write(req_write),
        .dmem_req_addr(req_addr),.dmem_req_size(req_size),.dmem_req_wdata(req_wdata),
        .dmem_req_wstrb(req_wstrb),.dmem_rsp_valid(rsp_valid),.dmem_rsp_ready(rsp_ready),
        .dmem_rsp_rdata(rsp_rdata),.dmem_rsp_error(rsp_error),.dmem_fault(fault)
    );
    task reset_bus;
        begin
            @(negedge clk); rst_n=0;
            #1;
            if (req_valid || rsp_ready || fault || active || rsp_valid)
                $fatal(1,"Reset failed to clear CPU/model transaction");
            repeat (3) @(negedge clk);
        end
    endtask
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active<=0; rsp_valid<=0; rsp_error<=0; rsp_rdata<=0;
            delay_count<=0; requests=0; completions=0; mem0=5; mem1=0;
        end else begin
            if (req_valid && req_ready) begin
                if (requests==0) begin
                    if (req_write || req_addr!==0 || req_size!==2 || req_wstrb!==0)
                        $fatal(1,"Reset/error first transaction is not LW");
                    rsp_rdata<=mem0;
                end else if (requests==1) begin
                    if (!req_write || req_addr!==4 || req_wdata!==6 || req_wstrb!==15)
                        $fatal(1,"Reset/error result store mismatch");
                    mem1=req_wdata; rsp_rdata<=0;
                end else $fatal(1,"Repeated reset/error RAM request");
                requests=requests+1; active<=1; delay_count<=0;
                rsp_error<=inject_error && (error_on_store ? req_write : !req_write);
            end else if (active && !rsp_valid && allow_response) begin
                if (delay_count==3) rsp_valid<=1;
                else delay_count<=delay_count+1;
            end
            if (rsp_valid && rsp_ready) begin
                completions=completions+1; rsp_valid<=0; active<=0;
            end
        end
    end
    always @(posedge clk) begin
        #1;
        if (rst_n) begin
            if ((phase==0 || phase==1 || phase==3) && retire_valid && wb_pc>=4)
                $fatal(1,"Waiting/faulting load or later instruction retired phase=%0d pc=%h",phase,wb_pc);
            if ((phase==0 || phase==1 || phase==3) && wb_we && wb_pc>=4)
                $fatal(1,"Waiting/faulting load produced WB");
            if (phase==5 && retire_valid && wb_pc>=12)
                $fatal(1,"Waiting/faulting store or later instruction retired");
            if (phase==5 && wb_we && wb_pc>=12)
                $fatal(1,"Faulting store produced WB");
            if (retire_valid && wb_pc==12 && wb_we)
                $fatal(1,"Reset/error STORE wrote register file");
            if ((phase==2 || phase==4 || phase==6) && retire_valid && wb_pc==16) begin
                if (!wb_we || wb_rd!=4 || wb_data!==77 || mem1!==6 ||
                    requests!=2 || completions!=2 || fault)
                    $fatal(1,"Reset recovery program failed");
                normal_done=1;
            end
        end
    end
    initial begin
        #1;
        dut.u_if_stage.u_instr_mem.mem[0]=32'h00000093; // addi x1,x0,0
        dut.u_if_stage.u_instr_mem.mem[1]=32'h0000a103; // lw x2,0(x1)
        dut.u_if_stage.u_instr_mem.mem[2]=32'h00110193; // addi x3,x2,1
        dut.u_if_stage.u_instr_mem.mem[3]=32'h0030a223; // sw x3,4(x1)
        dut.u_if_stage.u_instr_mem.mem[4]=32'h04d00213; // addi x4,x0,77
        dut.u_if_stage.u_instr_mem.mem[5]=32'h0000006f;
        repeat (5) @(negedge clk); rst_n=1;
        wait (req_valid);
        repeat (6) begin
            @(posedge clk); #2;
            if (!req_valid || req_addr!==0 || req_write || requests!=0 || fault)
                $fatal(1,"Unaccepted request not held");
        end
        reset_bus();
        phase=1; allow_request=1; rst_n=1;
        wait (active);
        repeat (6) @(negedge clk);
        if (requests!=1 || completions!=0 || rsp_valid || fault)
            $fatal(1,"Accepted request completed before response");
        reset_bus();
        phase=2; allow_response=1; normal_done=0; rst_n=1;
        wait (normal_done); successes=successes+1;
        reset_bus();
        phase=3; inject_error=1; rst_n=1;
        wait (fault);
        repeat (12) begin
            @(posedge clk); #2;
            if (!fault || req_valid || wb_we || retire_valid || requests!=1 || completions!=1)
                $fatal(1,"Bus error did not latch a quiescent fault");
        end
        reset_bus();
        phase=4; inject_error=0; normal_done=0; rst_n=1;
        wait (normal_done); successes=successes+1;
        reset_bus();
        phase=5; inject_error=1; error_on_store=1; rst_n=1;
        wait (fault);
        repeat (12) begin
            @(posedge clk); #2;
            if (!fault || req_valid || wb_we || retire_valid || requests!=2 || completions!=2)
                $fatal(1,"Store error did not latch a quiescent fault");
        end
        reset_bus();
        phase=6; inject_error=0; normal_done=0; rst_n=1;
        wait (normal_done); successes=successes+1;
        if (successes!=3) $fatal(1,"Missing reset/load-fault/store-fault recovery run");
        $display("RESET/FAULT PASS: cancel unaccepted and accepted-wait requests, suppress load/store error retirement, recover after reset");
        done=1;
    end
endmodule
