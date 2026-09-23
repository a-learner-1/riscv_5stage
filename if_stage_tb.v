module if_stage_tb;

    reg clk = 1'b0;
    reg rst_n = 1'b0;

    wire [31:0] pc_f;
    wire [31:0] pc_x;
    wire [31:0] instr_x;
    wire        valid_x;

    if_stage dut (
        .clk(clk),
        .rst_n(rst_n),
        .pc_f(pc_f),
        .pc_x(pc_x),
        .instr_x(instr_x),
        .valid_x(valid_x)
    );

    always #5 clk = ~clk;  // ???? 10 ns

    task automatic check_fetch(
        input [31:0] expected_pc,
        input [31:0] expected_instr
    );
        begin
            @(posedge clk);
            #1; // ?????????
            if (valid_x !== 1'b1 ||
                pc_x !== expected_pc ||
                instr_x !== expected_instr) begin
                $display("FAIL: pc_x=%h instr_x=%h valid_x=%b",
                         pc_x, instr_x, valid_x);
                $fatal(1);
            end
            $display("PASS: pc_x=%h instr_x=%h", pc_x, instr_x);
        end
    endtask

    initial begin
        #12 rst_n = 1'b1; // ??????????????

        check_fetch(32'd0, 32'h00500093);
        check_fetch(32'd4, 32'h00300113);
        check_fetch(32'd8, 32'h00000013);

        $display("IF stage test passed");
        $finish;
    end

endmodule
