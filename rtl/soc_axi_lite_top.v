// CPU plus instruction ROM and a 32-bit AXI4-Lite data master.
// Attach an AXI slave in the surrounding FPGA design.
// UART/GPIO/counters still use the CPU's existing 0x2000xxxx MMIO path.
module soc_axi_lite_top #(
    parameter PROGRAM_FILE = "programs/c_demo.hex",
    parameter DATA_FILE = "programs/c_demo_data.hex",
    parameter integer IMEM_WORDS = 8192,
    parameter integer DMEM_WORDS = 4096,
    parameter [31:0] DMEM_BASE_ADDR = 32'h00010000,
    parameter integer UART_CLOCK_HZ = 100000000,
    parameter integer UART_BAUD = 115200,
    parameter integer UART_RX_FIFO_DEPTH = 16,
    parameter integer SIM_CONSOLE_ECHO = 1,
    parameter integer IMEM_REQ_WAIT_CYCLES = 0,
    parameter integer IMEM_RSP_WAIT_CYCLES = 0,
    parameter integer MMIO_REQ_WAIT_CYCLES = 0,
    parameter integer MMIO_RSP_WAIT_CYCLES = 0,
    parameter integer ENABLE_TRAPS = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        uart_rx,
    input  wire [7:0]  gpio_in,
    output wire        uart_tx,
    output wire [7:0]  gpio_out,
    output wire [7:0]  gpio_oe,
    output wire [31:0] pc_x,
    output wire [31:0] instr_x,
    output wire        valid_x,
    output wire [31:0] wb_pc,
    output wire [4:0]  wb_rd,
    output wire [31:0] wb_data,
    output wire        wb_we,
    output wire        retire_valid,
    output wire [63:0] cycle_count,
    output wire [63:0] instret_count,
    output wire        imem_fault,
    output wire [31:0] imem_fault_pc,
    output wire        dmem_fault,
    output wire [31:0] m_axi_awaddr,
    output wire [2:0] m_axi_awprot,
    output wire m_axi_awvalid,
    input wire m_axi_awready,
    output wire [31:0] m_axi_wdata,
    output wire [3:0] m_axi_wstrb,
    output wire m_axi_wvalid,
    input wire m_axi_wready,
    input wire [1:0] m_axi_bresp,
    input wire m_axi_bvalid,
    output wire m_axi_bready,
    output wire [31:0] m_axi_araddr,
    output wire [2:0] m_axi_arprot,
    output wire m_axi_arvalid,
    input wire m_axi_arready,
    input wire [31:0] m_axi_rdata,
    input wire [1:0] m_axi_rresp,
    input wire m_axi_rvalid,
    output wire m_axi_rready,
    output wire trap_valid,
    output wire [31:0] trap_pc,
    output wire [31:0] trap_cause,
    output wire [31:0] trap_tval
);
    wire imem_req_valid, imem_req_ready;
    wire [31:0] imem_req_addr;
    wire imem_rsp_valid, imem_rsp_ready, imem_rsp_error;
    wire [31:0] imem_rsp_rdata;
    wire dmem_req_valid, dmem_req_ready, dmem_req_write;
    wire [31:0] dmem_req_addr, dmem_req_wdata;
    wire [1:0] dmem_req_size;
    wire [3:0] dmem_req_wstrb;
    wire dmem_rsp_valid, dmem_rsp_ready, dmem_rsp_error;
    wire [31:0] dmem_rsp_rdata;

    cpu_top #(
        .PROGRAM_FILE(PROGRAM_FILE), .DATA_FILE(DATA_FILE),
        .IMEM_WORDS(IMEM_WORDS), .DMEM_WORDS(DMEM_WORDS),
        .DMEM_BASE_ADDR(DMEM_BASE_ADDR),
        .UART_CLOCK_HZ(UART_CLOCK_HZ), .UART_BAUD(UART_BAUD),
        .UART_RX_FIFO_DEPTH(UART_RX_FIFO_DEPTH),
        .SIM_CONSOLE_ECHO(SIM_CONSOLE_ECHO),
        .EXTERNAL_IMEM(1), .EXTERNAL_DMEM(1),
        .ENABLE_TRAPS(ENABLE_TRAPS),
        // These still control the existing local MMIO endpoint.
        .DMEM_REQ_WAIT_CYCLES(MMIO_REQ_WAIT_CYCLES),
        .DMEM_RSP_WAIT_CYCLES(MMIO_RSP_WAIT_CYCLES)
    ) u_cpu (
        .clk(clk), .rst_n(rst_n), .uart_rx(uart_rx), .uart_tx(uart_tx),
        .gpio_in(gpio_in), .gpio_out(gpio_out), .gpio_oe(gpio_oe),
        .pc_x(pc_x), .instr_x(instr_x), .valid_x(valid_x),
        .wb_pc(wb_pc), .wb_rd(wb_rd), .wb_data(wb_data), .wb_we(wb_we),
        .retire_valid(retire_valid), .cycle_count(cycle_count), .instret_count(instret_count),
        .imem_req_valid(imem_req_valid), .imem_req_ready(imem_req_ready),
        .imem_req_addr(imem_req_addr), .imem_rsp_valid(imem_rsp_valid),
        .imem_rsp_ready(imem_rsp_ready), .imem_rsp_rdata(imem_rsp_rdata),
        .imem_rsp_error(imem_rsp_error), .imem_fault(imem_fault),
        .imem_fault_pc(imem_fault_pc),
        .dmem_req_valid(dmem_req_valid), .dmem_req_ready(dmem_req_ready),
        .dmem_req_write(dmem_req_write), .dmem_req_addr(dmem_req_addr),
        .dmem_req_size(dmem_req_size), .dmem_req_wdata(dmem_req_wdata),
        .dmem_req_wstrb(dmem_req_wstrb), .dmem_rsp_valid(dmem_rsp_valid),
        .dmem_rsp_ready(dmem_rsp_ready), .dmem_rsp_rdata(dmem_rsp_rdata),
        .dmem_rsp_error(dmem_rsp_error), .dmem_fault(dmem_fault),
        .trap_valid(trap_valid), .trap_pc(trap_pc),
        .trap_cause(trap_cause), .trap_tval(trap_tval)
    );
    soc_instr_mem #(
        .WORDS(IMEM_WORDS), .INIT_FILE(PROGRAM_FILE),
        .REQ_WAIT_CYCLES(IMEM_REQ_WAIT_CYCLES), .RSP_WAIT_CYCLES(IMEM_RSP_WAIT_CYCLES)
    ) u_imem (
        .clk(clk), .rst_n(rst_n), .req_valid(imem_req_valid),
        .req_ready(imem_req_ready), .req_addr(imem_req_addr),
        .rsp_valid(imem_rsp_valid), .rsp_ready(imem_rsp_ready),
        .rsp_rdata(imem_rsp_rdata), .rsp_error(imem_rsp_error)
    );
    dmem_axi_lite_bridge u_bridge (
        .clk(clk), .rst_n(rst_n),
        .req_valid(dmem_req_valid), .req_ready(dmem_req_ready),
        .req_write(dmem_req_write), .req_addr(dmem_req_addr),
        .req_size(dmem_req_size), .req_wdata(dmem_req_wdata),
        .req_wstrb(dmem_req_wstrb), .rsp_valid(dmem_rsp_valid),
        .rsp_ready(dmem_rsp_ready), .rsp_rdata(dmem_rsp_rdata),
        .rsp_error(dmem_rsp_error),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awprot(m_axi_awprot),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arprot(m_axi_arprot),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready)
    );
    // synthesis translate_off
    initial begin
        if (({32'd0, DMEM_BASE_ADDR} < 64'h20010000) &&
            (({32'd0, DMEM_BASE_ADDR} + 64'd4 * DMEM_WORDS) > 64'h20000000))
            $fatal(1, "soc_axi_lite_top RAM range must not overlap CPU-local MMIO 0x2000xxxx");
    end
    // synthesis translate_on
endmodule
