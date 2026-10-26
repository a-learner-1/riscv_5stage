"""Fixed CPU5 MES50HP implementation identity, distinct from CPU3 and S18."""
import re
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
TOP='rtl/cpu5_coremark_board_top.v'
CLOCK_HZ=50000000
UART_BAUD=115200
CACHE_SETS=64
BTB_ENTRIES=64
CACHE_GEOMETRY=0x02400010
BP_CONFIG=0x00400001
CONFIG=dict(clock_hz=CLOCK_HZ,uart_baud=UART_BAUD,isa='rv32im',backend='bram',backend_id=1,
            icache_ways=2,icache_sets=64,icache_line_bytes=16,dcache_ways=2,dcache_sets=64,dcache_line_bytes=16,
            btb_entries=64,branch_resolve_in_id=0,forwarding=1,stats_schema=4,profile_schema=2,
            profile_fields=10,rom_bytes=32768,ram_bytes=16384,reset_hold_cycles=50000)
BINDINGS=dict(IMEM_WORDS='8192',DMEM_WORDS='4096',DMEM_BASE_ADDR="32'h00010000",STATS_BASE_ADDR="32'h30000000",
 TRAP_VECTOR="32'h00000100",ENABLE_D0_BRAM='1',D0_REQ_WAIT_CYCLES='0',D0_RSP_WAIT_CYCLES='0',
 ENABLE_ICACHE='1',ICACHE_SETS='64',ICACHE_LINE_WORDS='4',ENABLE_DCACHE='1',DCACHE_SETS='64',DCACHE_LINE_WORDS='4',
 ENABLE_BRANCH_PRED='1',BTB_ENTRIES='64',BRANCH_RESOLVE_IN_ID='0',ENABLE_FORWARDING='1',ENABLE_M='1',
 UART_CLOCK_HZ='50000000',UART_BAUD='115200',UART_RX_FIFO_DEPTH='16',SIM_CONSOLE_ECHO='0',
 IMEM_REQ_WAIT_CYCLES='0',IMEM_RSP_WAIT_CYCLES='0',RAM_AW_WAIT_CYCLES='0',RAM_W_WAIT_CYCLES='0',
 RAM_AR_WAIT_CYCLES='0',RAM_B_WAIT_CYCLES='0',RAM_R_WAIT_CYCLES='0')

def validate_top(text):
    for name,value in BINDINGS.items():
        matches=re.findall(r'\.'+name+r'\(\s*([^\)]+)\s*\)',text)
        if matches!=[value]:raise ValueError('CPU5 board binding: '+name)
    for name in ('irq_external','irq_software','irq_timer'):
        if re.findall(r'\.'+name+r'\(([^\)]+)\)',text)!=["1'b0"]:raise ValueError('CPU5 board IRQ input: '+name)
    if len(re.findall(r'\bcpu5_stats_axi_lite_top\s*#\(',text))!=1 or re.search(r'\bsoc_coremark_axi_top\b',text):
        raise ValueError('CPU5 board must instantiate the real five-stage Stats SoC')
    if text.count('.gpio_in({keys_n, key1_n})')!=1 or text.count('assign led = gpio_out & gpio_oe;')!=1:
        raise ValueError('CPU5 board GPIO pin map')
    if text.count('.clk(clk_50m)')!=2 or text.count('.rst_n(cpu_rst_n)')!=1:
        raise ValueError('CPU5 board clock/reset map')

def bind_top(text,program,data):
    validate_top(text)
    pattern=r'module cpu5_coremark_board_top #\(\n    parameter PROGRAM_FILE = "[^"]+",\n    parameter DATA_FILE = "[^"]+",\n    parameter integer RESET_HOLD_CYCLES = 50000\n\)\('
    replacement='module board_top ('
    text,count=re.subn(pattern,replacement,text)
    if count!=1:raise ValueError('CPU5 board fixed parameter header')
    for path in (program,data):
        if not path.is_absolute() or not str(path).isascii() or any(c in str(path) for c in ('"','\n','\r',';','[',']','$')):
            raise ValueError('CPU5 board image path must be an absolute ASCII literal')
    marker='    wire cpu_rst_n;'
    constants='    localparam PROGRAM_FILE = "'+program.as_posix()+'";\n    localparam DATA_FILE = "'+data.as_posix()+'";\n    localparam integer RESET_HOLD_CYCLES = 50000;\n'
    if text.count(marker)!=1:raise ValueError('CPU5 board localparam anchor')
    return text.replace(marker,constants+marker,1)
