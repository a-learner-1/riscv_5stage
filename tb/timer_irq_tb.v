`timescale 1ns/1ps
// Real instruction programs and independent memory endpoints. No internal CSR
// or timer register is forced. Only ROM contents are installed during reset.
module timer_irq_tb;
    wire [12:0] done;
    reg test_pass=0;
    timer_irq_case #(.KIND(0)) masks(done[0]);
    timer_irq_case #(.KIND(1)) request_wait(done[1]);
    timer_irq_case #(.KIND(2)) response_wait(done[2]);
    timer_irq_case #(.KIND(3)) data_fault_priority(done[3]);
    timer_irq_case #(.KIND(4)) fetch_wait(done[4]);
    timer_irq_case #(.KIND(5)) stale_fetch_error(done[5]);
    timer_irq_case #(.KIND(6)) level_reentry(done[6]);
    timer_irq_case #(.KIND(7)) illegal_priority(done[7]);
    timer_irq_case #(.KIND(8),.TIMER_ENABLE(0)) opt_in_disabled(done[8]);
    timer_irq_case #(.KIND(9)) timer_mmio(done[9]);
    timer_irq_case #(.KIND(10)) branch_preempt(done[10]);
    timer_irq_case #(.KIND(11)) store_preempt(done[11]);
    timer_irq_case #(.KIND(12)) gpio_preempt(done[12]);
    initial begin wait(&done);test_pass=1;
        $display("PASS: timer IRQ masks/CSR, exact interrupted PC and unique retirement, request/response waits, fetch bubbles/stale errors, synchronous priority, MRET level reentry and reset/default-off");$stop;end
    initial begin #400000;$fatal(1,"Timer IRQ timeout done=%h",done);end
endmodule

module timer_irq_case #(parameter integer KIND=0,TIMER_ENABLE=1)(output reg done=0);
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    wire [31:0] pc_x,instr_x,wb_pc,wb_data,trap_pc,trap_cause,trap_tval;
    wire [4:0] wb_rd;
    wire valid_x,wb_we,retire_valid,trap_valid,imem_fault,dmem_fault;
    wire [7:0] gpio_out;
    wire [63:0] instret_count;
    wire dr_valid,dr_write,ds_ready,ir_valid,is_ready;
    wire [31:0] dr_addr,dr_wdata,ir_addr;
    wire [1:0] dr_size;
    wire [3:0] dr_wstrb;
    reg ds_valid=0,ds_error=0,is_valid=0,is_error=0;
    reg [31:0] ds_data=0,is_data=0;
    reg d_active=0,i_active=0;
    reg [31:0] memory[0:63],rom[0:255];
    reg expected_retire[0:255],forbidden_retire[0:255],check_write[0:255];
    reg [4:0] expected_rd[0:255];
    reg [31:0] expected_data[0:255];
    integer retired_seen[0:255];
    integer cursor=0,terminal_pc=0,critical_pc=0,sync_pc=-1;
    integer irqs=0,syncs=0,mrets=0,main_retired=0;
    integer reqs=0,rsps=0,writes=0,gpio_writes=0;
    integer internal_writes=0;
    integer d_req_wait=0,d_rsp_wait=0,i_req_wait=0,i_rsp_wait=0;
    integer blocked_data=0,waiting_response=0,fetch_bubble_irqs=0;
    integer critical_fetches=0,stale_errors=0,held_fetch_responses=0;
    integer timer_writes=0,blocked_timer=0,snapshot_pc=-1;
    reg [31:0] timer_snapshot;
    reg [63:0] snapshot_time;
    reg [63:0] timer_before_edge;
    integer i,k,lane,idx,saved_irqs,saved_syncs,saved_mrets,saved_retired;
    reg finished=0,checking=1,second_boot=0;
    reg [31:0] accepted_daddr,accepted_dwdata,accepted_iaddr;
    reg accepted_dwrite;
    reg [3:0] accepted_dstrobe;
    reg held_dreq=0,held_ireq=0,held_irsp=0;
    reg [70:0] ddesc;
    reg [31:0] iaddr;
    reg [32:0] ipayload;
    // The first older store waits long enough that the real timer expires.
    wire dr_ready=rst_n && !d_active && !ds_valid &&
        (KIND!=1 || reqs!=0 || d_req_wait>=600);
    wire ir_ready=rst_n && !i_active && !is_valid &&
        (KIND!=5 || ir_addr!=critical_pc || critical_fetches!=0 || i_req_wait>=600);
    cpu_top #(.PROGRAM_FILE("programs/data_handshake_blank.hex"),
        .IMEM_WORDS(256),.DMEM_WORDS(64),.DMEM_BASE_ADDR(0),
        .ENABLE_TRAPS(1),.ENABLE_TIMER_IRQ(TIMER_ENABLE),.SIM_CONSOLE_ECHO(0),
        .EXTERNAL_DMEM(KIND>=1 && KIND<=3),.EXTERNAL_IMEM(KIND==4 || KIND==5),
        .DMEM_REQ_WAIT_CYCLES(2),.DMEM_RSP_WAIT_CYCLES(3)
    ) dut(.clk(clk),.rst_n(rst_n),.pc_x(pc_x),.instr_x(instr_x),.valid_x(valid_x),
        .wb_pc(wb_pc),.wb_rd(wb_rd),.wb_data(wb_data),.wb_we(wb_we),
        .retire_valid(retire_valid),.cycle_count(),.instret_count(instret_count),
        .uart_rx(1'b1),.uart_tx(),.gpio_in(8'd0),.gpio_out(gpio_out),.gpio_oe(),
        .dmem_req_valid(dr_valid),.dmem_req_ready(dr_ready),.dmem_req_write(dr_write),
        .dmem_req_addr(dr_addr),.dmem_req_size(dr_size),.dmem_req_wdata(dr_wdata),
        .dmem_req_wstrb(dr_wstrb),.dmem_rsp_valid(ds_valid),.dmem_rsp_ready(ds_ready),
        .dmem_rsp_rdata(ds_data),.dmem_rsp_error(ds_error),.dmem_fault(dmem_fault),
        .imem_req_valid(ir_valid),.imem_req_ready(ir_ready),.imem_req_addr(ir_addr),
        .imem_rsp_valid(is_valid),.imem_rsp_ready(is_ready),.imem_rsp_rdata(is_data),
        .imem_rsp_error(is_error),.imem_fault(imem_fault),.imem_fault_pc(),
        .trap_valid(trap_valid),.trap_pc(trap_pc),.trap_cause(trap_cause),.trap_tval(trap_tval));
    function [31:0] itype;
        input integer imm;input [4:0] rs1;input [2:0] f3;input [4:0] rd;input [6:0] op;
        begin itype={imm[11:0],rs1,f3,rd,op};end
    endfunction
    function [31:0] csr;
        input [11:0] a;input [4:0] s;input [2:0] f3;input [4:0] rd;
        begin csr={a,s,f3,rd,7'h73};end
    endfunction
    function [31:0] store;
        input integer imm;input [4:0] rs2,rs1;
        begin store={imm[11:5],rs2,rs1,3'b010,imm[4:0],7'h23};end
    endfunction
    function [31:0] branch;
        input integer imm;input [4:0] rs2,rs1;input [2:0] f3;
        begin branch={imm[12],imm[10:5],rs2,rs1,f3,imm[4:1],imm[11],7'h63};end
    endfunction
    function [31:0] jump;
        input integer imm;
        begin jump={imm[20],imm[10:1],imm[11],imm[19:12],5'd0,7'h6f};end
    endfunction
    task emit;
        input [31:0] ins;input integer rd;input [31:0] data;
        begin rom[cursor]=ins;expected_retire[cursor]=1;
            check_write[cursor]=rd>=0;expected_rd[cursor]=rd[4:0];expected_data[cursor]=data;cursor=cursor+1;end
    endtask
    task addi;
        input integer rd,rs,imm;input [31:0] data;
        begin emit(itype(imm,rs[4:0],0,rd[4:0],7'h13),rd,data);end
    endtask
    task csrop;
        input [11:0] a;input integer source;input [2:0] f;input integer rd;input [31:0] value;
        begin emit(csr(a,source[4:0],f,rd[4:0]),rd,value);end
    endtask
    task skip;
        input [31:0] ins;
        begin rom[cursor]=ins;forbidden_retire[cursor]=1;cursor=cursor+1;end
    endtask
    task clear_program;
        begin cursor=0;finished=0;
            for(i=0;i<256;i=i+1)begin rom[i]=32'h13;expected_retire[i]=0;forbidden_retire[i]=0;
                check_write[i]=0;expected_rd[i]=0;expected_data[i]=0;retired_seen[i]=0;end
        end
    endtask
    task handler;
        begin
            rom[192]=csr(12'h342,0,2,20);rom[193]=csr(12'h341,0,2,21);
            rom[194]=csr(12'h343,0,2,22);rom[195]=csr(12'h300,0,2,23);
            if(TIMER_ENABLE)begin rom[196]=csr(12'h304,0,2,24);rom[197]=csr(12'h344,0,2,25);end
            rom[198]=branch(12,0,20,5); // BGE: synchronous causes are nonnegative.
            rom[199]=itype(1,31,0,31,7'h13);rom[200]=jump(20);
            rom[201]=itype(1,30,0,30,7'h13);rom[202]=itype(4,21,0,21,7'h13);
            rom[203]=csr(12'h341,21,1,0);rom[204]=jump(24);
            if(KIND==6)begin rom[205]=itype(1,0,0,26,7'h13);rom[206]=branch(16,26,31,0);
                rom[207]=store(72,2,1);rom[208]=store(76,2,1);end
            else begin rom[205]=store(72,2,1);rom[206]=store(76,2,1);end
            rom[210]=32'h30200073;
        end
    endtask
    task install;
        begin for(i=0;i<256;i=i+1)dut.u_if_stage.u_instr_mem.mem[i]=rom[i];end
    endtask
    task terminal;
        begin terminal_pc=cursor*4;addi(19,0,1,1);rom[cursor]=jump(0);end
    endtask
    task build;
        begin
            emit(32'h200000b7,1,32'h20000000);addi(2,0,-1,32'hffffffff);
            addi(3,0,128,128);addi(4,0,768,768);csrop(12'h305,4,1,0,0);
            addi(30,0,0,0);addi(31,0,0,0);
            if(KIND==8)begin
                sync_pc=cursor*4;skip(csr(12'h304,0,2,8));
                skip(csr(12'h344,0,2,9));skip(itype(64,1,2,10,7'h03));
            end else begin
                csrop(12'h304,0,2,7,0);
                emit(store(72,2,1),0,0); // low=max while high is still max
                emit(store(76,0,1),0,0);
                if(KIND==0 || KIND==6 || KIND==7 || KIND>=10) emit(store(72,0,1),0,0);
                else begin addi(4,0,400,400);emit(store(72,4,1),0,0);end
                if(KIND==9)begin
                    sync_pc=cursor*4;
                    skip(itype(64,1,0,8,7'h03)); // LB: aligned but illegal timer size, load access fault.
                    skip(itype(65,1,2,9,7'h03)); // LW misaligned, no timer request.
                    skip({7'd2,5'd2,5'd1,3'b000,5'd8,7'h23}); // SB at timer compare low.
                    skip(store(73,2,1)); // SW misaligned, no timer write.
                    snapshot_pc=cursor*4;emit(itype(64,1,2,7,7'h03),-1,0);
                end else if(KIND==0)begin
                    csrop(12'h344,0,2,8,128);csrop(12'h344,0,1,0,0);
                    csrop(12'h344,0,2,9,128);
                    csrop(12'h300,8,6,0,0);csrop(12'h300,0,2,8,32'h1808);
                    addi(11,0,54,54); // Global MIE alone cannot accept masked MTIP.
                    csrop(12'h300,8,7,0,0);csrop(12'h304,2,1,0,0); // WARL: only MTIE survives all-ones write.
                    csrop(12'h300,0,2,10,32'h1800);addi(11,0,55,55);
                    csrop(12'h300,8,6,0,0);critical_pc=cursor*4;
                    addi(12,11,1,56);csrop(12'h344,0,2,13,0);
                    csrop(12'h304,0,2,14,128);csrop(12'h300,0,2,15,32'h1888);
                end else begin
                    if(KIND>=10)begin addi(5,0,0,0);addi(6,0,KIND==12?1:77,KIND==12?1:77);end
                    csrop(12'h304,3,1,0,0);csrop(12'h300,8,6,0,0);
                    if(KIND==6)begin critical_pc=cursor*4;addi(12,0,66,66);end
                    else if(KIND==7)begin sync_pc=cursor*4;skip(32'hffffffff);critical_pc=cursor*4;addi(12,0,77,77);end
                    else if(KIND==4 || KIND==5)begin critical_pc=cursor*4;addi(12,0,44,44);end
                    else if(KIND==10)begin
                        critical_pc=cursor*4;emit(branch(12,6,6,0),0,0);
                        skip(store(4,6,5));skip(store(52,6,1));addi(12,0,88,88);
                    end else if(KIND==11)begin
                        critical_pc=cursor*4;emit(store(0,6,5),0,0);
                        emit(itype(0,5,2,7,7'h03),7,77);addi(12,7,1,78);
                    end else if(KIND==12)begin
                        critical_pc=cursor*4;emit(store(52,6,1),0,0);addi(12,0,88,88);
                    end
                    else begin
                        addi(5,0,0,0);addi(6,0,77,77);
                        if(KIND==3)begin sync_pc=cursor*4;skip(store(0,6,5));critical_pc=cursor*4;addi(12,0,33,33);end
                        else begin emit(store(0,6,5),0,0);critical_pc=cursor*4;
                            emit(itype(0,5,2,7,7'h03),7,77);addi(12,7,1,78);end
                        emit(branch(12,6,6,0),0,0);skip(store(4,6,5));skip(store(52,6,1));
                    end
                end
                if(KIND!=9)begin
                    // A GPIO transaction immediately after a taken branch is unique.
                    if(KIND!=12)begin addi(16,0,1,1);emit(store(52,16,1),0,0);end
                    csrop(12'h304,3,3,0,0);csrop(12'h304,0,2,17,0);
                    csrop(12'h300,0,2,18,32'h1888);
                end
            end
            terminal();handler();
        end
    endtask
    // Independent single-outstanding endpoint. Payloads hold until consumed.
    always @(posedge clk)begin
        if(!rst_n)begin ds_valid<=0;ds_error<=0;d_active<=0;d_req_wait<=0;d_rsp_wait<=0;
            is_valid<=0;is_error<=0;i_active<=0;i_req_wait<=0;i_rsp_wait<=0;end
        else begin
            if(dr_valid&&!dr_ready)begin d_req_wait<=d_req_wait+1;blocked_data=blocked_data+1;end
            if(ds_valid&&ds_ready)begin ds_valid<=0;rsps=rsps+1;end
            if(dr_valid&&dr_ready)begin
                if(d_active||ds_valid) $fatal(1,"IRQ data endpoint overlap");
                d_active<=1;accepted_daddr<=dr_addr;accepted_dwdata<=dr_wdata;
                accepted_dstrobe<=dr_wstrb;accepted_dwrite<=dr_write;
                d_rsp_wait<=((KIND==2||KIND==3)&&reqs==0)?600:2;reqs=reqs+1;d_req_wait<=0;
            end
            if(d_active)begin waiting_response=waiting_response+1;
                if(d_rsp_wait>0)d_rsp_wait<=d_rsp_wait-1;
                else begin d_active<=0;ds_valid<=1;ds_error<=KIND==3;
                    ds_data<=memory[accepted_daddr[7:2]];
                    if(accepted_dwrite&&KIND!=3)begin
                        for(lane=0;lane<4;lane=lane+1)if(accepted_dstrobe[lane])memory[accepted_daddr[7:2]][lane*8+:8]<=accepted_dwdata[lane*8+:8];
                        writes=writes+1;end
                end
            end
            if(ir_valid&&!ir_ready)i_req_wait<=i_req_wait+1;
            if(is_valid&&!is_ready)held_fetch_responses=held_fetch_responses+1;
            if(is_valid&&is_ready)begin if(is_error)stale_errors=stale_errors+1;is_valid<=0;end
            if(ir_valid&&ir_ready)begin
                if(i_active||is_valid)$fatal(1,"IRQ fetch endpoint overlap");
                i_active<=1;accepted_iaddr<=ir_addr;i_req_wait<=0;
                i_rsp_wait<=((KIND==4)&&ir_addr==critical_pc&&critical_fetches==0)?600:2;
                if(ir_addr==critical_pc)critical_fetches=critical_fetches+1;
            end
            if(i_active)begin
                if(i_rsp_wait>0)i_rsp_wait<=i_rsp_wait-1;
                else begin i_active<=0;is_valid<=1;is_data<=rom[accepted_iaddr[9:2]];
                    is_error<=(KIND==5&&accepted_iaddr==critical_pc&&critical_fetches==1);end
            end
        end
    end
    // Transaction hold contracts are checked independently of trap completion.
    always @(posedge clk)begin
        if(!rst_n)begin held_dreq<=0;held_ireq<=0;held_irsp<=0;end
        else begin
            if(held_dreq&&(!dr_valid||{dr_write,dr_addr,dr_size,dr_wdata,dr_wstrb}!==ddesc))$fatal(1,"IRQ changed blocked data request");
            if(held_ireq&&(!ir_valid||ir_addr!==iaddr))$fatal(1,"IRQ changed blocked fetch request");
            if(held_irsp&&(!is_valid||{is_error,is_data}!==ipayload))$fatal(1,"IRQ changed held fetch response");
            held_dreq<=dr_valid&&!dr_ready;ddesc<={dr_write,dr_addr,dr_size,dr_wdata,dr_wstrb};
            held_ireq<=ir_valid&&!ir_ready;iaddr<=ir_addr;
            held_irsp<=is_valid&&!is_ready;ipayload<={is_error,is_data};
        end
    end
    always @(posedge clk)if(rst_n&&checking&&!finished)begin
        timer_before_edge=dut.timer_mtime;
        if(dut.irq_event && !valid_x)fetch_bubble_irqs=fetch_bubble_irqs+1;
        if(dut.mem_req_fire&&dut.mem_req_write&&dut.mem_addr_x==32'h20000034)gpio_writes=gpio_writes+1;
        if(dut.mem_we_x)internal_writes=internal_writes+1;
        if(dut.mem_req_valid&&!dut.mem_req_ready&&dut.timer_write_hit_x)blocked_timer=blocked_timer+1;
        if(dut.mmio_timer_write_x)timer_writes=timer_writes+1;
        if(KIND==9 && dut.mem_req_fire&&!dut.mem_req_write&&dut.mem_addr_x==32'h20000040)begin
            timer_snapshot=dut.timer_mtime[31:0];snapshot_time=dut.timer_mtime;end
        #1;
        if(TIMER_ENABLE && dut.timer_mtime!==timer_before_edge+1)$fatal(1,"Timer stopped or double-ticked during CPU/endpoint wait");
        if(trap_valid)begin
            if(dmem_fault)$fatal(1,"IRQ trap mode entered sticky data halt");
            if(trap_cause==32'h80000007)begin
                if(trap_pc!==critical_pc||trap_tval!==0||dut.csr_mepc!==critical_pc||
                   dut.csr_mcause!==32'h80000007||dut.csr_mtval!==0||dut.csr_mstatus!==32'h1880)
                    $fatal(1,"IRQ descriptor kind=%0d gotPC=%h want=%h cause=%h status=%h",KIND,trap_pc,critical_pc,trap_cause,dut.csr_mstatus);
                if(reqs!=rsps||d_active||ds_valid||dut.mem_active)$fatal(1,"IRQ interrupted outstanding data transaction");
                if(retired_seen[critical_pc/4]!=0)$fatal(1,"IRQ saved already-executed instruction");
                if((KIND==3||KIND==7)&&syncs!=1)$fatal(1,"IRQ won over synchronous exception");
                irqs=irqs+1;if(irqs>(KIND==6?2:1))$fatal(1,"IRQ repeated unexpectedly");
            end else begin
                if(KIND==3)begin if(trap_cause!==7||trap_pc!==sync_pc||trap_tval!==0)$fatal(1,"Data error did not win IRQ priority");end
                else if(KIND==7)begin if(trap_cause!==2||trap_pc!==sync_pc||trap_tval!==32'hffffffff)$fatal(1,"Illegal instruction did not win IRQ priority");end
                else if(KIND==8)begin
                    if(syncs<2 ? trap_cause!==2 : trap_cause!==5)$fatal(1,"Disabled timer unexpectedly exposes CSR/MMIO");
                    if(trap_pc!==sync_pc+syncs*4)$fatal(1,"Disabled timer exception PC");
                    if(syncs<2 ? trap_tval!==rom[sync_pc/4+syncs] : trap_tval!==32'h20000040)$fatal(1,"Disabled timer exception tval");
                end else if(KIND==9)begin
                    if(trap_pc!==sync_pc+syncs*4)$fatal(1,"Timer bad-size/alignment PC");
                    case(syncs)
                        0:if(trap_cause!==5||trap_tval!==32'h20000040)$fatal(1,"Timer LB access exception");
                        1:if(trap_cause!==4||trap_tval!==32'h20000041)$fatal(1,"Timer unaligned LW exception");
                        2:if(trap_cause!==7||trap_tval!==32'h20000048)$fatal(1,"Timer SB access exception");
                        3:if(trap_cause!==6||trap_tval!==32'h20000049)$fatal(1,"Timer unaligned SW exception");
                        default:$fatal(1,"Extra timer MMIO exception");
                    endcase
                end else $fatal(1,"Unexpected synchronous exception kind=%0d cause=%h",KIND,trap_cause);
                syncs=syncs+1;
            end
        end
        if(retire_valid)begin
            idx=wb_pc/4;
            if(idx<0||idx>=256||wb_pc[1:0]!=0)$fatal(1,"IRQ retirement PC outside ROM");
            if(forbidden_retire[idx])$fatal(1,"Fault/wrong-path instruction retired kind=%0d PC=%h",KIND,wb_pc);
            if(idx<192)begin
                if(!expected_retire[idx]||retired_seen[idx]!=0)$fatal(1,"Unexpected/duplicate main retirement kind=%0d PC=%h",KIND,wb_pc);
                if(check_write[idx]&&((expected_rd[idx]!=0) ? (!wb_we||wb_rd!==expected_rd[idx]||wb_data!==expected_data[idx]) : wb_we))
                    $fatal(1,"IRQ writeback kind=%0d PC=%h rd=%0d data=%h want=%h",KIND,wb_pc,wb_rd,wb_data,expected_data[idx]);
                retired_seen[idx]=retired_seen[idx]+1;main_retired=main_retired+1;
                if(KIND==9 && wb_pc==snapshot_pc && (wb_data!==timer_snapshot || dut.timer_mtime<=snapshot_time+3))
                    $fatal(1,"Timer read did not snapshot pre-accept value or time stopped in wait");
                if(wb_pc==terminal_pc)finished=1;
            end else if(rom[idx]==32'h30200073)mrets=mrets+1;
        end
    end
    initial begin
        for(k=0;k<64;k=k+1)begin memory[k]=0;dut.u_data_mem.mem[k]=0;end
        #1;clear_program();build();install();repeat(4)@(negedge clk);rst_n=1;
        wait(finished);@(negedge clk);checking=0;
        for(k=0;k<192;k=k+1)if(expected_retire[k]&&retired_seen[k]!=1)$fatal(1,"IRQ lost instruction kind=%0d PC=%h",KIND,k*4);
        if(irqs!=((KIND==8||KIND==9)?0:KIND==6?2:1)||syncs!=(KIND==8?3:KIND==9?4:(KIND==3||KIND==7)?1:0)||mrets!=irqs+syncs)
            $fatal(1,"IRQ totals kind=%0d irq=%0d sync=%0d mret=%0d",KIND,irqs,syncs,mrets);
        if((KIND<8||KIND>=10) && (gpio_out!==1||gpio_writes!=1))$fatal(1,"Interrupted/wrong-path GPIO replay kind=%0d out=%h writes=%0d",KIND,gpio_out,gpio_writes);
        if(KIND==11 && (internal_writes!=1 || dut.u_data_mem.mem[0]!==77))$fatal(1,"Preempted STORE issued twice or lost");
        if(KIND==10 && (internal_writes!=0 || dut.u_data_mem.mem[1]!==0))$fatal(1,"Preempted branch failed wrong-path suppression");
        if(TIMER_ENABLE && (timer_writes!=(KIND==9?3:5)||blocked_timer==0))$fatal(1,"Timer MMIO repeated write or missing request wait kind=%0d writes=%0d",KIND,timer_writes);
        if(KIND==1||KIND==2)begin
            if(memory[0]!==77||memory[1]!==0||reqs!=2||rsps!=2||writes!=1)$fatal(1,"IRQ lost/duplicated RAM store/load");
            if(KIND==1&&blocked_data<600)$fatal(1,"IRQ request-backpressure scenario not reached");
            if(KIND==2&&waiting_response<600)$fatal(1,"IRQ response-wait scenario not reached");
        end
        if(KIND==3&&(memory[0]!==0||reqs!=1||rsps!=1))$fatal(1,"Failed store produced side effect");
        if((KIND==4||KIND==5)&&fetch_bubble_irqs!=1)$fatal(1,"IRQ frontend bubble not covered");
        if(KIND==5&&stale_errors!=1)$fatal(1,"IRQ stale error response not exercised");
        saved_irqs=irqs;saved_syncs=syncs;saved_mrets=mrets;saved_retired=main_retired;
        rst_n=0;repeat(3)@(negedge clk);
        if(trap_valid||dr_valid||ir_valid||ds_valid||is_valid||dut.csr_mstatus!==32'h1800||dut.csr_mtvec!==0||dut.csr_mepc!==0)
            $fatal(1,"IRQ shared reset did not clear architecture/protocol");
        if(TIMER_ENABLE && (dut.csr_mie!==0||dut.timer_mtip))$fatal(1,"IRQ reset did not mask and clear level");
        clear_program();irqs=0;syncs=0;mrets=0;main_retired=0;
        if(TIMER_ENABLE)begin csrop(12'h304,0,2,7,0);csrop(12'h344,0,2,8,0);end
        csrop(12'h300,0,2,9,32'h1800);terminal();install();checking=1;second_boot=1;rst_n=1;
        wait(finished);@(negedge clk);checking=0;
        if(irqs||syncs||mrets)$fatal(1,"Reset boot inherited old IRQ");
        if((KIND==1||KIND==2)&&memory[0]!==77)$fatal(1,"IRQ shared reset erased RAM");
        $display("IRQ case %0d PASS: IRQ=%0d synchronous=%0d MRET=%0d unique main=%0d, exact PC/writeback, wait=%0d/%0d stale=%0d bubbleIRQ=%0d, CSR/default-off and reset",KIND,saved_irqs,saved_syncs,saved_mrets,saved_retired,blocked_data,waiting_response,stale_errors,fetch_bubble_irqs);
        done=1;
    end
endmodule
