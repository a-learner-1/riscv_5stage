`timescale 1ns/1ps

// Self-contained RV32I stream: no compiler or newly built firmware needed.
// The existing blank image only initializes the unused internal CPU ROM.
module cpu_cycle_profile_tb;
    wire [4:0] done;
    reg test_pass = 0;
    cpu_cycle_profile_case #(.CASE_ID(0), .PRED(0), .DELAYED(0)) off_fast(done[0]);
    cpu_cycle_profile_case #(.CASE_ID(1), .PRED(1), .DELAYED(0)) on_fast(done[1]);
    cpu_cycle_profile_case #(.CASE_ID(2), .PRED(0), .DELAYED(1)) off_waits(done[2]);
    cpu_cycle_profile_case #(.CASE_ID(3), .PRED(1), .DELAYED(1)) on_waits(done[3]);
    cpu_cycle_profile_fault_case fault_stop(done[4]);
    initial begin
        wait (&done);
        test_pass = 1;
        $display("CPU CYCLE PROFILE PASS: six buckets, exact cycle sum, retire trace, once-only stores, pending resets and fault stop");
        $stop;
    end
    initial begin
        #1000000;
        $fatal(1, "CPU cycle profile timeout done=%b", done);
    end
endmodule

module cpu_cycle_profile_case #(
    parameter integer CASE_ID = 0,
    parameter integer PRED = 0,
    parameter integer DELAYED = 0
) (output reg done = 0);
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    wire [5:0] events;
    wire [63:0] cycle_count;
    wire [31:0] pc_x, wb_pc, wb_data;
    wire [4:0] wb_rd;
    wire valid_x, wb_we, retire_valid, imem_fault, dmem_fault, trap_valid;
    wire [7:0] gpio_out;
    wire iq_valid, iq_ready, ip_ready;
    wire [31:0] iq_addr;
    reg ip_valid = 0, ip_active = 0;
    reg [31:0] ip_data = 0;
    integer ip_delay = 0;
    wire dq_valid, dq_ready, dq_write, dp_ready;
    wire [31:0] dq_addr, dq_data;
    wire [3:0] dq_strb;
    reg dp_valid = 0, dp_active = 0;
    reg [31:0] dp_data = 0;
    integer dp_delay = 0;
    reg [31:0] ram [0:15];
    reg [31:0] rom [0:63];
    integer phase = 0, tick = 0;
    integer writes = 0, reads = 0, mmio_writes = 0, mmio_reads = 0;
    integer blocked_i = 0, blocked_d = 0, held_i_response = 0;
    integer retired = 0, expected_count = 0, i, b, n;
    reg [31:0] expected_pc [0:31];
    reg [63:0] buckets [0:5];
    reg [63:0] expected_cycles = 0;
    reg [5:0] expected_event = 0;
    reg expected_started = 0, recovery = 0;
    reg held_d = 0, held_i = 0;
    reg [31:0] held_d_addr = 0, held_d_data = 0, held_i_addr = 0;
    reg [3:0] held_d_strb = 0;
    reg held_d_write = 0;
    wire i_response_fire = ip_valid && ip_ready;
    assign iq_ready = rst_n && (!ip_active || i_response_fire) &&
                      (!DELAYED || tick % 3 != 1);
    assign dq_ready = rst_n && !dp_active && (!DELAYED || tick % 4 == 0);

    cpu_top #(.PROGRAM_FILE("programs/data_handshake_blank.hex"),
        .IMEM_WORDS(256), .DMEM_WORDS(16), .DMEM_BASE_ADDR(0),
        .SIM_CONSOLE_ECHO(0), .ENABLE_TRAPS(1), .ENABLE_BRANCH_PRED(PRED),
        .EXTERNAL_IMEM(1), .EXTERNAL_DMEM(1),
        .DMEM_REQ_WAIT_CYCLES(2), .DMEM_RSP_WAIT_CYCLES(4)) dut (
        .clk(clk), .rst_n(rst_n), .pc_x(pc_x), .instr_x(), .valid_x(valid_x),
        .wb_pc(wb_pc), .wb_rd(wb_rd), .wb_data(wb_data), .wb_we(wb_we),
        .retire_valid(retire_valid), .cycle_count(cycle_count), .instret_count(),
        .uart_tx(), .uart_rx(1'b1), .gpio_in(8'd0), .gpio_out(gpio_out), .gpio_oe(),
        .dmem_req_valid(dq_valid), .dmem_req_ready(dq_ready), .dmem_req_write(dq_write),
        .dmem_req_addr(dq_addr), .dmem_req_size(), .dmem_req_wdata(dq_data), .dmem_req_wstrb(dq_strb),
        .dmem_rsp_valid(dp_valid), .dmem_rsp_ready(dp_ready), .dmem_rsp_rdata(dp_data),
        .dmem_rsp_error(1'b0), .dmem_fault(dmem_fault),
        .imem_req_valid(iq_valid), .imem_req_ready(iq_ready), .imem_req_addr(iq_addr),
        .imem_rsp_valid(ip_valid), .imem_rsp_ready(ip_ready), .imem_rsp_rdata(ip_data),
        .imem_rsp_error(1'b0), .imem_fault(imem_fault), .imem_fault_pc(),
        .trap_valid(trap_valid), .trap_pc(), .trap_cause(), .trap_tval(),
        .irq_external(1'b0), .perf_cycle_events(events)
    );
    function [31:0] addi;
        input integer imm; input [4:0] rs1, rd;
        begin addi = {imm[11:0], rs1, 3'b000, rd, 7'h13}; end
    endfunction
    function [31:0] load;
        input integer imm; input [4:0] rs1, rd;
        begin load = {imm[11:0], rs1, 3'b010, rd, 7'h03}; end
    endfunction
    function [31:0] store;
        input integer imm; input [4:0] rs2, rs1;
        begin store = {imm[11:5], rs2, rs1, 3'b010, imm[4:0], 7'h23}; end
    endfunction
    function [31:0] bne;
        input integer offset; input [4:0] rs2, rs1;
        begin bne = {offset[12], offset[10:5], rs2, rs1, 3'b001,
                     offset[4:1], offset[11], 7'h63}; end
    endfunction
    task expect_pc;
        input [31:0] address;
        begin expected_pc[expected_count] = address; expected_count = expected_count + 1; end
    endtask
    task reset_cpu;
        begin
            @(negedge clk); rst_n = 0;
            #1;
            if (events !== 0 || cycle_count !== 0 || dut.perf_redirect_pending !== 0)
                $fatal(1, "case %0d reset retained profiler event/recovery", CASE_ID);
            repeat (3) @(negedge clk);
            rst_n = 1;
        end
    endtask
    initial begin
        for (i=0; i<64; i=i+1) rom[i] = 32'h00000013;
        rom[0] = addi(0,0,1);
        rom[1] = addi(37,0,2);
        rom[2] = store(0,2,1);
        rom[3] = load(0,1,3);
        rom[4] = addi(5,3,3);
        rom[5] = store(4,3,1);
        rom[6] = {20'h20000,5'd10,7'h37};
        rom[7] = store(32,3,10);
        rom[8] = load(32,10,4);
        rom[9] = bne(20,4,3); // must not take the wrong-path RAM store
        rom[10] = addi(3,0,5);
        rom[11] = addi(-1,5,5);
        rom[12] = bne(-4,0,5);
        rom[13] = 32'h0080006f; // JAL x0,+8
        rom[14] = store(8,2,1); // never executed
        rom[15] = {12'd85,5'd4,3'b100,5'd6,7'h13}; // XORI => 127
        rom[16] = store(52,6,10); // GPIO XOR; replay would corrupt final value
        rom[17] = load(32,10,7);
        rom[18] = store(8,7,1);
        rom[19] = addi(77,0,13);
        rom[20] = 32'h0000006f;
        for (i=0; i<=10; i=i+1) expect_pc(i*4);
        repeat (3) begin expect_pc(44); expect_pc(48); end
        expect_pc(52); expect_pc(60); expect_pc(64); expect_pc(68); expect_pc(72); expect_pc(76);
        repeat (3) @(negedge clk); rst_n = 1;
        // Reset while a counted data operation is still pending. No event
        // or transaction from this abandoned epoch may leak into the next.
        wait (dut.mem_active && dut.stall_x);
        reset_cpu();
        phase = 1;
        // Also reset an in-progress ordinary branch recovery interval.
        wait (dut.perf_redirect_pending && !valid_x);
        reset_cpu();
        phase = 2;
    end

    // Independent, single-outstanding ROM and RAM endpoint models. Their
    // request ready and response delay are independently varied; data requests
    // and instruction responses must remain stable under backpressure.
    always @(posedge clk) begin
        if (!rst_n) begin
            tick <= 0;
            ip_active <= 0; ip_valid <= 0; ip_data <= 0; ip_delay <= 0;
            dp_active <= 0; dp_valid <= 0; dp_data <= 0; dp_delay <= 0;
            writes <= 0; reads <= 0;
            for (n=0; n<16; n=n+1) ram[n] <= 0;
        end else begin
            tick <= tick+1;
            if (i_response_fire) begin ip_active <= 0; ip_valid <= 0; end
            if (iq_valid && iq_ready) begin
                if (iq_addr[1:0] || iq_addr >= 256)
                    $fatal(1, "case %0d invalid ROM address %h", CASE_ID, iq_addr);
                ip_active <= 1; ip_valid <= 0;
                ip_data <= rom[iq_addr >> 2];
                ip_delay <= DELAYED ? 2 + tick % 5 : 1;
            end else if (ip_active && !ip_valid) begin
                if (ip_delay <= 1) ip_valid <= 1;
                else ip_delay <= ip_delay-1;
            end
            if (dp_valid && dp_ready) begin dp_active <= 0; dp_valid <= 0; end
            if (dq_valid && dq_ready) begin
                if (dq_addr[1:0] || dq_addr >= 64)
                    $fatal(1, "case %0d invalid RAM address %h", CASE_ID, dq_addr);
                dp_active <= 1; dp_valid <= 0;
                dp_data <= ram[dq_addr >> 2];
                dp_delay <= DELAYED ? 3 + tick % 7 : 1;
                if (dq_write) begin
                    writes <= writes+1;
                    for (b=0; b<4; b=b+1)
                        if (dq_strb[b]) ram[dq_addr >> 2][b*8 +: 8] <= dq_data[b*8 +: 8];
                end else reads <= reads+1;
            end else if (dp_active && !dp_valid) begin
                if (dp_delay <= 1) dp_valid <= 1;
                else dp_delay <= dp_delay-1;
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            expected_cycles = 0; expected_started = 0; expected_event = 0;
            recovery = 0; retired = 0; mmio_writes = 0; mmio_reads = 0;
            blocked_i = 0; blocked_d = 0; held_i_response = 0;
            held_d = 0; held_i = 0;
            for (i=0; i<6; i=i+1) buckets[i] = 0;
        end else if (!done) begin
            expected_event = 0;
            if (expected_started || (valid_x && dut.instr_supported_x)) begin
                expected_started = 1;
                expected_cycles = expected_cycles+1;
                if (dut.stall_x && (dut.mem_active || dut.mem_start_x)) begin
                    if (dut.mem_req_mmio) expected_event = 6'b010000;
                    else if (dut.mem_req_write) expected_event = 6'b001000;
                    else expected_event = 6'b000100;
                end else if (!valid_x && recovery && !dut.trap_event && !dut.mret_commit_x &&
                             !imem_fault && !dmem_fault)
                    expected_event = 6'b100000;
                else if (!valid_x && !imem_fault && !dmem_fault)
                    expected_event = 6'b000010;
                else expected_event = 6'b000001;
            end
            if (dut.trap_event || dut.mret_commit_x || imem_fault || dmem_fault) recovery = 0;
            else if (dut.redirect_x && dut.normal_redirect_x) recovery = 1;
            else if (valid_x) recovery = 0;
            if (held_d && (!dq_valid || dq_addr !== held_d_addr || dq_data !== held_d_data ||
                           dq_strb !== held_d_strb || dq_write !== held_d_write))
                $fatal(1, "case %0d changed held RAM request", CASE_ID);
            held_d = dq_valid && !dq_ready;
            if (held_d) begin
                blocked_d = blocked_d+1; held_d_addr = dq_addr;
                held_d_data = dq_data; held_d_strb = dq_strb; held_d_write = dq_write;
            end
            if (held_i && (!iq_valid || iq_addr !== held_i_addr))
                $fatal(1, "case %0d changed held ROM request", CASE_ID);
            held_i = iq_valid && !iq_ready;
            if (held_i) begin blocked_i = blocked_i+1; held_i_addr = iq_addr; end
            if (ip_valid && !ip_ready) held_i_response = held_i_response+1;
            if (dut.mem_req_fire && dut.mem_req_mmio) begin
                if (dut.mem_req_write) mmio_writes = mmio_writes+1;
                else mmio_reads = mmio_reads+1;
            end
            if (imem_fault || dmem_fault || trap_valid)
                $fatal(1, "case %0d unexpected fault or trap", CASE_ID);
        end
        #1;
        if (!rst_n) begin
            if (events !== 0 || cycle_count !== 0)
                $fatal(1, "case %0d emitted reset event", CASE_ID);
        end else if (!done) begin
            if (events !== expected_event || cycle_count !== expected_cycles)
                $fatal(1, "case %0d classification/enable mismatch events=%b expected=%b cycles=%0d expected=%0d",
                    CASE_ID, events, expected_event, cycle_count, expected_cycles);
            if (events != 0 && ((events & (events-1)) != 0))
                $fatal(1, "case %0d overlapping primary events %b", CASE_ID, events);
            for (i=0; i<6; i=i+1) if (events[i]) buckets[i] = buckets[i]+1;
            if (buckets[0]+buckets[1]+buckets[2]+buckets[3]+buckets[4]+buckets[5] !== cycle_count)
                $fatal(1, "case %0d classified cycles do not sum to cycle_count", CASE_ID);
            if (retire_valid) begin
                if (retired >= expected_count || wb_pc !== expected_pc[retired])
                    $fatal(1, "case %0d retire replay/wrong path index=%0d pc=%h expected=%h",
                        CASE_ID, retired, wb_pc, expected_pc[retired]);
                retired = retired+1;
                if (wb_pc == 76 && phase == 2) begin
                    if (retired != expected_count || !wb_we || wb_rd != 13 || wb_data != 77 ||
                        writes != 3 || reads != 1 || mmio_writes != 2 || mmio_reads != 2 ||
                        ram[0] != 37 || ram[1] != 42 || ram[2] != 85 || gpio_out != 85)
                        $fatal(1, "case %0d architectural/store count mismatch", CASE_ID);
                    for (i=0; i<6; i=i+1)
                        if (buckets[i] == 0) $fatal(1, "case %0d uncovered bucket %0d", CASE_ID, i);
                    if (DELAYED && (blocked_i == 0 || blocked_d == 0))
                        $fatal(1, "case %0d did not exercise request backpressure", CASE_ID);
                    $display("CPU cycle profile case %0d PASS cycles=%0d work=%0d ifetch=%0d read=%0d write=%0d mmio=%0d redirect=%0d",
                        CASE_ID, cycle_count, buckets[0], buckets[1], buckets[2], buckets[3], buckets[4], buckets[5]);
                    done = 1;
                end
            end
        end
    end
endmodule

// An ordinary JAL redirects to an instruction response error with traps
// disabled. The halted CPU still advances cycle_count, but those cycles must
// be work_other, never an indefinitely pending branch recovery or fetch wait.
module cpu_cycle_profile_fault_case(output reg done = 0);
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    wire [5:0] events;
    wire [63:0] cycles;
    wire fault, req_valid, rsp_ready;
    wire [31:0] req_addr;
    reg active = 0, rsp_valid = 0, rsp_error = 0;
    reg [31:0] rsp_data = 32'h00000013;
    wire req_ready = rst_n && !active;
    integer epoch, hold_cycle;
    reg [63:0] previous_cycles;

    cpu_top #(.PROGRAM_FILE("programs/data_handshake_blank.hex"),
        .IMEM_WORDS(256), .DMEM_WORDS(16), .SIM_CONSOLE_ECHO(0),
        .ENABLE_TRAPS(0), .ENABLE_BRANCH_PRED(0), .EXTERNAL_IMEM(1)) dut (
        .clk(clk), .rst_n(rst_n), .pc_x(), .instr_x(), .valid_x(),
        .wb_pc(), .wb_rd(), .wb_data(), .wb_we(), .retire_valid(),
        .cycle_count(cycles), .instret_count(), .uart_tx(), .uart_rx(1'b1),
        .gpio_in(8'd0), .gpio_out(), .gpio_oe(),
        .dmem_req_valid(), .dmem_req_ready(1'b0), .dmem_req_write(),
        .dmem_req_addr(), .dmem_req_size(), .dmem_req_wdata(), .dmem_req_wstrb(),
        .dmem_rsp_valid(1'b0), .dmem_rsp_ready(), .dmem_rsp_rdata(32'd0),
        .dmem_rsp_error(1'b0), .dmem_fault(),
        .imem_req_valid(req_valid), .imem_req_ready(req_ready), .imem_req_addr(req_addr),
        .imem_rsp_valid(rsp_valid), .imem_rsp_ready(rsp_ready), .imem_rsp_rdata(rsp_data),
        .imem_rsp_error(rsp_error), .imem_fault(fault), .imem_fault_pc(),
        .trap_valid(), .trap_pc(), .trap_cause(), .trap_tval(),
        .irq_external(1'b0), .perf_cycle_events(events)
    );
    always @(posedge clk) begin
        if (!rst_n) begin
            active <= 0; rsp_valid <= 0; rsp_error <= 0;
            rsp_data <= 32'h00000013;
        end else begin
            if (rsp_valid && rsp_ready) begin active <= 0; rsp_valid <= 0; end
            if (req_valid && req_ready) begin
                active <= 1; rsp_valid <= 0;
                rsp_data <= req_addr == 0 ? 32'h0400006f : 32'h00000013;
                rsp_error <= req_addr == 32'h40;
            end else if (active && !rsp_valid)
                rsp_valid <= 1;
        end
    end
    initial begin
        for (epoch=0; epoch<2; epoch=epoch+1) begin
            repeat (3) @(negedge clk);
            rst_n = 1;
            wait (dut.perf_redirect_pending);
            wait (fault);
            // Event and cycle_count are registered descriptions of the
            // preceding edge. Check the first edge AFTER the sticky fault.
            #1; previous_cycles = cycles;
            for (hold_cycle=0; hold_cycle<8; hold_cycle=hold_cycle+1) begin
                @(posedge clk); #1;
                if (events !== 6'b000001 || cycles !== previous_cycles+1 ||
                    dut.perf_redirect_pending !== 0 || !fault)
                    $fatal(1, "fault-stop epoch %0d misclassified halted cycle events=%b", epoch, events);
                previous_cycles = cycles;
            end
            @(negedge clk); rst_n = 0;
            #1;
            if (events !== 0 || cycles !== 0 || fault !== 0 || dut.perf_redirect_pending !== 0)
                $fatal(1, "fault-stop reset retained event, cycle or recovery state");
        end
        done = 1;
    end
endmodule
