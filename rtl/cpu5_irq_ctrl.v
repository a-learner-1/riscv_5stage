// Synchronized level IRQ candidates. Arbitration always uses pre-edge CSR and
// pending state; post-retirement CSR values only arm the following edge.
module cpu5_irq_ctrl #(
    parameter integer ENABLE_EXTERNAL_IRQ=0,ENABLE_SOFTWARE_IRQ=0,ENABLE_TIMER_IRQ=0
)(
    input wire clk,rst_n,
    input wire irq_external,irq_software,irq_timer,
    input wire global_enable,input wire [31:0] mie_value,
    input wire retire_fire,post_commit_global_enable,
    input wire [31:0] post_commit_mie,
    input wire trap_enter_fire,safe_boundary,mem_enable,flush_active,sync_fault,
    output wire [31:0] pending_sync,
    output reg irq_arm_q,
    output wire irq_eligible_now,irq_take,
    output wire [31:0] irq_cause
);
    localparam [31:0] SOURCE_MASK=(ENABLE_EXTERNAL_IRQ?32'h800:32'd0)|
        (ENABLE_SOFTWARE_IRQ?32'h8:32'd0)|(ENABLE_TIMER_IRQ?32'h80:32'd0);
    reg external_meta_q,external_sync_q,software_meta_q,software_sync_q,timer_meta_q,timer_sync_q;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            external_meta_q<=0;external_sync_q<=0;software_meta_q<=0;software_sync_q<=0;
            timer_meta_q<=0;timer_sync_q<=0;
        end else begin
            external_meta_q<=ENABLE_EXTERNAL_IRQ?irq_external:1'b0;
            external_sync_q<=external_meta_q;
            software_meta_q<=ENABLE_SOFTWARE_IRQ?irq_software:1'b0;
            software_sync_q<=software_meta_q;
            timer_meta_q<=ENABLE_TIMER_IRQ?irq_timer:1'b0;
            timer_sync_q<=timer_meta_q;
        end
    end
    assign pending_sync=(external_sync_q?32'h800:32'd0)|
        (software_sync_q?32'h8:32'd0)|(timer_sync_q?32'h80:32'd0);
    wire [31:0] enabled_pending=pending_sync & mie_value & SOURCE_MASK;
    assign irq_eligible_now=global_enable && |enabled_pending;
    assign irq_take=rst_n && irq_arm_q && irq_eligible_now && safe_boundary &&
        mem_enable && !flush_active && !sync_fault;
    assign irq_cause=enabled_pending[11]?32'h8000000b:
        enabled_pending[3]?32'h80000003:enabled_pending[7]?32'h80000007:32'd0;
    wire next_global=retire_fire?post_commit_global_enable:global_enable;
    wire [31:0] next_mie=retire_fire?post_commit_mie:mie_value;
    wire next_eligible=next_global && |(pending_sync & next_mie & SOURCE_MASK);
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)irq_arm_q<=0;
        else if(trap_enter_fire)irq_arm_q<=0;
        else irq_arm_q<=next_eligible;
    end
    // synthesis translate_off
    initial if((ENABLE_EXTERNAL_IRQ!=0 && ENABLE_EXTERNAL_IRQ!=1) ||
        (ENABLE_SOFTWARE_IRQ!=0 && ENABLE_SOFTWARE_IRQ!=1) ||
        (ENABLE_TIMER_IRQ!=0 && ENABLE_TIMER_IRQ!=1))
        $fatal(1,"CPU5 IRQ source parameters must be boolean");
    always @(posedge clk)if(rst_n)begin
        if(irq_take && retire_fire)$fatal(1,"CPU5 IRQ and retirement overlap");
        if(irq_take && (!irq_arm_q || !irq_eligible_now || !safe_boundary ||
            !mem_enable || flush_active || sync_fault))
            $fatal(1,"CPU5 IRQ lacks pre-edge safe armed eligibility");
    end
    // synthesis translate_on
endmodule
