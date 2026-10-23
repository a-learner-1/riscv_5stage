// Minimal M-only CSR bank. Every update is authorized by oldest MEM only.
// Diagnostic trap descriptors belong to the pipeline, not to this writable bank.
module cpu5_csr_unit #(
    parameter [31:0] TRAP_VECTOR=32'h00000100,
    parameter integer ENABLE_RV32M=0
)(
    input wire clk,rst_n,
    input wire [11:0] access_addr,
    input wire [2:0] access_funct3,
    input wire access_write_intent,
    input wire [31:0] access_operand,
    output reg [31:0] read_value,
    output wire access_illegal,
    input wire commit_fire,mret_fire,trap_fire,
    input wire [31:0] fault_pc,fault_cause,fault_tval,
    output wire [31:0] mtvec_value,mepc_value
);
    reg [31:0] csr_mstatus,csr_mtvec,csr_mscratch,csr_mepc,csr_mcause,csr_mtval;
    reg known,read_only;
    wire [31:0] write_value=access_funct3[1:0]==2'b01 ? access_operand:
        access_funct3[1:0]==2'b10 ? (read_value|access_operand):(read_value&~access_operand);
    always @* begin
        known=1'b1;read_only=1'b0;read_value=32'd0;
        case(access_addr)
            12'h300:read_value=csr_mstatus;
            // Only the integrated opt-in owner advertises M. Historical top
            // ENABLE_M by itself does not enable instruction execution.
            12'h301:read_value=ENABLE_RV32M?32'h40001100:32'h40000100;
            12'h305:read_value=csr_mtvec;
            12'h340:read_value=csr_mscratch;
            12'h341:read_value=csr_mepc;
            12'h342:read_value=csr_mcause;
            12'h343:read_value=csr_mtval;
            12'hf11,12'hf12,12'hf13,12'hf14,12'hf15:read_only=1'b1;
            default:known=1'b0;
        endcase
    end
    assign access_illegal=!known || (read_only && access_write_intent);
    assign mtvec_value=csr_mtvec;assign mepc_value=csr_mepc;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            csr_mstatus<=32'h00001800;csr_mtvec<=TRAP_VECTOR;
            csr_mscratch<=0;csr_mepc<=0;csr_mcause<=0;csr_mtval<=0;
        end else if(trap_fire)begin
            csr_mepc<={fault_pc[31:2],2'b00};csr_mcause<=fault_cause;csr_mtval<=fault_tval;
            csr_mstatus<=32'h00001800|(csr_mstatus[3]?32'h80:32'd0);
        end else if(mret_fire)begin
            csr_mstatus<=32'h00001880|(csr_mstatus[7]?32'h8:32'd0);
        end else if(commit_fire && access_write_intent && !access_illegal)begin
            case(access_addr)
                12'h300:csr_mstatus<=32'h00001800|(write_value&32'h88);
                12'h305:csr_mtvec<={write_value[31:2],2'b00};
                12'h340:csr_mscratch<=write_value;
                12'h341:csr_mepc<={write_value[31:2],2'b00};
                12'h342:csr_mcause<=write_value;
                12'h343:csr_mtval<=write_value;
                // misa is fixed WARL; legal writes are ignored.
                default:begin end
            endcase
        end
    end
    // synthesis translate_off
    always @(posedge clk)if(rst_n)begin
        if((trap_fire && (commit_fire||mret_fire)) || (commit_fire&&mret_fire))
            $fatal(1,"CPU5 CSR architectural actions overlap");
        if(commit_fire && access_illegal)$fatal(1,"CPU5 illegal CSR committed");
    end
    // synthesis translate_on
endmodule
