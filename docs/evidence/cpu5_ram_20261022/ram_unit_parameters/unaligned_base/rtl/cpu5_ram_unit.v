// CPU5 ordinary RAM decode/address/format only. This unit never authorizes a
// request: the pipeline/independent D owner enforce age and side-effect order.
// The external endpoint returns the entire aligned word, including for LB/LH.
module cpu5_ram_unit #(
    parameter [31:0] DMEM_BASE_ADDR=32'h00010000,
    parameter integer DMEM_WORDS=4096
)(
    input wire [31:0] instr,rs1_value,rs2_value,response_word,
    output wire supported,is_load,is_store,uses_rs1,uses_rs2,writes_rd,
    output wire [4:0] rs1,rs2,rd,
    output wire [31:0] imm,addr,wdata,load_value,
    output wire [1:0] size,
    output wire [3:0] wstrb,
    output wire misaligned,out_of_range,fault,
    output wire [31:0] fault_cause
);
    wire [2:0] funct3=instr[14:12];
    wire load_opcode=instr[6:0]==7'h03;
    wire store_opcode=instr[6:0]==7'h23;
    assign is_load=load_opcode && (funct3==0 || funct3==1 || funct3==2 || funct3==4 || funct3==5);
    assign is_store=store_opcode && (funct3==0 || funct3==1 || funct3==2);
    assign supported=is_load || is_store;
    assign uses_rs1=supported;assign uses_rs2=is_store;
    assign rs1=instr[19:15];assign rs2=instr[24:20];
    assign rd=is_store?5'd0:instr[11:7];
    assign writes_rd=is_load && rd!=0;
    assign imm=is_load?{{20{instr[31]}},instr[31:20]}:
        is_store?{{20{instr[31]}},instr[31:25],instr[11:7]}:32'd0;
    // RV32 effective-address addition wraps architecturally at 32 bits. The
    // independent access-width/range comparison below must never wrap with it.
    assign addr=supported?(rs1_value+imm):32'd0;
    assign size=!supported?2'd0:(funct3==0 || funct3==4)?2'd0:
        (funct3==1 || funct3==5)?2'd1:2'd2;
    wire [4:0] shift_bits={addr[1:0],3'b000};
    assign wdata=is_store?(rs2_value<<shift_bits):32'd0;
    assign wstrb=!is_store?4'd0:size==0?(4'b0001<<addr[1:0]):
        size==1?(4'b0011<<addr[1:0]):4'b1111;
    wire [31:0] shifted=response_word>>shift_bits;
    assign load_value=!is_load?32'd0:funct3==0?{{24{shifted[7]}},shifted[7:0]}:
        funct3==4?{24'd0,shifted[7:0]}:funct3==1?{{16{shifted[15]}},shifted[15:0]}:
        funct3==5?{16'd0,shifted[15:0]}:response_word;
    localparam [63:0] RAM_BEGIN={32'd0,DMEM_BASE_ADDR};
    localparam [63:0] RAM_END=RAM_BEGIN+64'd4*DMEM_WORDS;
    wire [63:0] first_byte={32'd0,addr};
    wire [63:0] last_byte=first_byte+(size==0?64'd0:size==1?64'd1:64'd3);
    assign misaligned=supported && ((size==1 && addr[0]) || (size==2 && addr[1:0]!=0));
    assign out_of_range=supported && (first_byte<RAM_BEGIN || last_byte>=RAM_END);
    assign fault=supported && (misaligned || out_of_range);
    assign fault_cause=!fault?32'd0:misaligned?(is_store?32'd6:32'd4):(is_store?32'd7:32'd5);
    // synthesis translate_off
    initial if(DMEM_WORDS<=0 || DMEM_BASE_ADDR[1:0]!=0 || RAM_END>64'h100000000)
        $fatal(1,"cpu5_ram_unit requires a nonempty aligned RAM range ending at or before 2^32");
    // synthesis translate_on
endmodule
