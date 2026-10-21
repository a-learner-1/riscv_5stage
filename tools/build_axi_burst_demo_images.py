"""Build/validate the distinct MES50HP AXI4 read-burst demonstration firmware.

This is CPU-commanded protocol-demo firmware, not CNN or CoreMark evidence.
ROM, initialized D0 RAM, configuration, ELF and all inputs are hash-bound.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

import build_coremark_images as common

ROOT = Path(__file__).resolve().parents[1]
NAME = 'axi_burst_demo_board'
BUILD_REL = 'build/axi_burst_demo_board_firmware'
RTL_SOURCES = (
    'instr_mem.v', 'instr_bus_adapter.v', 'branch_predictor.v', 'if_stage.v',
    'regfile.v', 'decoder.v', 'alu.v', 'rv32m_unit.v', 'data_mem.v', 'data_bus_adapter.v',
    'uart_tx.v', 'uart_rx.v', 'uart_rx_fifo.v', 'uart_rx_mmio.v', 'gpio_mmio.v',
    'machine_timer.v', 'cpu_top.v', 'board_reset.v', 'soc_instr_mem.v',
    'soc_data_mem.v', 'dmem_region_router.v', 'dmem_axi_lite_bridge.v',
    'axi_lite_ram.v', 'soc_axi_lite_top.v', 'instr_cache.v', 'data_cache.v',
    'axi_lite_coremark_stats.v', 'axi_lite_1x2.v',
    'axi_lite_burst_reader.v', 'axi4_read_1x2.v', 'axi4_read_ram.v',
    'soc_axi_burst_demo_top.v',
)
SOURCES = tuple('rtl/' + name for name in RTL_SOURCES) + (
    'rtl/axi_burst_demo_board_top.v', 'software/start.S', 'software/link.ld',
    'software/mmio.h', 'software/gpio.h', 'software/axi_burst_demo.c',
    'tools/build_axi_burst_demo_images.py', 'tools/build_coremark_images.py',
    'tools/build_pds_board.py', 'pds/board_top.fdc',
)
IMAGES = tuple('programs/' + NAME + suffix for suffix in ('.hex', '_data.hex', '_config.vh'))
CONTRACT = {
    'image_kind': 'MES50HP CPU-commanded AXI4 read-burst demo',
    'firmware': NAME, 'platform': 'axi4-read-burst-demo-d0-cache-btb',
    'formal_hardware_init': True, 'simulation_acceleration': False,
    'clock_hz': 50000000, 'uart_baud': 115200, 'reset_hold_cycles': 50000,
    'rom_words': 8192, 'ram_words': 4096, 'ram_base': '0x00010000',
    'march': 'rv32i', 'mabi': 'ilp32', 'all_linked_text_checked_rv32i': True,
    'enable_d0_bram': 1, 'data_backend': 'bram', 'data_backend_id': 1,
    'enable_icache': 1, 'enable_dcache': 1, 'enable_branch_pred': 1,
    'icache_ways': 2, 'dcache_ways': 2, 'cache_sets': 64, 'cache_line_bytes': 16,
    'btb_entries': 64, 'btb_entry_bits': 23, 'direction_counter_bits': 2,
    'stats_base': '0x30000000', 'stats_bytes': 512,
    'csr_base': '0x30001000', 'csr_bytes': 256, 'csr_id': '0x42525354', 'csr_version': 1,
    'buffer0_base': '0x40000000', 'buffer1_base': '0x40001000', 'buffer_bytes_each': 4096,
    'arlen_values': [0, 3], 'arsize': 2, 'arburst': 1,
    'expected_commands': 10, 'expected_ar_count': 10, 'expected_r_count': 34,
    'expected_seed_count': 12, 'cnn_integrated': False,
    'formal_score_measured': False, 'hardware_download_performed': False,
    'pass_uart': 'AXI4 READ BURST DEMO PASS\r\n', 'tohost_address': '0x00013ffc',
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def checked_paths(root, mapping, expected, label):
    require(isinstance(mapping, dict) and set(mapping) == set(expected), 'Incomplete ' + label + ' hash set')
    for name in expected:
        path = (root / name).resolve()
        require(path.is_relative_to(root.resolve()) and path.is_file() and sha(path) == mapping[name],
                'Stale AXI burst demo ' + label + ': ' + name)


def validate_board_top(top):
    require('module board_top #(' in top or 'module axi_burst_demo_board_top #(' in top, 'Wrong AXI burst board top')
    required = {'IMEM_WORDS': '8192', 'DMEM_WORDS': '4096', 'DMEM_BASE_ADDR': "32'h00010000", 'UART_CLOCK_HZ': '50000000',
        'UART_BAUD': '115200', 'UART_RX_FIFO_DEPTH': '16', 'SIM_CONSOLE_ECHO': '0',
        'STATS_BASE_ADDR': "32'h30000000", 'CSR_BASE_ADDR': "32'h30001000",
        'BUFFER0_BASE_ADDR': "32'h40000000", 'BUFFER1_BASE_ADDR': "32'h40001000", 'BUFFER_WORDS': '1024'}
    for name, value in required.items():
        require(len(re.findall(r'\.' + name + r'\s*\(\s*' + value + r'\s*\)', top)) == 1,
                'Wrong AXI burst board geometry/wiring: ' + name)
    require(re.search(r'parameter integer RESET_HOLD_CYCLES\s*=\s*50000\b', top), 'Wrong AXI burst reset hold')


def validate_soc_contract(text):
    core = re.search(r'soc_axi_lite_top\s*#\((.*?)\)\s*u_core\s*\(', text, re.S)
    require(core is not None, 'AXI burst demo must retain the real D0 CPU core')
    required = {'ENABLE_TRAPS': '1', 'ENABLE_TIMER_IRQ': '1', 'ENABLE_ICACHE': '1',
        'ENABLE_DCACHE': '1', 'ENABLE_D0_BRAM': '1', 'ENABLE_BRANCH_PRED': '1',
        'BTB_ENTRIES': '64', 'ICACHE_SETS': '64', 'ICACHE_LINE_WORDS': '4',
        'DCACHE_SETS': '64', 'DCACHE_LINE_WORDS': '4'}
    for name, value in required.items():
        require(len(re.findall(r'\.' + name + r'\s*\(\s*' + value + r'\s*\)', core[1])) == 1,
                'Wrong AXI burst real-CPU configuration: ' + name)


def validate_axi_burst_demo_firmware(root=ROOT):
    root = Path(root)
    path = root / BUILD_REL / 'build_report.json'
    require(path.is_file(), 'Run tools/build_axi_burst_demo_images.py first')
    try:
        report = json.loads(path.read_text(encoding='utf-8'))
    except (ValueError, UnicodeError) as error:
        raise RuntimeError('Invalid AXI burst demo build report') from error
    require(all(report.get(key) == value for key, value in CONTRACT.items()), 'Incompatible AXI burst demo hardware metadata')
    checked_paths(root, report.get('sources_sha256'), SOURCES, 'source')
    checked_paths(root, report.get('images_sha256'), IMAGES, 'image')
    artifacts = tuple(BUILD_REL + '/' + name for name in ('axi_burst_demo_board.elf', 'text.bin', 'data.bin'))
    checked_paths(root, report.get('artifacts_sha256'), artifacts, 'ELF/binary')
    require((root / artifacts[0]).read_bytes().startswith(b'\x7fELF'), 'Invalid AXI burst demo ELF')
    text, data = (root / artifacts[1]).read_bytes(), (root / artifacts[2]).read_bytes()
    common.validate_rv32i(text)
    for payload, rel, words, fill in ((text, IMAGES[0], 8192, 0x13), (data, IMAGES[1], 4096, 0)):
        require(len(payload) <= 4 * words, 'AXI burst demo image exceeds hardware memory')
        padded = payload + b'\0' * (-len(payload) % 4)
        expected = [int.from_bytes(padded[i:i+4], 'little') for i in range(0, len(padded), 4)]
        expected += [fill] * (words - len(expected))
        lines = (root / rel).read_text(encoding='ascii').splitlines()
        require(len(lines) == words and all(re.fullmatch(r'[0-9a-fA-F]{8}', line) for line in lines), 'Incomplete hardware ROM/RAM image')
        require([int(line, 16) for line in lines] == expected, 'Hardware image is not its recorded ELF binary')
    config = root / IMAGES[2]
    require('`define AXI_BURST_DEMO_HARDWARE_INIT 1' in config.read_text(encoding='ascii'), 'Simulation image cannot be used for PDS')
    validate_board_top((root / 'rtl/axi_burst_demo_board_top.v').read_text(encoding='utf-8'))
    validate_soc_contract((root / 'rtl/soc_axi_burst_demo_top.v').read_text(encoding='utf-8'))
    return config, path


def build(cross=None):
    require(common.ROOT == ROOT, 'Firmware helpers must belong to the same repository')
    build_dir = ROOT / BUILD_REL
    build_dir.mkdir(parents=True, exist_ok=True)
    (ROOT / 'programs').mkdir(exist_ok=True)
    (build_dir / 'build_report.json').unlink(missing_ok=True)
    inputs = {name: sha(ROOT / name) for name in SOURCES}
    tool = common.prefix(cross)
    commands = []
    elf = build_dir / (NAME + '.elf')
    flags = ['-march=rv32i', '-mabi=ilp32', '-O2', '-ffreestanding', '-fno-builtin',
        '-fno-stack-protector', '-fno-pic', '-msmall-data-limit=0', '-mno-relax',
        '-ffunction-sections', '-fdata-sections', '-Wall', '-Wextra', '-Werror',
        '-nostdlib', '-nostartfiles', '-static', '-Wl,-T,software/link.ld',
        '-Wl,--gc-sections', '-Wl,--no-relax', '-Wl,-Map,' + common.rel(build_dir / 'axi_burst_demo_board.map')]
    with (build_dir / 'build.log').open('w', encoding='utf-8') as log:
        version = common.run([tool + 'gcc', '--version'], log, commands).strip()
        options = ['-march=rv32i', '-mabi=ilp32']
        selected = common.run([tool + 'gcc', *options, '-print-multi-directory'], log, commands).strip()
        available = common.run([tool + 'gcc', '-print-multi-lib'], log, commands)
        entry = next((line for line in available.splitlines() if line.split(';')[0] == selected), '')
        require(';@march=rv32i@mabi=ilp32' in entry, 'Compiler must select explicit rv32i/ilp32 multilib')
        libgcc = Path(common.run([tool + 'gcc', *options, '-print-libgcc-file-name'], log, commands).strip())
        require(libgcc.is_file(), 'Missing selected RV32I libgcc')
        common.run([tool + 'gcc', *flags, 'software/start.S', 'software/axi_burst_demo.c', '-lgcc', '-o', common.rel(elf)], log, commands)
        binaries = {}
        for section in ('text', 'data'):
            target = build_dir / (section + '.bin')
            common.run([tool + 'objcopy', '-O', 'binary', '-j', '.' + section, common.rel(elf), common.rel(target)], log, commands)
            binaries[section] = target.read_bytes()
        common.validate_rv32i(binaries['text'])
        common.run([tool + 'objdump', '-d', '-S', common.rel(elf)], log, commands, build_dir / 'axi_burst_demo_board.dump')
        symbol_text = common.run([tool + 'nm', '-n', common.rel(elf)], log, commands, build_dir / 'axi_burst_demo_board.symbols')
    symbols = {}
    for line in symbol_text.splitlines():
        parts = line.split()
        if len(parts) == 3 and (parts[2].startswith('axi_burst_demo_') or parts[2] == 'tohost'):
            symbols[parts[2]] = int(parts[0], 16)
    require(symbols.get('tohost') == 0x13ffc and symbols.get('axi_burst_demo_status', 0) >= 0x10000, 'Missing real D0 RAM status/tohost symbols')
    common.image(binaries['text'], ROOT / IMAGES[0], 8192, 0x13)
    common.image(binaries['data'], ROOT / IMAGES[1], 4096, 0)
    config = ['// Generated distinct hardware AXI4 read-burst demo configuration.',
        '`define AXI_BURST_DEMO_HARDWARE_INIT 1', '`define AXI_BURST_DEMO_CLOCK_HZ 50000000',
        '`define AXI_BURST_DEMO_UART_BAUD 115200', '`define AXI_BURST_DEMO_EXPECTED_AR 10',
        '`define AXI_BURST_DEMO_EXPECTED_R 34', '`define AXI_BURST_DEMO_EXPECTED_SEEDS 12']
    for name, address in sorted(symbols.items()):
        config.append('`define ' + name.upper() + '_ADDR 32\'h' + f'{address:08x}')
    (ROOT / IMAGES[2]).write_text('\n'.join(config) + '\n', encoding='ascii')
    report = {**CONTRACT, 'sources_sha256': inputs, 'images_sha256': {name: sha(ROOT / name) for name in IMAGES},
        'artifacts_sha256': {p.relative_to(ROOT).as_posix(): sha(p) for p in (elf, build_dir / 'text.bin', build_dir / 'data.bin')},
        'text_bytes': len(binaries['text']), 'initialized_data_bytes': len(binaries['data']),
        'symbols': {name: f'0x{address:08x}' for name, address in symbols.items()},
        'compiler': version.splitlines()[0], 'compiler_flags': flags, 'compiler_commands': commands,
        'libgcc_path': str(libgcc), 'libgcc_sha256': sha(libgcc),
        'firmware_error_coverage': ['unaligned', 'unmapped', '4KiB-crossing', 'recovery-after-each'],
        'separate_testbench_error_coverage': ['first/middle/last subordinate RRESP errors', 'backpressure', 'reset'],
    }
    require({name: sha(ROOT / name) for name in SOURCES} == inputs, 'AXI burst demo inputs changed during build')
    (build_dir / 'build_report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    validate_axi_burst_demo_firmware(ROOT)
    print('AXI4 read-burst demo firmware built: ROM8192/RAM4096, 50MHz/115200 baud.')
    print('Expected commands=10, AR=10, R=34, seed writes=12. CNN integration: no.')
    print(build_dir / 'build_report.json')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cross')
    args = parser.parse_args()
    try:
        build(args.cross)
    except (RuntimeError, OSError) as error:
        print('ERROR: ' + str(error), file=sys.stderr)
        sys.exit(1)
