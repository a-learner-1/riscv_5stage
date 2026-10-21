// RV32M arithmetic unit. One command in flight; operands are sampled at start.
// done/result remain stable until the next accepted start or reset.
// Multiplication uses FPGA arithmetic blocks; division is radix-2 iterative.
module rv32m_unit (
    input wire clk, input wire rst_n,
    input wire start, input wire [2:0] op,
    input wire [31:0] lhs, input wire [31:0] rhs,
    output reg busy, output reg done, output reg [31:0] result
);
    localparam [1:0] IDLE=0, MUL_PRODUCT=1, MUL_RESULT=2, DIV_STEP=3;
    reg [1:0] state;
    reg [2:0] op_q;
    reg [31:0] lhs_q, rhs_q;
    // The signed high products share one unsigned 32x32 product. Corrections
    // implement signedness without duplicating any of the four multipliers.
    (* syn_multstyle = "block_mult" *) reg [63:0] product_q;
    wire lhs_signed_q = (op_q==3'b001 || op_q==3'b010) && lhs_q[31];
    wire rhs_signed_q = (op_q==3'b001) && rhs_q[31];
    wire [31:0] high_product = product_q[63:32] -
        (lhs_signed_q ? rhs_q : 32'd0) -
        (rhs_signed_q ? lhs_q : 32'd0);

    reg [31:0] quotient_q, remainder_q, divisor_q;
    reg [5:0] step_q;
    reg quotient_negative_q, remainder_negative_q, select_remainder_q;
    wire signed_div = !op[0];
    wire [31:0] lhs_magnitude = signed_div && lhs[31] ? (~lhs+32'd1) : lhs;
    wire [31:0] rhs_magnitude = signed_div && rhs[31] ? (~rhs+32'd1) : rhs;
    // remainder<divisor on entry to every step. Thus a successful trial
    // difference is below 2^32, and bit32 unambiguously denotes a borrow.
    wire [32:0] trial_difference = {remainder_q,quotient_q[31]} - {1'b0,divisor_q};
    wire trial_accept = !trial_difference[32];
    wire [31:0] next_remainder = trial_accept ? trial_difference[31:0] :
        {remainder_q[30:0],quotient_q[31]};
    wire [31:0] next_quotient = {quotient_q[30:0],trial_accept};
    wire [31:0] signed_quotient = quotient_negative_q ? (~next_quotient+32'd1) : next_quotient;
    wire [31:0] signed_remainder = remainder_negative_q ? (~next_remainder+32'd1) : next_remainder;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=IDLE;busy<=0;done<=0;result<=0;op_q<=0;
            lhs_q<=0;rhs_q<=0;product_q<=0;
            quotient_q<=0;remainder_q<=0;divisor_q<=0;step_q<=0;
            quotient_negative_q<=0;remainder_negative_q<=0;select_remainder_q<=0;
        end else begin
            case(state)
                IDLE: if(start) begin
                    done<=0;busy<=1;op_q<=op;lhs_q<=lhs;rhs_q<=rhs;
                    if(!op[2]) state<=MUL_PRODUCT;
                    else if(rhs==0) begin
                        // RISC-V division by zero is a defined result, no trap.
                        result<=op[1] ? lhs : 32'hffffffff;
                        busy<=0;done<=1;
                    end else if(signed_div && lhs==32'h80000000 && rhs==32'hffffffff) begin
                        result<=op[1] ? 32'd0 : 32'h80000000;
                        busy<=0;done<=1;
                    end else begin
                        quotient_q<=lhs_magnitude;remainder_q<=0;divisor_q<=rhs_magnitude;
                        quotient_negative_q<=signed_div && (lhs[31]^rhs[31]);
                        remainder_negative_q<=signed_div && lhs[31];
                        select_remainder_q<=op[1];step_q<=0;state<=DIV_STEP;
                    end
                end
                MUL_PRODUCT: begin
                    product_q<=lhs_q*rhs_q;
                    state<=MUL_RESULT;
                end
                MUL_RESULT: begin
                    result<=op_q==0 ? product_q[31:0] : high_product;
                    busy<=0;done<=1;state<=IDLE;
                end
                DIV_STEP: begin
                    quotient_q<=next_quotient;remainder_q<=next_remainder;
                    if(step_q==31) begin
                        result<=select_remainder_q ? signed_remainder : signed_quotient;
                        busy<=0;done<=1;state<=IDLE;
                    end else step_q<=step_q+1'b1;
                end
                default: begin state<=IDLE;busy<=0;done<=0;end
            endcase
        end
    end
endmodule
