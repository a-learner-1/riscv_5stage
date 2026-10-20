`timescale 1ns/1ps
// Observe public AXI read handshakes only. Counts survive shared reset so
// cancelled transactions remain distinguishable from completed transactions.
module axi4_read_contract_monitor #(parameter integer CHECK_LAST=1)(
    input wire clk,rst_n,
    input wire [31:0] araddr,input wire [2:0] arprot,
    input wire [7:0] arlen,input wire [2:0] arsize,input wire [1:0] arburst,
    input wire arvalid,arready,
    input wire [31:0] rdata,input wire [1:0] rresp,input wire rlast,rvalid,rready,
    output integer accepted_bursts=0,completed_bursts=0,accepted_beats=0,reset_cancels=0
);
    reg active=0,ar_held=0,r_held=0,was_active;
    reg [47:0] held_ar;
    reg [34:0] held_r;
    integer remaining=0;
    wire ar_fire=arvalid&&arready,r_fire=rvalid&&rready;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            if(active) reset_cancels=reset_cancels+1;
            active=0;remaining=0;ar_held=0;r_held=0;
        end else begin
            if(ar_held&&(!arvalid||{araddr,arprot,arlen,arsize,arburst}!==held_ar))
                $fatal(1,"AXI AR payload/VALID changed under backpressure %m");
            if(r_held&&(!rvalid||{rdata,rresp,rlast}!==held_r))
                $fatal(1,"AXI R payload/VALID changed under backpressure %m");
            ar_held=arvalid&&!arready;held_ar={araddr,arprot,arlen,arsize,arburst};
            r_held=rvalid&&!rready;held_r={rdata,rresp,rlast};
            // R may accompany its AR acceptance; an old final R may also
            // accompany the next AR. Neither requires a particular latency.
            if(rvalid&&!active&&!ar_fire) $fatal(1,"Unsolicited AXI R %m");
            if(ar_fire&&active&&!(r_fire&&remaining==1))
                $fatal(1,"Second outstanding AR on single-outstanding path %m");
            was_active=active;
            if(ar_fire&&!was_active) begin active=1;remaining={1'b0,arlen}+1;end
            if(r_fire) begin
                if(remaining<1) $fatal(1,"Extra AXI R beat %m");
                if(CHECK_LAST&&rlast!==(remaining==1))
                    $fatal(1,"RLAST disagrees with ARLEN beat ledger %m remaining=%0d",remaining);
                accepted_beats=accepted_beats+1;
                remaining=remaining-1;
                if(remaining==0) begin active=0;completed_bursts=completed_bursts+1;end
            end
            if(ar_fire) begin
                accepted_bursts=accepted_bursts+1;
                if(was_active) begin
                    active=1;remaining={1'b0,arlen}+1;
                end
            end
        end
    end
endmodule
