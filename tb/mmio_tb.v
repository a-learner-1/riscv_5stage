`timescale 1ns/1ps

module mmio_tb;
    reg clk = 1'b0;
    reg rst_n = 1'b0;

    wire [31:0] pc_x;
    wire [31:0] instr_x;
    wire        valid_x;
    wire [31:0] wb_pc;
    wire [4:0]  wb_rd;
    wire [31:0] wb_data;
    wire        wb_we;
    wire        retire_valid;
    wire [63:0] cycle_count;
    wire [63:0] instret_count;
    wire        mmio_putchar_valid;
    wire [7:0]  mmio_putchar_data;

    assign mmio_putchar_valid = dut.mmio_putchar_valid;
    assign mmio_putchar_data  = dut.mmio_putchar_data;

    integer watchdog_cycles;
    integer putchar_pulses;
    reg     character_seen;

    cpu_top #(
        .PROGRAM_FILE("programs/mmio_test.hex"),
        .IMEM_WORDS(64),
        .DMEM_WORDS(64),
        .DMEM_BASE_ADDR(32'h0001_0000)
    ) dut (
        .clk(clk),
        .rst_n(rst_n), .uart_rx(1'b1),
        .pc_x(pc_x),
        .instr_x(instr_x),
        .valid_x(valid_x),
        .wb_pc(wb_pc),
        .wb_rd(wb_rd),
        .wb_data(wb_data),
        .wb_we(wb_we),
        .retire_valid(retire_valid),
        .cycle_count(cycle_count),
        .instret_count(instret_count), .gpio_in(8'd0), .gpio_out(), .gpio_oe(), .uart_tx()
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        #1;
        if (rst_n && mmio_putchar_valid) begin
            putchar_pulses = putchar_pulses + 1;
            character_seen = 1'b1;

            if (mmio_putchar_data !== 8'h41)
                $fatal(1, "MMIO putchar mismatch: got=%h expected=41",
                       mmio_putchar_data);
        end
    end

    initial begin
        watchdog_cycles = 0;
        putchar_pulses = 0;
        character_seen = 1'b0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        while (!character_seen) begin
            @(posedge clk);
            #2;
            watchdog_cycles = watchdog_cycles + 1;

            if (watchdog_cycles > 100)
                $fatal(1, "MMIO test timeout pc=%h instr=%h",
                       pc_x, instr_x);
        end

        // Allow the one-cycle output pulse to return low.
        @(posedge clk);
        #2;

        if (putchar_pulses != 1)
            $fatal(1, "Expected one putchar pulse, got=%0d", putchar_pulses);

        if (mmio_putchar_valid !== 1'b0)
            $fatal(1, "mmio_putchar_valid did not return low");

        if ((dut.u_regfile.regs[2] === 32'hxxxx_xxxx) ||
            (dut.u_regfile.regs[2] == 32'd0))
            $fatal(1, "cycle counter MMIO read failed: x2=%h",
                   dut.u_regfile.regs[2]);

        if ((dut.u_regfile.regs[4] === 32'hxxxx_xxxx) ||
            (dut.u_regfile.regs[4] == 32'd0))
            $fatal(1, "instret counter MMIO read failed: x4=%h",
                   dut.u_regfile.regs[4]);

        if (dut.u_regfile.regs[2] > cycle_count[31:0])
            $fatal(1, "cycle snapshot is newer than live counter");

        if (dut.u_regfile.regs[4] > instret_count[31:0])
            $fatal(1, "instret snapshot is newer than live counter");

        // None of the three MMIO transactions may touch ordinary RAM.
        if (dut.u_data_mem.mem[0] !== 32'd0)
            $fatal(1, "MMIO access incorrectly modified data RAM");

        // The DUT printed the character with $write, so terminate that line
        // before printing the test summary.
        $display("");
        $display("MMIO: character='%c' (0x%02h)",
                 mmio_putchar_data, mmio_putchar_data);
        $display("MMIO: cycle snapshot=%0d live=%0d",
                 dut.u_regfile.regs[2], cycle_count);
        $display("MMIO: instret snapshot=%0d live=%0d",
                 dut.u_regfile.regs[4], instret_count);
        $display("PASS: MMIO counters and character output");
        $stop;
    end
endmodule
