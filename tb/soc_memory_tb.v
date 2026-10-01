`timescale 1ns/1ps
module soc_memory_tb;
    wire [3:0] done;
    reg test_pass=0;
    soc_instr_unit #(.WAIT_MODE(0)) instr_fast(done[0]);
    soc_instr_unit #(.WAIT_MODE(1)) instr_wait(done[1]);
    soc_data_unit #(.WAIT_MODE(0)) data_fast(done[2]);
    soc_data_unit #(.WAIT_MODE(1)) data_wait(done[3]);
    initial begin
        wait(&done);test_pass=1;
        $display("PASS: SoC memory endpoints: random master timing, response stability, IF consume/reissue, byte masks, illegal-access isolation, reset cancellation and accepted-write retention");
        $stop;
    end
    initial begin #100000; $fatal(1,"SoC memory endpoint timeout done=%b",done);end
endmodule

module soc_instr_unit #(parameter integer WAIT_MODE=0)(output reg done=0);
    reg clk=0,rst_n=0,req_valid=0,rsp_ready=0;
    always #5 clk=~clk;
    reg [31:0] req_addr=0;
    wire req_ready,rsp_valid,rsp_error;
    wire [31:0] rsp_rdata;
    reg pending=0,expected_error=0,held_req=0,held_rsp=0;
    reg [31:0] expected_data=0,held_addr=0,held_data=0;
    reg held_error=0;
    integer requests=0,responses=0,reissues=0,i;
    reg [31:0] random_q=32'h5724a91d ^ WAIT_MODE;
    soc_instr_mem #(
        .WORDS(256),.INIT_FILE("programs/data_handshake_blank.hex"),
        .REQ_WAIT_CYCLES(WAIT_MODE ? 2 : 0),.RSP_WAIT_CYCLES(WAIT_MODE ? 4 : 0)
    ) dut (
        .clk(clk),.rst_n(rst_n),.req_valid(req_valid),.req_ready(req_ready),
        .req_addr(req_addr),.rsp_valid(rsp_valid),.rsp_ready(rsp_ready),
        .rsp_rdata(rsp_rdata),.rsp_error(rsp_error)
    );
    task advance_random;
        begin random_q={random_q[30:0],random_q[31]^random_q[21]^random_q[1]^random_q[0]};end
    endtask
    task accept_only;
        input [31:0] address;
        begin
            @(negedge clk);req_addr=address;req_valid=1;
            @(posedge clk);while(!req_ready) @(posedge clk);
            @(negedge clk);req_valid=0;
        end
    endtask
    task consume;
        input integer extra_hold;
        integer n;
        begin
            wait(rsp_valid);
            for(n=0;n<extra_hold;n=n+1) @(negedge clk);
            @(negedge clk);rsp_ready=1;
            @(posedge clk);
            if(!rsp_valid) $fatal(1,"SoC IMEM response disappeared before consume");
            @(negedge clk);rsp_ready=0;
        end
    endtask
    task reset_endpoint;
        begin
            @(negedge clk);rst_n=0;req_valid=0;rsp_ready=0;
            repeat(2) @(negedge clk);
            if(rsp_valid || req_ready) $fatal(1,"SoC IMEM bus active during reset");
            rst_n=1;
        end
    endtask
    always @(posedge clk) begin
        if(!rst_n) begin
            pending=0;held_req=0;held_rsp=0;
            requests=0;responses=0;reissues=0;
        end else begin
            if(held_req && (!req_valid || req_addr!==held_addr)) $fatal(1,"SoC IMEM master changed blocked request");
            held_req=req_valid && !req_ready;if(held_req) held_addr=req_addr;
            if(held_rsp && (!rsp_valid || rsp_rdata!==held_data || rsp_error!==held_error))
                $fatal(1,"SoC IMEM response changed under backpressure");
            held_rsp=rsp_valid && !rsp_ready;
            if(held_rsp) begin held_data=rsp_rdata;held_error=rsp_error;end
            if(rsp_valid && rsp_ready) begin
                if(!pending || rsp_error!==expected_error ||
                   rsp_rdata !== (expected_error ? 32'd0 : expected_data))
                    $fatal(1,"SoC IMEM response mismatch mode=%0d data=%h expected=%h error=%b/%b",WAIT_MODE,rsp_rdata,expected_data,rsp_error,expected_error);
                pending=0;responses=responses+1;
                if(req_valid && req_ready) reissues=reissues+1;
            end
            if(req_valid && req_ready) begin
                if(pending) $fatal(1,"SoC IMEM multiple outstanding requests");
                expected_error=(req_addr[1:0]!=0 || req_addr>=1024);
                expected_data=32'ha5000000+(req_addr>>2);
                pending=1;requests=requests+1;
            end
        end
    end
    initial begin
        #1;for(i=0;i<256;i=i+1) dut.u_instr_mem.mem[i]=32'ha5000000+i;
        repeat(3) @(negedge clk);rst_n=1;
        // Continuous valid requests: zero-wait endpoint must consume the
        // previous response and accept the next address on each edge.
        @(negedge clk);req_valid=1;req_addr=0;rsp_ready=1;
        for(i=0;i<8;i=i+1) begin
            @(posedge clk);while(!req_ready) @(posedge clk);
            @(negedge clk);req_addr=(i+1)*4;
        end
        req_valid=0;wait(responses==8);
        @(negedge clk);rsp_ready=0;
        if(WAIT_MODE==0 && reissues!=7) $fatal(1,"SoC IMEM default throughput reissues=%0d expected=7",reissues);
        for(i=0;i<24;i=i+1) begin
            advance_random();repeat(random_q[1:0]) @(negedge clk);
            accept_only(random_q[7:0]*4);consume(random_q[5:3]);
        end
        accept_only(2);consume(3);             // alignment error
        accept_only(1024);consume(2);          // range error
        accept_only(0);consume(1);             // normal recovery without reset

        // A presented next request is blocked behind an unconsumed reply.
        accept_only(0);req_addr=4;req_valid=1;
        repeat(2) @(negedge clk);
        if(req_ready) $fatal(1,"SoC IMEM unaccepted reset setup");
        reset_endpoint();accept_only(0);consume(1);
        // Fixed-latency instance cancels before rsp_valid; fast instance
        // cancels before consuming its already-present response.
        accept_only(4);
        if(WAIT_MODE && rsp_valid) $fatal(1,"SoC IMEM accepted-wait setup");
        reset_endpoint();accept_only(0);consume(1);
        accept_only(8);wait(rsp_valid);repeat(3) @(negedge clk);
        reset_endpoint();accept_only(0);consume(2);
        $display("SOC IMEM unit %0d PASS: same-edge streaming, 24 random reads, alignment/range errors and three reset phases",WAIT_MODE);
        done=1;
    end
endmodule

module soc_data_unit #(parameter integer WAIT_MODE=0)(output reg done=0);
    localparam [31:0] BASE=32'h00010000;
    reg clk=0,rst_n=0,req_valid=0,req_write=0,rsp_ready=0;
    always #5 clk=~clk;
    reg [31:0] req_addr=BASE,req_wdata=0;
    reg [1:0] req_size=2;
    reg [3:0] req_wstrb=0;
    wire req_ready,rsp_valid,rsp_error;
    wire [31:0] rsp_rdata;
    reg [31:0] model_mem[0:15];
    reg pending=0,expected_error=0,held_req=0,held_rsp=0;
    reg [31:0] expected_data=0,held_data=0;
    reg held_error=0;
    reg [70:0] held_desc=0;
    wire [70:0] descriptor={req_write,req_addr,req_size,req_wdata,req_wstrb};
    reg [31:0] random_q=32'h61b4c58f ^ WAIT_MODE;
    integer requests=0,responses=0,bad_writes=0,i,lane,index;
    reg legal;
    reg [31:0] address;
    reg [1:0] size;
    reg [3:0] mask;
    soc_data_mem #(
        .WORDS(16),.BASE_ADDR(BASE),.INIT_FILE(""),
        .REQ_WAIT_CYCLES(WAIT_MODE ? 2 : 0),.RSP_WAIT_CYCLES(WAIT_MODE ? 4 : 0)
    ) dut (
        .clk(clk),.rst_n(rst_n),.req_valid(req_valid),.req_ready(req_ready),
        .req_write(req_write),.req_addr(req_addr),.req_size(req_size),
        .req_wdata(req_wdata),.req_wstrb(req_wstrb),
        .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_rdata(rsp_rdata),.rsp_error(rsp_error)
    );
    function [3:0] required_mask;
        input [1:0] access_size;input [1:0] offset;
        begin
            case(access_size)
                0:required_mask=4'b0001<<offset;
                1:required_mask=4'b0011<<offset;
                2:required_mask=4'b1111;
                default:required_mask=0;
            endcase
        end
    endfunction
    function valid_address;
        input [31:0] access_addr;input [1:0] access_size;
        begin
            valid_address=access_addr>=BASE && access_addr<BASE+64 && access_size!=3 &&
                ((access_size==0) || (access_size==1 && access_addr[0]==0) ||
                 (access_size==2 && access_addr[1:0]==0));
        end
    endfunction
    task advance_random;
        begin random_q={random_q[30:0],random_q[31]^random_q[21]^random_q[1]^random_q[0]};end
    endtask
    task start_request;
        input write_access;input [31:0] addr;input [1:0] access_size;
        input [31:0] data;input [3:0] strb;
        begin
            @(negedge clk);req_write=write_access;req_addr=addr;req_size=access_size;
            req_wdata=data;req_wstrb=strb;req_valid=1;
            @(posedge clk);while(!req_ready) @(posedge clk);
            @(negedge clk);req_valid=0;
        end
    endtask
    task consume;
        input integer extra_hold;integer n;
        begin
            wait(rsp_valid);
            for(n=0;n<extra_hold;n=n+1) @(negedge clk);
            @(negedge clk);rsp_ready=1;
            @(posedge clk);
            if(!rsp_valid) $fatal(1,"SoC DMEM response vanished");
            @(negedge clk);rsp_ready=0;
        end
    endtask
    task transaction;
        input write_access;input [31:0] addr;input [1:0] access_size;
        input [31:0] data;input [3:0] strb;input integer extra_hold;
        begin start_request(write_access,addr,access_size,data,strb);consume(extra_hold);end
    endtask
    task reset_endpoint;
        begin
            @(negedge clk);rst_n=0;req_valid=0;rsp_ready=0;
            repeat(2) @(negedge clk);
            if(rsp_valid || req_ready) $fatal(1,"SoC DMEM bus active in reset");
            for(index=0;index<16;index=index+1)
                if(dut.u_data_mem.mem[index]!==model_mem[index]) $fatal(1,"SoC DMEM reset cleared/changed RAM");
            rst_n=1;
        end
    endtask
    always @(posedge clk) begin
        if(!rst_n) begin
            pending=0;held_req=0;held_rsp=0;requests=0;responses=0;
        end else begin
            if(held_req && (!req_valid || descriptor!==held_desc)) $fatal(1,"SoC DMEM master changed blocked request");
            held_req=req_valid && !req_ready;if(held_req) held_desc=descriptor;
            if(held_rsp && (!rsp_valid || rsp_rdata!==held_data || rsp_error!==held_error))
                $fatal(1,"SoC DMEM response changed under backpressure");
            held_rsp=rsp_valid && !rsp_ready;
            if(held_rsp) begin held_data=rsp_rdata;held_error=rsp_error;end
            if(rsp_valid && rsp_ready) begin
                if(!pending || rsp_error!==expected_error || rsp_rdata!==expected_data)
                    $fatal(1,"SoC DMEM response mismatch mode=%0d data=%h/%h error=%b/%b",WAIT_MODE,rsp_rdata,expected_data,rsp_error,expected_error);
                pending=0;responses=responses+1;
                for(index=0;index<16;index=index+1)
                    if(dut.u_data_mem.mem[index]!==model_mem[index])
                        $fatal(1,"SoC DMEM accepted/illegal write side effect word=%0d",index);
            end
            if(req_valid && req_ready) begin
                if(pending) $fatal(1,"SoC DMEM multiple outstanding requests");
                legal=valid_address(req_addr,req_size) &&
                    (!req_write || req_wstrb==required_mask(req_size,req_addr[1:0]));
                expected_error=!legal;
                expected_data=(!legal || req_write) ? 0 : model_mem[(req_addr-BASE)>>2];
                if(req_write && legal)
                    for(lane=0;lane<4;lane=lane+1)
                        if(req_wstrb[lane]) model_mem[(req_addr-BASE)>>2][lane*8+:8]=req_wdata[lane*8+:8];
                if(req_write && !legal) bad_writes=bad_writes+1;
                pending=1;requests=requests+1;
            end
        end
    end
    initial begin
        for(i=0;i<16;i=i+1) model_mem[i]=0;
        repeat(3) @(negedge clk);rst_n=1;
        transaction(1,BASE,2,32'h80ff7f01,15,3);
        transaction(1,BASE+1,0,32'h00006600,2,2);
        transaction(1,BASE+2,1,32'hfabc0000,12,4);
        transaction(0,BASE,2,0,15,2); // read mask is ignored
        transaction(0,BASE+1,0,0,15,2);
        transaction(0,BASE+2,1,0,15,2);
        transaction(1,BASE+1,2,32'hffffffff,15,3); // misaligned word
        transaction(1,BASE+2,1,32'hffffffff,3,3);  // wrong halfword lanes
        transaction(1,BASE,0,32'hffffffff,15,3);   // extra byte lanes
        transaction(1,BASE,2,32'hffffffff,0,3);    // missing word lanes
        transaction(1,BASE,3,32'hffffffff,15,3);   // invalid size
        transaction(1,BASE-4,2,32'hffffffff,15,3);// below RAM
        transaction(1,BASE+64,2,32'hffffffff,15,3);// above RAM
        transaction(0,BASE+1,2,0,0,3);
        transaction(0,BASE+64,2,0,0,3);
        transaction(0,BASE,3,0,0,3);
        transaction(1,BASE+63,0,32'ha5000000,8,2);// last byte is valid
        transaction(1,BASE+62,1,32'h12340000,12,2);
        for(i=0;i<64;i=i+1) begin
            advance_random();repeat(random_q[1:0]) @(negedge clk);
            size=(random_q[3:2]==3) ? 2 : random_q[3:2];
            address=BASE+(random_q[7:4]*4);
            if(size==0) address=address+random_q[9:8];
            if(size==1) address=address+(random_q[8] ? 2 : 0);
            mask=required_mask(size,address[1:0]);
            transaction(random_q[10],address,size,random_q ^ 32'ha5a55a5a,
                        random_q[10] ? mask : 4'b1111,random_q[13:11]);
        end
        if(bad_writes!=7) $fatal(1,"SoC DMEM directed invalid write coverage");

        // An unaccepted next write must not survive reset behind a held reply.
        start_request(1,BASE,2,32'hdeadbeef,15);
        req_addr=BASE+4;req_wdata=32'hffffffff;req_valid=1;
        repeat(2) @(negedge clk);
        if(req_ready) $fatal(1,"SoC DMEM unaccepted reset setup");
        reset_endpoint();transaction(0,BASE,2,0,0,2);
        if(model_mem[0]!==32'hdeadbeef) $fatal(1,"SoC DMEM accepted write was rolled back");
        start_request(1,BASE+4,2,32'h12345678,15);
        if(WAIT_MODE && rsp_valid) $fatal(1,"SoC DMEM accepted-wait reset setup");
        reset_endpoint();transaction(0,BASE+4,2,0,15,1);
        start_request(1,BASE+8,2,32'h5a5aa5a5,15);
        wait(rsp_valid);repeat(3) @(negedge clk);
        reset_endpoint();transaction(0,BASE+8,2,0,0,3);
        $display("SOC DMEM unit %0d PASS: byte/halfword/word lanes, 64 random accesses, seven invalid writes without side effects, response hold, three reset phases and accepted-write retention",WAIT_MODE);
        done=1;
    end
endmodule
