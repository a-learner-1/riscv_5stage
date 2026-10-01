`timescale 1ns/1ps

// Directed programs and bus responders are self-contained; no C toolchain
// or external FPGA platform is required for this regression.
module fetch_handshake_tb;
    wire [6:0] done;
    reg test_pass = 0;
    fetch_program_case #(.CASE_ID(0), .MODE(0)) local_fast(done[0]);
    fetch_program_case #(.CASE_ID(1), .MODE(1)) local_wait(done[1]);
    fetch_program_case #(.CASE_ID(2), .MODE(2)) external_random(done[2]);
    fetch_program_case #(.CASE_ID(3), .MODE(3)) blocked_redirect(done[3]);
    fetch_program_case #(.CASE_ID(4), .MODE(4)) stale_error(done[4]);
    fetch_reset_fault_case reset_fault(done[5]);
    fetch_frontend_boundary_case frontend_boundary(done[6]);
    initial begin
        wait (&done);
        $display("PASS: fetch handshake: default throughput, local/external waits, precise PC retirement, redirects, stable requests, stale errors, data stalls, reset, fault recovery and frontend access boundaries");
        test_pass = 1;
        $stop;
    end
    initial begin
        #200000;
        $fatal(1, "Fetch handshake timeout done=%b", done);
    end
endmodule

module fetch_frontend_boundary_case(output reg done=0);
    reg clk=0;
    always #5 clk=~clk;
    reg local_rst_n=0, local_redirect=0;
    reg [31:0] local_target=0;
    wire [31:0] local_pc_x, local_instr, local_fault_pc;
    wire local_valid, local_fault;
    reg external_rst_n=0, external_redirect=0, external_stall=0;
    reg [31:0] external_target=0;
    reg external_req_ready=0, external_rsp_valid=0, external_rsp_error=0;
    reg [31:0] external_rsp_rdata=0;
    wire external_req_valid, external_rsp_ready, external_valid, external_fault;
    wire [31:0] external_req_addr, external_pc_x, external_instr, external_fault_pc;
    reg local_done=0, external_done=0;
    integer k;

    // A 1 KiB local instruction RAM is deliberately smaller than the main
    // CPU's normal ROM. Use the existing full-length blank image to avoid
    // readmemh truncation diagnostics unrelated to these boundary checks.
    if_stage #(
        .PROGRAM_FILE("programs/data_handshake_blank.hex"), .IMEM_WORDS(256)
    ) local_dut (
        .clk(clk), .rst_n(local_rst_n), .redirect_x(local_redirect),
        .redirect_pc_x(local_target), .stall_x(1'b0), .pc_f(),
        .pc_x(local_pc_x), .instr_x(local_instr), .valid_x(local_valid),
        .imem_req_valid(), .imem_req_ready(1'b0), .imem_req_addr(),
        .imem_rsp_valid(1'b0), .imem_rsp_ready(), .imem_rsp_rdata(32'd0),
        .imem_rsp_error(1'b0), .imem_fault(local_fault), .imem_fault_pc(local_fault_pc)
    );
    if_stage #(
        .PROGRAM_FILE("programs/data_handshake_blank.hex"),
        .IMEM_WORDS(256), .EXTERNAL_IMEM(1)
    ) external_dut (
        .clk(clk), .rst_n(external_rst_n), .redirect_x(external_redirect),
        .redirect_pc_x(external_target), .stall_x(external_stall), .pc_f(),
        .pc_x(external_pc_x), .instr_x(external_instr), .valid_x(external_valid),
        .imem_req_valid(external_req_valid), .imem_req_ready(external_req_ready),
        .imem_req_addr(external_req_addr), .imem_rsp_valid(external_rsp_valid),
        .imem_rsp_ready(external_rsp_ready), .imem_rsp_rdata(external_rsp_rdata),
        .imem_rsp_error(external_rsp_error), .imem_fault(external_fault),
        .imem_fault_pc(external_fault_pc)
    );

    task local_reset_recover;
        begin
            @(negedge clk); local_rst_n=0; local_redirect=0;
            repeat(2) @(negedge clk);
            if(local_fault || local_valid || local_dut.fetch_req_valid)
                $fatal(1,"Frontend local boundary reset did not clear state");
            local_rst_n=1;
            wait(local_valid);
            #1;
            if(local_pc_x !== 0 || local_instr !== 32'h00000013 || local_fault)
                $fatal(1,"Frontend local boundary reset did not recover PC 0");
        end
    endtask
    task local_fault_at;
        input [31:0] address;
        begin
            @(negedge clk); local_target=address; local_redirect=1;
            @(negedge clk); local_redirect=0;
            wait(local_fault);
            #1;
            if(local_fault_pc !== address || local_valid || local_dut.fetch_req_valid)
                $fatal(1,"Frontend access fault mismatch target=%h pc=%h valid=%b request=%b",address,local_fault_pc,local_valid,local_dut.fetch_req_valid);
            repeat(4) @(negedge clk);
            if(!local_fault || local_fault_pc !== address || local_valid || local_dut.fetch_req_valid)
                $fatal(1,"Frontend local access fault did not remain stopped");
            // A redirect alone cannot clear the sticky frontend stop.
            local_target=0; local_redirect=1;
            @(negedge clk); local_redirect=0;
            if(!local_fault || local_valid || local_dut.fetch_req_valid)
                $fatal(1,"Frontend local fault was cleared by redirect instead of reset");
        end
    endtask

    always @(posedge clk) begin
        #1;
        if(local_rst_n && local_valid &&
           (local_pc_x[1:0] != 0 || local_pc_x >= 1024))
            $fatal(1,"Frontend executed an unaligned/out-of-range response pc=%h",local_pc_x);
    end

    initial begin
        local_reset_recover();
        local_fault_at(2);
        local_reset_recover();
        local_fault_at(1024);
        local_reset_recover();
        local_done=1;
    end
    initial begin
        repeat(3) @(negedge clk); external_rst_n=1;
        wait(external_req_valid);
        @(negedge clk); external_req_ready=1;
        @(posedge clk);
        if(external_req_addr !== 0) $fatal(1,"Frontend external initial PC");
        @(negedge clk); external_req_ready=0;
        repeat(2) @(negedge clk);

        // The old PC 0 error and redirect are sampled on the SAME edge.
        // The frontend must drain the error, avoid sticky fault, and may
        // accept the new target on that edge without reusing old metadata.
        external_target=64; external_redirect=1;
        external_rsp_rdata=32'hffffffff; external_rsp_error=1;
        external_rsp_valid=1; external_req_ready=1;
        @(posedge clk);
        if(!external_rsp_ready || !external_req_valid || external_req_addr !== 64)
            $fatal(1,"Frontend redirect/error coincidence did not drain and target PC 64");
        @(negedge clk);
        external_redirect=0; external_rsp_valid=0; external_rsp_error=0;
        external_req_ready=0;
        if(external_fault || external_valid)
            $fatal(1,"Frontend redirected stale error became a fault/instruction");
        external_rsp_rdata=32'h06300193; // addi x3,x0,99
        external_rsp_valid=1;
        @(posedge clk);
        if(!external_rsp_ready) $fatal(1,"Frontend target response was not accepted");
        #1;
        if(external_fault || !external_valid || external_pc_x !== 64 ||
           external_instr !== 32'h06300193)
            $fatal(1,"Frontend target PC/instruction metadata after stale error");
        @(negedge clk); external_rsp_valid=0; external_stall=1;
        repeat(3) @(negedge clk);
        if(external_fault) $fatal(1,"Frontend stale error latched late");
        external_done=1;
    end
    initial begin
        wait(local_done && external_done);
        $display("FETCH FRONTEND BOUNDARY PASS: unaligned PC 2 and out-of-range PC 1024 stop with exact fault PC, reset recovery, coincident redirect/old error discarded with correct new target");
        done=1;
    end
endmodule

module fetch_program_case #(
    parameter integer CASE_ID = 0,
    // 0: default local; 1: fixed local; 2: random external;
    // 3: blocked old request during redirect; 4: accepted old error response.
    parameter integer MODE = 0
) (output reg done = 0);
    reg clk=0, rst_n=0;
    always #5 clk=~clk;
    wire req_valid, rsp_ready, imem_fault, dmem_fault;
    wire [31:0] req_addr, fault_pc, wb_pc, wb_data;
    wire [4:0] wb_rd;
    wire wb_we, retire_valid;
    wire [7:0] gpio_out, gpio_oe;
    reg rsp_valid=0, rsp_error=0, active=0;
    reg [31:0] rsp_rdata=0, pending_addr=0;
    reg [31:0] random_q=32'h52a4653b ^ CASE_ID;
    reg [31:0] program_rom [0:63];
    reg [31:0] expected_pc [0:17];
    integer rsp_wait=0, blocked20_wait=0;
    integer requests=0, responses=0, retired=0, cycles=0;
    integer last_retire_cycle=-1, request_block_cycles=0;
    integer redirect_blocked=0, redirect_accepted=0, stale_errors=0;
    integer data_response_overlap=0, gpio_writes=0;
    integer i;
    reg held_req=0, held_rsp=0;
    reg [31:0] held_addr=0, held_rdata=0;
    reg held_error=0;
    wire response_fire=rsp_valid && rsp_ready;
    wire ready_slot=!active || response_fire;
    wire ready_gate=(MODE == 2) ? random_q[0] :
        ((MODE == 3) && req_addr == 20) ? (blocked20_wait >= 4) : 1'b1;
    wire req_ready=rst_n && ready_slot && ready_gate;

    cpu_top #(
        .PROGRAM_FILE("programs/data_handshake_blank.hex"),
        .IMEM_WORDS(256), .DMEM_WORDS(64), .SIM_CONSOLE_ECHO(0),
        .EXTERNAL_IMEM(MODE >= 2),
        .IMEM_REQ_WAIT_CYCLES((MODE == 1) ? 3 : 0),
        .IMEM_RSP_WAIT_CYCLES((MODE == 1) ? 5 : 0),
        .DMEM_REQ_WAIT_CYCLES(3), .DMEM_RSP_WAIT_CYCLES(8)
    ) dut (
        .clk(clk), .rst_n(rst_n), .pc_x(), .instr_x(), .valid_x(),
        .wb_pc(wb_pc), .wb_rd(wb_rd), .wb_data(wb_data), .wb_we(wb_we),
        .retire_valid(retire_valid), .cycle_count(), .instret_count(),
        .uart_rx(1'b1), .uart_tx(), .gpio_in(8'd0),
        .gpio_out(gpio_out), .gpio_oe(gpio_oe),
        .dmem_req_valid(), .dmem_req_ready(1'b0), .dmem_req_write(),
        .dmem_req_addr(), .dmem_req_size(), .dmem_req_wdata(), .dmem_req_wstrb(),
        .dmem_rsp_valid(1'b0), .dmem_rsp_ready(), .dmem_rsp_rdata(32'd0),
        .dmem_rsp_error(1'b0), .dmem_fault(dmem_fault),
        .imem_req_valid(req_valid), .imem_req_ready(req_ready), .imem_req_addr(req_addr),
        .imem_rsp_valid(rsp_valid), .imem_rsp_ready(rsp_ready),
        .imem_rsp_rdata(rsp_rdata), .imem_rsp_error(rsp_error),
        .imem_fault(imem_fault), .imem_fault_pc(fault_pc)
    );

    function [31:0] itype;
        input integer imm; input [4:0] rs1; input [2:0] f3;
        input [4:0] rd; input [6:0] op;
        begin itype={imm[11:0],rs1,f3,rd,op}; end
    endfunction
    function [31:0] stype;
        input integer imm; input [4:0] rs2,rs1;
        begin stype={imm[11:5],rs2,rs1,3'b010,imm[4:0],7'h23}; end
    endfunction
    function [31:0] btype;
        input integer imm;
        begin btype={imm[12],imm[10:5],5'd0,5'd0,3'b000,imm[4:1],imm[11],7'h63}; end
    endfunction
    function [31:0] jtype;
        input integer imm; input [4:0] rd;
        begin jtype={imm[20],imm[10:1],imm[11],imm[19:12],rd,7'h6f}; end
    endfunction

    initial begin
        #1;
        for(i=0;i<64;i=i+1) program_rom[i]=32'h00000013;
        program_rom[0]=itype(0,0,0,1,7'h13);
        program_rom[1]=itype(7,0,0,2,7'h13);
        program_rom[2]=itype(1,2,0,2,7'h13);
        program_rom[3]={20'h20000,5'd10,7'h37};
        program_rom[4]=btype(12);
        program_rom[5]=stype(4,2,1);           // wrong-path RAM
        program_rom[6]=stype(52,2,10);         // wrong-path GPIO
        program_rom[7]=itype(2,2,0,3,7'h13);
        program_rom[8]=jtype(12,4);
        program_rom[9]=stype(8,3,1);           // wrong-path RAM
        program_rom[10]=stype(16,3,10);        // wrong-path UART TX
        program_rom[11]=itype(60,0,0,5,7'h13);
        program_rom[12]=itype(4,5,0,5,7'h13);
        program_rom[13]=itype(0,5,0,6,7'h67);
        program_rom[14]=stype(12,3,1);         // wrong-path RAM
        program_rom[15]=stype(52,3,10);        // wrong-path GPIO
        program_rom[16]=stype(0,3,1);
        program_rom[17]=itype(0,1,2,7,7'h03);
        program_rom[18]=itype(5,7,0,8,7'h13);
        program_rom[19]=stype(16,8,1);
        program_rom[20]=itype(1,0,0,9,7'h13);
        program_rom[21]=stype(40,9,10);
        program_rom[22]=stype(52,9,10);
        program_rom[23]=itype(77,0,0,11,7'h13);
        program_rom[24]=jtype(0,0);
        for(i=0;i<64;i=i+1) dut.u_if_stage.u_instr_mem.mem[i]=program_rom[i];
        for(i=0;i<64;i=i+1) dut.u_data_mem.mem[i]=0;
        expected_pc[0]=0; expected_pc[1]=4; expected_pc[2]=8;
        expected_pc[3]=12; expected_pc[4]=16; expected_pc[5]=28;
        expected_pc[6]=32; expected_pc[7]=44; expected_pc[8]=48;
        expected_pc[9]=52; expected_pc[10]=64; expected_pc[11]=68;
        expected_pc[12]=72; expected_pc[13]=76; expected_pc[14]=80;
        expected_pc[15]=84; expected_pc[16]=88; expected_pc[17]=92;
        repeat(5) @(negedge clk);
        rst_n=1;
    end

    // One accepted outstanding operation, with same-edge response/reissue.
    // The response is visible only AFTER its acceptance edge and is held
    // until the master consumes it. Reset cancels the endpoint as well.
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            active<=0; rsp_valid<=0; rsp_error<=0; rsp_rdata<=0;
            pending_addr<=0; rsp_wait<=0; blocked20_wait<=0;
            random_q<=32'h52a4653b ^ CASE_ID;
            requests=0; responses=0;
        end else if(MODE >= 2) begin
            random_q<={random_q[30:0],random_q[31]^random_q[21]^random_q[1]^random_q[0]};
            if(req_valid && req_addr == 20 && !req_ready)
                blocked20_wait<=blocked20_wait+1;
            if(response_fire) begin
                if(!active) $fatal(1,"Fetch case %0d unsolicited response",CASE_ID);
                responses=responses+1;
                active<=0; rsp_valid<=0;
            end
            if(req_valid && req_ready) begin
                if(active && !response_fire) $fatal(1,"Fetch case %0d multiple outstanding",CASE_ID);
                if(req_addr[1:0] != 0 || req_addr >= 256)
                    $fatal(1,"Fetch case %0d unexpected address %h",CASE_ID,req_addr);
                requests=requests+1;
                pending_addr<=req_addr;
                rsp_rdata<=program_rom[req_addr[7:2]];
                rsp_error<=((MODE == 3 || MODE == 4) && req_addr == 20);
                rsp_wait<=(MODE == 2) ? random_q[4:2] :
                    ((MODE == 4 && req_addr == 20) ? 5 : 0);
                rsp_valid<=(MODE != 2 && !(MODE == 4 && req_addr == 20)) ||
                    (MODE == 2 && random_q[4:2] == 0);
                active<=1;
            end else if(active && !rsp_valid) begin
                if(rsp_wait <= 1) rsp_valid<=1;
                else rsp_wait<=rsp_wait-1;
            end
        end
    end

    always @(posedge clk) begin
        if(!rst_n) begin
            held_req=0; held_rsp=0; retired=0; cycles=0;
            last_retire_cycle=-1; request_block_cycles=0;
            redirect_blocked=0; redirect_accepted=0; stale_errors=0;
            data_response_overlap=0; gpio_writes=0;
        end else if(!done) begin
            cycles=cycles+1;
            if(MODE >= 2) begin
                if(held_req && (!req_valid || req_addr !== held_addr))
                    $fatal(1,"Fetch case %0d blocked request withdrawn/changed old=%h new=%h valid=%b",CASE_ID,held_addr,req_addr,req_valid);
                held_req=req_valid && !req_ready;
                if(held_req) begin held_addr=req_addr; request_block_cycles=request_block_cycles+1; end
                if(held_rsp && (!rsp_valid || rsp_rdata !== held_rdata || rsp_error !== held_error))
                    $fatal(1,"Fetch case %0d endpoint response changed while held",CASE_ID);
                held_rsp=rsp_valid && !rsp_ready;
                if(held_rsp) begin held_rdata=rsp_rdata; held_error=rsp_error; end
                if(dut.redirect_x && held_req && req_addr == 20) redirect_blocked=redirect_blocked+1;
                if(dut.redirect_x && active && pending_addr == 20) redirect_accepted=redirect_accepted+1;
                if(response_fire && rsp_error) stale_errors=stale_errors+1;
                if(dut.stall_x && rsp_valid && !rsp_ready) data_response_overlap=data_response_overlap+1;
            end
            if(dut.mem_req_fire && dut.mem_req_mmio) begin
                if(dut.mem_pc_q != 84 && dut.mem_pc_q != 88 &&
                   dut.pc_x != 84 && dut.pc_x != 88)
                    $fatal(1,"Fetch case %0d wrong-path MMIO request pc=%h",CASE_ID,dut.pc_x);
                gpio_writes=gpio_writes+1;
            end
            if(imem_fault || dmem_fault) $fatal(1,"Fetch case %0d unexpected fault pc=%h",CASE_ID,fault_pc);
        end
        #1;
        if(rst_n && !done && retire_valid) begin
            if(retired >= 18 || wb_pc !== expected_pc[retired])
                $fatal(1,"Fetch case %0d retire index=%0d expected=%h actual=%h",CASE_ID,retired,expected_pc[retired],wb_pc);
            if(MODE == 0 && retired > 0 && retired <= 4 && cycles != last_retire_cycle+1)
                $fatal(1,"Default fetch throughput lost at pc=%h cycle=%0d previous=%0d",wb_pc,cycles,last_retire_cycle);
            last_retire_cycle=cycles;
            case(wb_pc)
                8: if(!wb_we || wb_rd != 2 || wb_data !== 8) $fatal(1,"ALU forwarding");
                28: if(!wb_we || wb_rd != 3 || wb_data !== 10) $fatal(1,"Branch target");
                32: if(!wb_we || wb_rd != 4 || wb_data !== 36) $fatal(1,"JAL link");
                52: if(!wb_we || wb_rd != 6 || wb_data !== 56) $fatal(1,"JALR link/forwarding");
                68: if(!wb_we || wb_rd != 7 || wb_data !== 10) $fatal(1,"Load result");
                72: if(!wb_we || wb_rd != 8 || wb_data !== 15) $fatal(1,"Load-use result");
                64,76,84,88: if(wb_we) $fatal(1,"Store wrote register");
                92: begin
                    if(!wb_we || wb_rd != 11 || wb_data !== 77) $fatal(1,"Fetch completion sentinel");
                    if(dut.u_data_mem.mem[0] !== 10 || dut.u_data_mem.mem[4] !== 15 ||
                       dut.u_data_mem.mem[1] !== 0 || dut.u_data_mem.mem[2] !== 0 || dut.u_data_mem.mem[3] !== 0)
                        $fatal(1,"Fetch case %0d wrong-path/final RAM data",CASE_ID);
                    if(gpio_writes != 2 || gpio_out !== 1 || gpio_oe !== 1)
                        $fatal(1,"Fetch case %0d GPIO side effects writes=%0d out=%h oe=%h",CASE_ID,gpio_writes,gpio_out,gpio_oe);
                    if(MODE == 3 && redirect_blocked == 0) $fatal(1,"No blocked request crossed redirect");
                    if(MODE == 4 && redirect_accepted == 0) $fatal(1,"No accepted response crossed redirect");
                    if((MODE == 3 || MODE == 4) && stale_errors == 0) $fatal(1,"No stale error drained");
                    if(MODE >= 2 && data_response_overlap == 0) $fatal(1,"No instruction response backpressure during data stall");
                    $display("FETCH case %0d PASS: 18 precise retirements, blocked requests=%0d redirect blocked/accepted=%0d/%0d stale errors=%0d data overlap=%0d",CASE_ID,request_block_cycles,redirect_blocked,redirect_accepted,stale_errors,data_response_overlap);
                    done=1;
                end
                default: ;
            endcase
            retired=retired+1;
        end
    end
endmodule

module fetch_reset_fault_case(output reg done=0);
    reg clk=0, rst_n=0;
    always #5 clk=~clk;
    wire req_valid, rsp_ready, imem_fault, dmem_fault;
    wire [31:0] req_addr, fault_pc, wb_pc, wb_data;
    wire [4:0] wb_rd;
    wire retire_valid, wb_we;
    reg req_ready=0, rsp_valid=0, rsp_error=0;
    reg [31:0] rsp_rdata=0;
    integer outstanding=0, store_retirements=0, old_retirements=0;
    integer accepted=0, returned=0, k;
    reg held=0;
    reg [31:0] held_addr=0;

    cpu_top #(
        .PROGRAM_FILE("programs/data_handshake_blank.hex"),
        .IMEM_WORDS(256), .DMEM_WORDS(64), .SIM_CONSOLE_ECHO(0),
        .EXTERNAL_IMEM(1), .DMEM_REQ_WAIT_CYCLES(3), .DMEM_RSP_WAIT_CYCLES(30)
    ) dut (
        .clk(clk), .rst_n(rst_n), .pc_x(), .instr_x(), .valid_x(),
        .wb_pc(wb_pc), .wb_rd(wb_rd), .wb_data(wb_data), .wb_we(wb_we),
        .retire_valid(retire_valid), .cycle_count(), .instret_count(),
        .uart_rx(1'b1), .uart_tx(), .gpio_in(8'd0), .gpio_out(), .gpio_oe(),
        .dmem_req_valid(), .dmem_req_ready(1'b0), .dmem_req_write(),
        .dmem_req_addr(), .dmem_req_size(), .dmem_req_wdata(), .dmem_req_wstrb(),
        .dmem_rsp_valid(1'b0), .dmem_rsp_ready(), .dmem_rsp_rdata(32'd0),
        .dmem_rsp_error(1'b0), .dmem_fault(dmem_fault),
        .imem_req_valid(req_valid), .imem_req_ready(req_ready), .imem_req_addr(req_addr),
        .imem_rsp_valid(rsp_valid), .imem_rsp_ready(rsp_ready),
        .imem_rsp_rdata(rsp_rdata), .imem_rsp_error(rsp_error),
        .imem_fault(imem_fault), .imem_fault_pc(fault_pc)
    );
    function [31:0] addi;
        input integer imm; input [4:0] rs1,rd;
        begin addi={imm[11:0],rs1,3'b000,rd,7'h13}; end
    endfunction

    task accept_request;
        input [31:0] address;
        begin
            wait(req_valid);
            @(negedge clk);
            if(req_addr !== address) $fatal(1,"Reset/fault expected req %h actual %h",address,req_addr);
            req_ready=1;
            @(posedge clk);
            if(!req_valid || req_addr !== address) $fatal(1,"Reset/fault request vanished");
            @(negedge clk); req_ready=0;
        end
    endtask
    task send_response;
        input [31:0] instruction; input error;
        begin
            rsp_rdata=instruction; rsp_error=error; rsp_valid=1;
            @(posedge clk);
            while(!rsp_ready) @(posedge clk);
            @(negedge clk); rsp_valid=0; rsp_error=0;
        end
    endtask
    task reset_both;
        begin
            @(negedge clk); rst_n=0; req_ready=0; rsp_valid=0; rsp_error=0;
            repeat(3) @(negedge clk);
            if(req_valid || rsp_ready || imem_fault || dmem_fault)
                $fatal(1,"Fetch bus/fault not cleared by reset");
            rst_n=1;
        end
    endtask
    task prove_recovery;
        begin
            accept_request(0); send_response(addi(77,0,1),0);
            wait(retire_valid && wb_pc == 0);
            #1;
            if(!wb_we || wb_rd != 1 || wb_data !== 77 || imem_fault)
                $fatal(1,"Fetch reset recovery failed");
            repeat(2) @(negedge clk);
        end
    endtask

    always @(posedge clk) begin
        if(!rst_n) begin
            outstanding=0; accepted=0; returned=0; held=0;
            store_retirements=0; old_retirements=0;
        end else begin
            if(held && (!req_valid || req_addr !== held_addr)) $fatal(1,"Reset/fault request changed without reset");
            held=req_valid && !req_ready;
            if(held) held_addr=req_addr;
            if(rsp_valid && rsp_ready) begin
                if(outstanding != 1) $fatal(1,"Reset/fault unsolicited response");
                outstanding=outstanding-1; returned=returned+1;
            end
            if(req_valid && req_ready) begin
                if(outstanding != 0) $fatal(1,"Reset/fault overlapping request");
                outstanding=outstanding+1; accepted=accepted+1;
            end
            if(dmem_fault) $fatal(1,"Unexpected data fault in fetch test");
        end
        #1;
        if(rst_n && retire_valid) begin
            old_retirements=old_retirements+1;
            if(wb_pc == 8) store_retirements=store_retirements+1;
            if(imem_fault && wb_pc == 12) $fatal(1,"Faulting instruction retired");
        end
    end

    initial begin
        #1;
        for(k=0;k<64;k=k+1) dut.u_data_mem.mem[k]=0;
        repeat(3) @(negedge clk); rst_n=1;

        // Reset cancels a request that was presented but never accepted.
        wait(req_valid); repeat(3) @(negedge clk);
        if(outstanding != 0) $fatal(1,"Unaccepted reset setup");
        reset_both(); prove_recovery();

        // Reset cancels an accepted request whose response has not arrived.
        reset_both(); accept_request(0);
        repeat(3) @(negedge clk);
        if(outstanding != 1 || rsp_valid) $fatal(1,"Accepted-wait reset setup");
        reset_both(); prove_recovery();

        // A younger response is held while the older load is stalled.
        // Reset cancels both before that response can reach EX.
        reset_both(); accept_request(0); send_response(32'h00002103,0); // lw x2,0(x0)
        accept_request(4);
        rsp_rdata=addi(99,0,3); rsp_error=0; rsp_valid=1;
        repeat(3) @(negedge clk);
        if(!dut.stall_x || rsp_ready || !rsp_valid)
            $fatal(1,"Response-backpressure reset setup");
        reset_both(); prove_recovery();

        // A real-path instruction error must wait for the older accepted
        // STORE to complete and retire once. It cannot cancel its side effect.
        reset_both();
        accept_request(0); send_response(addi(0,0,1),0);
        accept_request(4); send_response(addi(13,0,2),0);
        accept_request(8); send_response(32'h0020a023,0); // sw x2,0(x1)
        accept_request(12);
        rsp_rdata=addi(99,0,3); rsp_error=1; rsp_valid=1;
        repeat(5) @(negedge clk);
        if(!dut.stall_x || imem_fault || rsp_ready)
            $fatal(1,"Fetch fault incorrectly interrupted older data transaction");
        @(posedge clk); while(!rsp_ready) @(posedge clk);
        @(negedge clk); rsp_valid=0; rsp_error=0;
        wait(imem_fault);
        #1;
        if(fault_pc !== 12 || store_retirements != 1 || dut.u_data_mem.mem[0] !== 13)
            $fatal(1,"Fetch fault PC/older store completion pc=%h retire=%0d mem=%h",fault_pc,store_retirements,dut.u_data_mem.mem[0]);
        k=old_retirements;
        repeat(6) @(negedge clk);
        if(req_valid || old_retirements != k || !imem_fault)
            $fatal(1,"Fetch fault did not remain halted until reset");
        reset_both(); prove_recovery();
        $display("FETCH RESET/FAULT PASS: unaccepted, accepted-wait and held-response cancellation; older STORE completes before current-path error; sticky fault and reset recovery");
        done=1;
    end
endmodule
