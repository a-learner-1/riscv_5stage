`timescale 1ns/1ps

// Expected values come from the independent Python integer oracle, never from
// DUT state or a copy of its datapath algorithm.
module rv32m_unit_tb;
    reg clk = 0, rst_n = 0, start = 0;
    reg [2:0] op = 0;
    reg [31:0] lhs = 0, rhs = 0;
    wire busy, done;
    wire [31:0] result;
    reg test_pass = 0;
    integer vector_file, scanned, vectors = 0, cycles, operation, resets = 0;
    integer covered [0:7];
    integer min_latency [0:7], max_latency [0:7];
    reg [2:0] expected_op;
    reg [31:0] a, b, expected_result, held_result;
    always #5 clk = ~clk;
    rv32m_unit dut (.clk(clk), .rst_n(rst_n), .start(start), .op(op),
        .lhs(lhs), .rhs(rhs), .busy(busy), .done(done), .result(result));

    task execute(input [2:0] which, input [31:0] va, vb, expected);
        begin
            @(negedge clk);
            if (busy) $fatal(1, "RV32M unit did not return to idle");
            op = which; lhs = va; rhs = vb; start = 1;
            @(posedge clk); #1;
            if ((done && busy) || (!done && !busy))
                $fatal(1, "RV32M unit did not accept start op=%0d", which);
            @(negedge clk);
            start = 0;
            // Change every input after acceptance: operands/op must be captured.
            op = ~which; lhs = ~va; rhs = ~vb;
            cycles = 0;
            while (!done && cycles < 80) begin
                @(posedge clk); #1;
                cycles = cycles + 1;
                if (!done && !busy) $fatal(1, "RV32M unit lost active operation op=%0d", which);
            end
            if (!done || busy || result !== expected)
                $fatal(1, "RV32M unit arithmetic op=%0d a=%h b=%h got=%h expected=%h busy/done=%b%b cycles=%0d",
                    which, va, vb, result, expected, busy, done, cycles);
            if (cycles < min_latency[which]) min_latency[which] = cycles;
            if (cycles > max_latency[which]) max_latency[which] = cycles;
            covered[which] = covered[which] + 1;
            held_result = result;
            // Some transactions deliberately leave the CPU-side completion
            // unconsumed, ensuring sticky done/result remain stable.
            if ((vectors % 31) == 0) repeat (3) begin
                @(posedge clk); #1;
                if (!done || busy || result !== held_result)
                    $fatal(1, "RV32M unit completion changed while held");
            end
        end
    endtask

    initial begin
        for (operation = 0; operation < 8; operation = operation + 1) begin
            covered[operation] = 0; min_latency[operation] = 999; max_latency[operation] = 0;
        end
        repeat (3) @(negedge clk);
        if (busy !== 0 || done !== 0) $fatal(1, "RV32M unit reset not idle");
        rst_n = 1;
        // Cancel each operation during execution and prove no late completion.
        for (operation = 0; operation < 8; operation = operation + 1) begin
            @(negedge clk); start = 1; op = operation[2:0]; lhs = 32'h8badf00d; rhs = 32'h12345;
            @(posedge clk); #1;
            if (!busy || done) $fatal(1, "RV32M unit reset test did not start");
            @(negedge clk); start = 0; rst_n = 0;
            @(posedge clk); #1;
            if (busy !== 0 || done !== 0) $fatal(1, "RV32M unit active reset failed op=%0d", operation);
            @(negedge clk); rst_n = 1;
            repeat (45) begin
                @(posedge clk); #1;
                if (busy || done) $fatal(1, "RV32M unit stale completion after reset op=%0d", operation);
            end
            resets = resets + 1;
        end
        // A stray command pulse while busy cannot replace the captured divide
        // or queue a second result. The public CPU only starts while idle.
        @(negedge clk);start=1;op=5;lhs=100;rhs=7;
        @(posedge clk);#1;
        if(!busy || done)$fatal(1,"Busy-reject divide did not start");
        @(negedge clk);start=0;
        repeat(3)@(negedge clk);
        start=1;op=0;lhs=12;rhs=13;
        @(posedge clk);#1;
        if(!busy || done)$fatal(1,"Busy command interrupted active divide");
        @(negedge clk);start=0;
        cycles=0;
        while(!done && cycles<80)begin @(posedge clk);#1;cycles=cycles+1;end
        if(!done || busy || result!==14)$fatal(1,"Busy command corrupted original divide");
        repeat(4)begin
            @(posedge clk);#1;
            if(!done || busy || result!==14)$fatal(1,"Busy command produced queued/stale result");
        end
        vector_file = $fopen("build/rv32m/rv32m_vectors.txt", "r");
        if (!vector_file) $fatal(1, "Generate RV32M Python oracle vectors first");
        while (!$feof(vector_file)) begin
            scanned = $fscanf(vector_file, "%h %h %h %h\n", expected_op, a, b, expected_result);
            if (scanned == 4) begin
                execute(expected_op, a, b, expected_result);
                vectors = vectors + 1;
            end else if (!$feof(vector_file)) $fatal(1, "Malformed RV32M vector row %0d", vectors);
        end
        $fclose(vector_file);
        if (vectors < 8192 || resets != 8) $fatal(1, "RV32M insufficient oracle coverage %0d", vectors);
        for (operation = 0; operation < 8; operation = operation + 1) begin
            if (covered[operation] < 1024) $fatal(1, "RV32M missing operation %0d", operation);
            $display("RV32M UNIT op=%0d vectors=%0d latency=%0d..%0d", operation,
                covered[operation], min_latency[operation], max_latency[operation]);
        end
        test_pass = 1;
        $display("RV32M UNIT PASS vectors=%0d resets=%0d; all arithmetic, input capture, back-to-back, busy reject and held completion", vectors, resets);
        $stop;
    end
    initial begin #200000000; $fatal(1, "RV32M unit timeout"); end
endmodule
