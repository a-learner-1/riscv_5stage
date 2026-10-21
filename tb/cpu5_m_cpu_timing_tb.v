`timescale 1ns/1ps
`define MC cpu.dut
// Reuse the existing independent ISA retirement/store oracle, adding passive
// edge observation. Includes all ops, x0, dependencies, DIV0 and overflow.
module cpu5_m_cpu_timing_tb;
    wire done;
    rv32m_cpu_case #(.PRED(1),.INJECT_IRQ(0)) cpu(done);
    reg test_pass=0,owner=0,done_seen=0,completed=0;
    reg [63:0] edge_id=0,oid=0,s=0,d=0,c=0,waits=0;
    reg [2:0] op;
    reg [4:0] rd;
    reg [31:0] pc,a,b,result;
    integer f,covered[0:7],i,fast=0;
    string output_dir;
    initial begin
        if(!$value$plusargs("M_OUTPUT=%s",output_dir))$fatal(1,"M_OUTPUT required");
        f=$fopen({output_dir,"/m_owners.csv"},"w");
        if(!f)$fatal(1,"cannot open CPU timing trace");
        $fwrite(f,"owner,pc,op,rd,lhs,rhs,result,start_edge,unit_done_edge,cpu_complete_edge,retire_edge,wait_cycles\n");
        for(i=0;i<8;i=i+1)covered[i]=0;
    end
    always @(posedge cpu.clk)if(cpu.rst_n && !test_pass)begin
        edge_id=edge_id+1;
        if(owner && completed && `MC.retire_valid)begin
            if(edge_id!=c+1 || `MC.wb_pc!==pc || `MC.wb_rd!==rd || `MC.wb_data!==result || `MC.wb_we!==(rd!=0))
                $fatal(1,"directed CPU M retirement owner mismatch");
            $fwrite(f,"%0d,%08h,%0d,%0d,%08h,%08h,%08h,%0d,%0d,%0d,%0d,%0d\n",oid,pc,op,rd,a,b,result,s,d,c,edge_id,waits);
            covered[op]=covered[op]+1;
            if(d==s)fast=fast+1;
            owner=0;completed=0;done_seen=0;
        end
        if(`MC.m_start_x)begin
            if(owner || `MC.m_busy || `MC.g_m.u_muldiv.state!=0)$fatal(1,"directed CPU duplicate owner");
            owner=1;oid=oid+1;s=edge_id;d=0;c=0;waits=0;done_seen=0;completed=0;
            op=`MC.instr_x[14:12];rd=`MC.rd_addr_x;pc=`MC.pc_x;a=`MC.rs1_value_x;b=`MC.rs2_value_x;
        end
        if(`MC.m_complete_x)begin
            if(!owner || !done_seen || completed || d>=edge_id)$fatal(1,"directed CPU stale done");
            c=edge_id;completed=1;result=`MC.m_result;
        end
        if(`MC.m_wait_x)begin
            if(!owner || completed)$fatal(1,"directed CPU wait has no owner");
            waits=waits+1;
        end
        #1;
        if(owner && !done_seen && `MC.m_done)begin
            if(`MC.m_busy)$fatal(1,"directed CPU unit busy and done");
            done_seen=1;d=edge_id;
        end
    end
    initial begin
        wait(done);@(negedge cpu.clk);
        if(owner || fast<6)$fatal(1,"directed CPU owner coverage incomplete");
        for(i=0;i<8;i=i+1)if(covered[i]<1)$fatal(1,"directed CPU operation missing");
        $fclose(f);test_pass=1;
        $display("CPU5 M CPU TIMING PASS owners=%0d fast=%0d; original ISA/retirement/store oracle passed",oid,fast);
        $stop;
    end
endmodule
