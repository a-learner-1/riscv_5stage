`timescale 1ns/1ps
// Public-native-interface checks for cases a legal CPU cannot generate.
module d0_native_backend_tb;
    localparam [31:0] BASE=32'h10000;
    reg clk=0,rst_n=0,qv=0,qw=0,sr=0,allow_req=1,allow_rsp=1,ghost0=0,ghost1=0;
    reg [31:0] qa=0,qd=0;reg [1:0] qz=2;reg [3:0] qs=0;
    wire qr,sv,se;wire [31:0] sd;
    wire q0v,q0r,q0w,s0v,s0r,s0e,q1v,q1r,q1w,s1r;
    wire [31:0] q0a,q0d,s0d,q1a,q1d;wire [1:0] q0z,q1z;wire [3:0] q0s,q1s;
    wire ram_ready,ram_valid,ram_error,ram_rsp_ready;wire [31:0] ram_data;
    reg s1v=0,s1e=0;reg [31:0] s1d=0;
    integer r0=0,r1=0,c0=0,c1=0,checks=0,i;
    reg test_pass=0;
    always #5 clk=~clk;
    dmem_region_router #(.M0_BASE_ADDR(BASE),.M0_WORDS(16)) router(
        .clk(clk),.rst_n(rst_n),.req_valid(qv),.req_ready(qr),.req_write(qw),.req_addr(qa),.req_size(qz),.req_wdata(qd),.req_wstrb(qs),
        .rsp_valid(sv),.rsp_ready(sr),.rsp_rdata(sd),.rsp_error(se),
        .m0_req_valid(q0v),.m0_req_ready(q0r),.m0_req_write(q0w),.m0_req_addr(q0a),.m0_req_size(q0z),.m0_req_wdata(q0d),.m0_req_wstrb(q0s),
        .m0_rsp_valid((ram_valid&&allow_rsp)||ghost0),.m0_rsp_ready(s0r),.m0_rsp_rdata(ghost0?32'hdead0000:ram_data),.m0_rsp_error(ghost0||ram_error),
        .m1_req_valid(q1v),.m1_req_ready(q1r),.m1_req_write(q1w),.m1_req_addr(q1a),.m1_req_size(q1z),.m1_req_wdata(q1d),.m1_req_wstrb(q1s),
        .m1_rsp_valid(s1v||ghost1),.m1_rsp_ready(s1r),.m1_rsp_rdata(ghost1?32'hdead1111:s1d),.m1_rsp_error(ghost1||s1e));
    assign q0r=ram_ready&&allow_req;
    assign ram_rsp_ready=s0r&&allow_rsp&&!ghost0;
    soc_data_mem #(.WORDS(16),.BASE_ADDR(BASE),.INIT_FILE("")) ram(
        .clk(clk),.rst_n(rst_n),.req_valid(q0v&&allow_req),.req_ready(ram_ready),.req_write(q0w),.req_addr(q0a),
        .req_size(q0z),.req_wdata(q0d),.req_wstrb(q0s),.rsp_valid(ram_valid),.rsp_ready(ram_rsp_ready),.rsp_rdata(ram_data),.rsp_error(ram_error));
    assign q1r=rst_n&&!s1v&&allow_req;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin s1v<=0;s1e<=0;s1d<=0;end
        else begin
            if(q1v&&q1r) begin s1v<=1;s1e<=q1a!=32'h30000000;s1d<=q1w?0:32'hcafef00d;end
            if(s1v&&s1r&&!ghost1) s1v<=0;
        end
    end
    always @(posedge clk) if(rst_n) begin
        if(q0v&&q0r) r0=r0+1;if(q1v&&q1r) r1=r1+1;
        if(ram_valid&&ram_rsp_ready) c0=c0+1;if(s1v&&s1r&&!ghost1) c1=c1+1;
        if(q0v&&q1v) $fatal(1,"D0 router duplicated request to both regions");
        if(ghost0&&s0r||ghost1&&s1r) $fatal(1,"D0 router consumed an unselected response");
    end
    task reset_shared;
        begin @(negedge clk);rst_n=0;qv=0;sr=0;ghost0=0;ghost1=0;allow_req=1;allow_rsp=1;
            repeat(3) @(negedge clk);
            if(qr||sv||q0v||q1v||s0r||s1r||ram_valid||s1v) $fatal(1,"D0 reset did not cancel protocol state");
            rst_n=1;
        end
    endtask
    task transfer(input bit wr,input [31:0] addr,input [1:0] size,input [31:0] data,input [3:0] strb,
                  input bit error,input [31:0] expected,input bit target0,input bit cancel);
        integer br0,br1,bc0,bc1,k;
        begin br0=r0;br1=r1;bc0=c0;bc1=c1;
            @(negedge clk);allow_req=0;allow_rsp=0;qv=1;qw=wr;qa=addr;qz=size;qd=data;qs=strb;sr=0;
            repeat(3) begin @(posedge clk);#1;
                if(qr||sv||r0!=br0||r1!=br1) $fatal(1,"D0 request backpressure failed");
            end
            @(negedge clk);allow_req=1;
            @(posedge clk);if(!qr) $fatal(1,"D0 endpoint failed to accept released request");
            @(negedge clk);qv=0;qa=target0?32'h30000000:BASE;qd=32'h5555aaaa;qw=!wr;qz=3;qs=0;
            ghost1=target0;ghost0=!target0;
            if(target0) begin repeat(3) begin @(posedge clk);#1;if(sv||ram_rsp_ready) $fatal(1,"D0 response gate consumed hidden response");end end
            @(negedge clk);allow_rsp=1;
            while(!sv) @(negedge clk);
            repeat(7) begin @(posedge clk);#1;
                if(!sv||se!==error||sd!==expected||qr||q0v||q1v||c0!=bc0||c1!=bc1)
                    $fatal(1,"D0 locked response changed/consumed while held addr=%h data=%h error=%b",addr,sd,se);
                if(r0!=br0+(target0?1:0)||r1!=br1+(target0?0:1)) $fatal(1,"D0 duplicated or misrouted accepted request");
            end
            if(cancel) begin
                reset_shared;
                if(c0!=bc0||c1!=bc1) $fatal(1,"Reset consumed canceled D0 response");
            end else begin
                @(negedge clk);sr=1;@(posedge clk);@(negedge clk);sr=0;ghost0=0;ghost1=0;
                repeat(2) @(negedge clk);
                if(sv||c0!=bc0+(target0?1:0)||c1!=bc1+(target0?0:1)) $fatal(1,"D0 response was not consumed exactly once");
            end
            checks=checks+1;
        end
    endtask
    initial begin
        reset_shared;
        transfer(1,BASE,2,32'h11223344,15,0,0,1,0);
        transfer(1,BASE+1,0,32'h0000aa00,2,0,0,1,0);
        transfer(1,BASE+2,1,32'hbbcc0000,12,0,0,1,0);
        transfer(0,BASE,2,0,0,0,32'hbbccaa44,1,0);
        transfer(1,BASE+63,0,32'hdd000000,8,0,0,1,0);
        transfer(1,BASE+62,1,32'heeff0000,12,0,0,1,0);
        transfer(0,BASE+60,2,0,0,0,32'heeff0000,1,0);
        transfer(1,BASE,3,32'hffffffff,15,1,0,1,0);
        transfer(1,BASE,2,32'hffffffff,0,1,0,1,0);
        transfer(1,BASE+1,0,32'hffffffff,1,1,0,1,0);
        transfer(1,BASE+1,1,32'hffffffff,6,1,0,1,0);
        transfer(0,BASE+2,2,0,0,1,0,1,0);
        transfer(0,BASE,2,0,0,0,32'hbbccaa44,1,0);
        transfer(0,BASE-1,0,0,0,1,32'hcafef00d,0,0);
        transfer(0,BASE+64,2,0,0,1,32'hcafef00d,0,0);
        transfer(0,32'h30000000,2,0,0,0,32'hcafef00d,0,0);
        transfer(1,BASE,2,32'h76543210,15,0,0,1,1);
        transfer(0,BASE,2,0,0,0,32'h76543210,1,0);
        // Reset an unaccepted request: no downstream request or RAM mutation.
        @(negedge clk);allow_req=0;qv=1;qw=1;qa=BASE;qd=32'hffffffff;qs=15;qz=2;
        repeat(3) @(negedge clk);reset_shared;
        transfer(0,BASE,2,0,0,0,32'h76543210,1,0);
        if(checks!=19) $fatal(1,"D0 native coverage ledger incomplete");
        test_pass=1;$display("D0 NATIVE BACKEND TESTS PASS: 19 transactions, subwords/bounds/strobes, request and true response backpressure, locked routes, unselected responses and reset retained writes");$stop;
    end
    initial begin #200000;$fatal(1,"D0 native backend timeout");end
endmodule
