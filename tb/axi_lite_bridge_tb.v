`timescale 1ns/1ps

// Independent directed AXI4-Lite BFM. It never inspects bridge state.
// Address/data pairing and RAM byte writes are implemented by the slave
// scoreboard, so an accepted half-write has no side effect before pairing.
// Shared reset cancels channel state but deliberately preserves RAM contents.
module axi_lite_bridge_tb;
    reg clk=0, rst_n=0;
    always #5 clk=~clk;
    reg req_valid=0, req_write=0;
    reg [31:0] req_addr=0, req_wdata=0;
    reg [1:0] req_size=0;
    reg [3:0] req_wstrb=0;
    wire req_ready, rsp_valid, rsp_error;
    wire [31:0] rsp_rdata;
    reg rsp_ready=0;
    wire [31:0] awaddr, wdata, araddr;
    wire [2:0] awprot, arprot;
    wire [3:0] wstrb;
    wire awvalid, wvalid, bready, arvalid, rready;
    reg awready=0, wready=0, arready=0;
    reg bvalid=0, rvalid=0;
    reg [1:0] bresp=0, rresp=0;
    reg [31:0] rdata=0;
    reg test_pass=0;

    dmem_axi_lite_bridge dut (
        .clk(clk),.rst_n(rst_n),
        .req_valid(req_valid),.req_ready(req_ready),.req_write(req_write),
        .req_addr(req_addr),.req_size(req_size),.req_wdata(req_wdata),.req_wstrb(req_wstrb),
        .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_rdata(rsp_rdata),.rsp_error(rsp_error),
        .m_axi_awaddr(awaddr),.m_axi_awprot(awprot),.m_axi_awvalid(awvalid),.m_axi_awready(awready),
        .m_axi_wdata(wdata),.m_axi_wstrb(wstrb),.m_axi_wvalid(wvalid),.m_axi_wready(wready),
        .m_axi_bresp(bresp),.m_axi_bvalid(bvalid),.m_axi_bready(bready),
        .m_axi_araddr(araddr),.m_axi_arprot(arprot),.m_axi_arvalid(arvalid),.m_axi_arready(arready),
        .m_axi_rdata(rdata),.m_axi_rresp(rresp),.m_axi_rvalid(rvalid),.m_axi_rready(rready)
    );

    reg [31:0] mem[0:63];
    reg slave_aw_seen=0, slave_w_seen=0, slave_paired=0, slave_read_pending=0;
    reg [31:0] slave_aw_addr=0, slave_w_data=0, slave_read_data=0;
    reg [3:0] slave_w_strb=0;
    reg [31:0] last_aw_addr=0,last_w_data=0,last_ar_addr=0;
    reg [3:0] last_w_strb=0;
    time last_aw_time=0,last_w_time=0;
    integer cpu_requests=0,cpu_responses=0,cpu_errors=0;
    integer aw_count=0,w_count=0,b_count=0,ar_count=0,r_count=0,paired_writes=0;
    integer aw_stalls=0,w_stalls=0,ar_stalls=0,cpu_rsp_stalls=0;
    integer order_aw_first=0,order_w_first=0,order_same=0;
    integer invalid_cases=0,reset_cases=0,abandoned_requests=0;
    integer i,lane;
    reg aw_held=0,w_held=0,ar_held=0,rsp_held=0;
    reg [34:0] aw_payload_q=0,ar_payload_q=0;
    reg [35:0] w_payload_q=0;
    reg [32:0] rsp_payload_q=0;

    // Persistent memory initialization is separate from protocol reset.
    initial for (i=0;i<64;i=i+1) mem[i]=32'ha0000000^i;

    // Scoreboard samples only VALID && READY at the active clock edge.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            slave_aw_seen=0; slave_w_seen=0; slave_paired=0; slave_read_pending=0;
            slave_aw_addr=0; slave_w_data=0; slave_w_strb=0; slave_read_data=0;
            aw_held=0; w_held=0; ar_held=0; rsp_held=0;
        end else begin
            if (aw_held && (!awvalid || {awaddr,awprot}!==aw_payload_q))
                $fatal(1,"AW VALID/payload changed under backpressure");
            if (w_held && (!wvalid || {wdata,wstrb}!==w_payload_q))
                $fatal(1,"W VALID/payload changed under backpressure");
            if (ar_held && (!arvalid || {araddr,arprot}!==ar_payload_q))
                $fatal(1,"AR VALID/payload changed under backpressure");
            if (rsp_held && (!rsp_valid || {rsp_rdata,rsp_error}!==rsp_payload_q))
                $fatal(1,"CPU response changed under backpressure");
            aw_held=awvalid&&!awready; w_held=wvalid&&!wready;
            ar_held=arvalid&&!arready; rsp_held=rsp_valid&&!rsp_ready;
            if (aw_held) begin aw_payload_q={awaddr,awprot}; aw_stalls=aw_stalls+1; end
            if (w_held) begin w_payload_q={wdata,wstrb}; w_stalls=w_stalls+1; end
            if (ar_held) begin ar_payload_q={araddr,arprot}; ar_stalls=ar_stalls+1; end
            if (rsp_held) begin rsp_payload_q={rsp_rdata,rsp_error}; cpu_rsp_stalls=cpu_rsp_stalls+1; end

            if (req_valid&&req_ready) cpu_requests=cpu_requests+1;
            if (rsp_valid&&rsp_ready) begin
                cpu_responses=cpu_responses+1;
                if (rsp_error) cpu_errors=cpu_errors+1;
            end
            if (awvalid&&awready) begin
                if (slave_aw_seen||slave_read_pending) $fatal(1,"Duplicate/overlapping AW acceptance");
                if (awaddr[1:0]!==0 || awaddr>=256 || awprot!==0) $fatal(1,"Invalid AXI AW payload");
                slave_aw_seen=1; slave_aw_addr=awaddr;
                last_aw_addr=awaddr; last_aw_time=$time; aw_count=aw_count+1;
            end
            if (wvalid&&wready) begin
                if (slave_w_seen||slave_read_pending) $fatal(1,"Duplicate/overlapping W acceptance");
                slave_w_seen=1; slave_w_data=wdata; slave_w_strb=wstrb;
                last_w_data=wdata; last_w_strb=wstrb; last_w_time=$time; w_count=w_count+1;
            end
            if (slave_aw_seen&&slave_w_seen&&!slave_paired) begin
                for (lane=0;lane<4;lane=lane+1)
                    if (slave_w_strb[lane]) mem[slave_aw_addr[7:2]][lane*8+:8]=slave_w_data[lane*8+:8];
                slave_paired=1; paired_writes=paired_writes+1;
            end
            if (bvalid&&bready) begin
                if (!slave_paired) $fatal(1,"B accepted before one AW and one W");
                b_count=b_count+1;
                slave_aw_seen=0; slave_w_seen=0; slave_paired=0;
            end
            if (arvalid&&arready) begin
                if (slave_read_pending||slave_aw_seen||slave_w_seen) $fatal(1,"Duplicate/overlapping AR acceptance");
                if (araddr[1:0]!==0 || araddr>=256 || arprot!==0) $fatal(1,"Invalid AXI AR payload");
                slave_read_pending=1; slave_read_data=mem[araddr[7:2]];
                last_ar_addr=araddr; ar_count=ar_count+1;
            end
            if (rvalid&&rready) begin
                if (!slave_read_pending) $fatal(1,"R accepted without AR");
                r_count=r_count+1; slave_read_pending=0;
            end
        end
    end

    task tick;
        begin @(posedge clk); #1; end
    endtask
    task joint_reset;
        begin
            @(negedge clk); rst_n=0;
            req_valid=0; rsp_ready=0; awready=0; wready=0; arready=0;
            bvalid=0; rvalid=0; bresp=0; rresp=0; rdata=0;
            #1;
            if (req_ready || rsp_valid || awvalid || wvalid || arvalid || bready || rready ||
                slave_aw_seen || slave_w_seen || slave_paired || slave_read_pending)
                $fatal(1,"Shared reset did not clear channel state");
            repeat (3) @(negedge clk);
            rst_n=1;
            tick();
            if (!req_ready || rsp_valid || awvalid || wvalid || arvalid)
                $fatal(1,"Bridge did not return to idle after reset");
        end
    endtask
    task start_request;
        input write_access;
        input [31:0] addr;
        input [1:0] size;
        input [31:0] data;
        input [3:0] strb;
        integer before_accept;
        begin
            before_accept=cpu_requests;
            @(negedge clk);
            req_valid=1; req_write=write_access; req_addr=addr;
            req_size=size; req_wdata=data; req_wstrb=strb;
            while (cpu_requests==before_accept) tick();
            if (cpu_requests!=before_accept+1) $fatal(1,"CPU request accepted more than once");
            @(negedge clk); req_valid=0;
        end
    endtask
    task accept_write_channels;
        input integer channel_order;
        integer old_aw,old_w;
        begin
            old_aw=aw_count; old_w=w_count;
            // Both channels see backpressure before acceptance. This also
            // proves VALID does not wait for the slave to raise READY.
            repeat (3) tick();
            if (!awvalid || !wvalid) $fatal(1,"Write VALID depends on READY");
            if (channel_order==0) begin
                @(negedge clk); awready=1;
                while (aw_count==old_aw) tick();
                @(negedge clk); awready=0;
                repeat (4) tick();
                if (w_count!=old_w || awvalid || !wvalid) $fatal(1,"AW-first sequencing");
                @(negedge clk); wready=1;
                while (w_count==old_w) tick();
                @(negedge clk); wready=0;
                if (!(last_aw_time<last_w_time)) $fatal(1,"AW-first order not exercised");
                order_aw_first=order_aw_first+1;
            end else if (channel_order==1) begin
                @(negedge clk); wready=1;
                while (w_count==old_w) tick();
                @(negedge clk); wready=0;
                repeat (4) tick();
                if (aw_count!=old_aw || wvalid || !awvalid) $fatal(1,"W-first sequencing");
                @(negedge clk); awready=1;
                while (aw_count==old_aw) tick();
                @(negedge clk); awready=0;
                if (!(last_w_time<last_aw_time)) $fatal(1,"W-first order not exercised");
                order_w_first=order_w_first+1;
            end else begin
                @(negedge clk); awready=1; wready=1;
                while (aw_count==old_aw || w_count==old_w) tick();
                @(negedge clk); awready=0; wready=0;
                if (last_aw_time!=last_w_time) $fatal(1,"Simultaneous write channels not exercised");
                order_same=order_same+1;
            end
            if (aw_count!=old_aw+1 || w_count!=old_w+1 || !slave_paired)
                $fatal(1,"Write did not pair exactly one AW and one W");
        end
    endtask
    task deliver_b;
        input [1:0] response;
        integer before_b;
        begin
            before_b=b_count;
            repeat (3) tick();
            @(negedge clk); bresp=response; bvalid=1;
            while (b_count==before_b) tick();
            @(negedge clk); bvalid=0;
        end
    endtask
    task accept_read_channel;
        integer before_ar;
        begin
            before_ar=ar_count;
            repeat (4) tick();
            if (!arvalid) $fatal(1,"Read VALID depends on READY");
            @(negedge clk); arready=1;
            while (ar_count==before_ar) tick();
            @(negedge clk); arready=0;
            if (ar_count!=before_ar+1 || !slave_read_pending) $fatal(1,"Read accepted more than once");
        end
    endtask
    task deliver_r;
        input [1:0] response;
        integer before_r;
        begin
            before_r=r_count;
            repeat (2) tick();
            @(negedge clk);
            rdata=(response==0)?slave_read_data:32'hbad0e770;
            rresp=response; rvalid=1;
            while (r_count==before_r) tick();
            @(negedge clk); rvalid=0;
        end
    endtask
    task consume_cpu_response;
        input expected_error;
        input [31:0] expected_data;
        integer before_rsp;
        begin
            before_rsp=cpu_responses;
            while (!rsp_valid) tick();
            if (rsp_error!==expected_error || rsp_rdata!==expected_data)
                $fatal(1,"CPU response mismatch error=%b data=%h expected=%b/%h",
                       rsp_error,rsp_rdata,expected_error,expected_data);
            repeat (5) begin
                tick();
                if (!rsp_valid || req_ready || rsp_error!==expected_error || rsp_rdata!==expected_data)
                    $fatal(1,"CPU response not retained during backpressure");
            end
            @(negedge clk); rsp_ready=1;
            while (cpu_responses==before_rsp) tick();
            @(negedge clk); rsp_ready=0;
            tick();
            if (cpu_responses!=before_rsp+1 || rsp_valid || !req_ready)
                $fatal(1,"CPU response did not complete exactly once");
        end
    endtask
    task write_case;
        input [31:0] addr;
        input [1:0] size;
        input [31:0] data;
        input [3:0] strb;
        input integer channel_order;
        input [1:0] response;
        integer old_aw,old_w,old_b,old_ar,old_r;
        begin
            old_aw=aw_count;old_w=w_count;old_b=b_count;old_ar=ar_count;old_r=r_count;
            start_request(1,addr,size,data,strb);
            accept_write_channels(channel_order);
            if (last_aw_addr!==(addr&32'hfffffffc) || last_w_data!==data || last_w_strb!==strb)
                $fatal(1,"Bridge altered aligned address or pre-shifted write data/strobes");
            deliver_b(response);
            consume_cpu_response(response!=0,0);
            if (aw_count!=old_aw+1 || w_count!=old_w+1 || b_count!=old_b+1 ||
                ar_count!=old_ar || r_count!=old_r) $fatal(1,"Write AXI channel count");
        end
    endtask
    task read_case;
        input [31:0] addr;
        input [1:0] size;
        input [31:0] expected_data;
        input [1:0] response;
        integer old_aw,old_w,old_b,old_ar,old_r;
        begin
            old_aw=aw_count;old_w=w_count;old_b=b_count;old_ar=ar_count;old_r=r_count;
            start_request(0,addr,size,0,0);
            accept_read_channel();
            if (last_ar_addr!==(addr&32'hfffffffc)) $fatal(1,"Read address not word aligned");
            deliver_r(response);
            consume_cpu_response(response!=0,(response==0)?expected_data:0);
            if (ar_count!=old_ar+1 || r_count!=old_r+1 || aw_count!=old_aw ||
                w_count!=old_w || b_count!=old_b) $fatal(1,"Read AXI channel count");
        end
    endtask
    task invalid_case;
        input write_access;
        input [31:0] addr;
        input [1:0] size;
        input [3:0] strb;
        integer old_aw,old_w,old_b,old_ar,old_r;
        begin
            old_aw=aw_count;old_w=w_count;old_b=b_count;old_ar=ar_count;old_r=r_count;
            start_request(write_access,addr,size,32'h11223344,strb);
            consume_cpu_response(1,0);
            if (aw_count!=old_aw || w_count!=old_w || b_count!=old_b || ar_count!=old_ar || r_count!=old_r ||
                awvalid || wvalid || arvalid) $fatal(1,"Illegal CPU request escaped onto AXI");
            invalid_cases=invalid_cases+1;
        end
    endtask

    // Global watchdog also bounds every wait in the BFM tasks.
    initial begin
        #200000;
        $fatal(1,"AXI bridge timeout CPU=%0d/%0d AXI AW/W/B=%0d/%0d/%0d AR/R=%0d/%0d resets=%0d",
               cpu_requests,cpu_responses,aw_count,w_count,b_count,ar_count,r_count,reset_cases);
    end

    integer count_before,aw_before,w_before;
    reg [31:0] memory_before;
    initial begin
        joint_reset();
        // Independent channel orders, all byte lanes, both halfword lanes.
        write_case(0,2,32'h11223344,15,0,0);
        write_case(5,0,32'h0000aa00,2,1,0);
        write_case(10,1,32'hbeef0000,12,2,0);
        // This slave applies a paired write before returning an error.
        // AXI errors cannot promise rollback of an already applied write.
        write_case(12,2,32'hcafebabe,15,0,2);
        write_case(16,2,32'hdeadbeef,15,1,3);
        write_case(20,0,32'h0000005a,1,2,0);
        write_case(22,0,32'h00770000,4,0,0);
        write_case(23,0,32'hcc000000,8,1,0);
        write_case(24,1,32'h00009876,3,2,0);
        write_case(26,1,32'habcd0000,12,0,0);
        // Subword reads return a complete word, with no bridge-side shift.
        read_case(0,2,32'h11223344,0);
        read_case(5,0,32'ha000aa01,0);
        read_case(10,1,32'hbeef0002,0);
        read_case(23,0,32'hcc77005a,0);
        read_case(26,1,32'habcd9876,0);
        read_case(0,2,0,2);
        read_case(4,2,0,3);

        invalid_case(0,0,3,0);
        invalid_case(0,1,1,0);
        invalid_case(0,2,2,0);
        invalid_case(1,1,1,6);
        invalid_case(1,1,0,1);
        invalid_case(1,2,1,3);
        invalid_case(1,4,2,7);
        invalid_case(1,0,0,0);
        invalid_case(1,0,3,15);

        // Reset after CPU acceptance but before either AXI write channel.
        memory_before=mem[8];aw_before=aw_count;w_before=w_count;
        start_request(1,32,2,32'h11111111,15);
        repeat (4) tick();
        if (!awvalid||!wvalid||aw_count!=aw_before||w_count!=w_before) $fatal(1,"No-channel reset setup");
        joint_reset();abandoned_requests=abandoned_requests+1;reset_cases=reset_cases+1;
        if (mem[8]!==memory_before) $fatal(1,"Unaccepted AXI write modified memory");

        // AW-only reset: an orphan address must not cause a later write.
        memory_before=mem[9];aw_before=aw_count;w_before=w_count;
        start_request(1,36,2,32'h22222222,15);
        @(negedge clk);awready=1;
        while (aw_count==aw_before) tick();
        @(negedge clk);awready=0;
        repeat (3) tick();
        if (w_count!=w_before||!wvalid||mem[9]!==memory_before) $fatal(1,"AW-only reset setup");
        joint_reset();abandoned_requests=abandoned_requests+1;reset_cases=reset_cases+1;
        if (mem[9]!==memory_before) $fatal(1,"Orphan AW modified memory");

        // W-only reset: an orphan data beat must also be discarded.
        memory_before=mem[10];aw_before=aw_count;w_before=w_count;
        start_request(1,40,2,32'h33333333,15);
        @(negedge clk);wready=1;
        while (w_count==w_before) tick();
        @(negedge clk);wready=0;
        repeat (3) tick();
        if (aw_count!=aw_before||!awvalid||mem[10]!==memory_before) $fatal(1,"W-only reset setup");
        joint_reset();abandoned_requests=abandoned_requests+1;reset_cases=reset_cases+1;
        if (mem[10]!==memory_before) $fatal(1,"Orphan W modified memory");

        // Both AW and W accepted; RAM side effect persists through reset,
        // although B and the CPU completion have not happened yet.
        start_request(1,44,2,32'hcafed00d,15);
        accept_write_channels(2);
        repeat (4) tick();
        if (!bready||mem[11]!==32'hcafed00d||rsp_valid) $fatal(1,"Waiting-B reset setup");
        joint_reset();abandoned_requests=abandoned_requests+1;reset_cases=reset_cases+1;
        if (mem[11]!==32'hcafed00d) $fatal(1,"Shared reset rolled back an applied RAM write");

        // Accepted AR, no R response yet.
        start_request(0,44,2,0,0);
        accept_read_channel();
        repeat (4) tick();
        if (!rready||rsp_valid) $fatal(1,"Waiting-R reset setup");
        joint_reset();abandoned_requests=abandoned_requests+1;reset_cases=reset_cases+1;

        // A complete read is held at the CPU response. A second CPU request
        // is presented while busy and must remain unaccepted before reset.
        start_request(0,44,2,0,0);
        accept_read_channel();deliver_r(0);
        while (!rsp_valid) tick();
        count_before=cpu_requests;
        @(negedge clk);req_valid=1;req_write=1;req_addr=48;req_size=2;req_wdata=32'h44444444;req_wstrb=15;
        repeat (6) begin
            tick();
            if (req_ready||cpu_requests!=count_before||!rsp_valid||rsp_error||rsp_rdata!==32'hcafed00d)
                $fatal(1,"Held CPU response accepted a second CPU request");
        end
        joint_reset();abandoned_requests=abandoned_requests+1;reset_cases=reset_cases+1;
        if (mem[12]!==32'ha000000c) $fatal(1,"Unaccepted CPU request had side effect");

        // Probe cancelled half-writes and the persistent completed write
        // with fresh transactions after the final shared reset.
        read_case(32,2,32'ha0000008,0);
        read_case(36,2,32'ha0000009,0);
        read_case(40,2,32'ha000000a,0);
        read_case(44,2,32'hcafed00d,0);
        if (cpu_requests!=36||cpu_responses!=30||cpu_errors!=13||abandoned_requests!=6||
            aw_count!=12||w_count!=12||b_count!=10||ar_count!=13||r_count!=12||paired_writes!=11||
            invalid_cases!=9||reset_cases!=6)
            $fatal(1,"Coverage count mismatch CPU=%0d/%0d errors=%0d AXI=%0d/%0d/%0d/%0d/%0d pairs=%0d",
                   cpu_requests,cpu_responses,cpu_errors,aw_count,w_count,b_count,ar_count,r_count,paired_writes);
        if (order_aw_first<1||order_w_first<1||order_same<1||aw_stalls==0||w_stalls==0||ar_stalls==0||cpu_rsp_stalls==0)
            $fatal(1,"Missing channel order/backpressure coverage");
        $display("AXI bridge coverage: CPU accepted=36 completed=30 errors=13 reset-cancelled=6 illegal-local=9");
        $display("AXI channels: AW=12 W=12 B=10 AR=13 R=12 paired writes=11; orders AW-first=%0d W-first=%0d same=%0d",
                 order_aw_first,order_w_first,order_same);
        $display("Stall cycles AW=%0d W=%0d AR=%0d CPU-response=%0d; six reset scenarios, seven reset conditions",
                 aw_stalls,w_stalls,ar_stalls,cpu_rsp_stalls);
        $display("PASS: independent AXI4-Lite bridge protocol, byte lanes, response errors, local validation, stability and shared-reset recovery");
        test_pass=1;
        $stop;
    end
endmodule
