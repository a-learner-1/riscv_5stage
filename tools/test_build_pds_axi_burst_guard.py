"""Distinct demo identity/ELF/source guards; never start PDS."""
import contextlib
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

import build_axi_burst_demo_images as demo
import build_pds_board as pds


class AxiBurstDemoGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='axi_burst_demo_guard_')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in demo.SOURCES:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('fixture ' + name, encoding='utf-8')
        top = (Path(__file__).resolve().parents[1] / 'rtl/axi_burst_demo_board_top.v').read_text(encoding='utf-8')
        (self.root / 'rtl/axi_burst_demo_board_top.v').write_text(top, encoding='utf-8')
        soc = (Path(__file__).resolve().parents[1] / 'rtl/soc_axi_burst_demo_top.v').read_text(encoding='utf-8')
        (self.root / 'rtl/soc_axi_burst_demo_top.v').write_text(soc, encoding='utf-8')
        self.build = self.root / demo.BUILD_REL
        self.build.mkdir(parents=True)
        for name, payload in (('axi_burst_demo_board.elf', b'\x7fELFfixture'),
                              ('text.bin', bytes.fromhex('13000000')), ('data.bin', bytes.fromhex('78563412'))):
            (self.build / name).write_bytes(payload)
        for rel, first, fill, count in ((demo.IMAGES[0], '00000013', '00000013', 8192),
                                        (demo.IMAGES[1], '12345678', '00000000', 4096)):
            path = self.root / rel
            path.parent.mkdir(exist_ok=True)
            path.write_text(first + '\n' + (fill + '\n') * (count - 1), encoding='ascii')
        (self.root / demo.IMAGES[2]).write_text('`define AXI_BURST_DEMO_HARDWARE_INIT 1\n', encoding='ascii')
        self.report = {**demo.CONTRACT,
            'sources_sha256': {name: self.sha(name) for name in demo.SOURCES},
            'images_sha256': {name: self.sha(name) for name in demo.IMAGES},
            'artifacts_sha256': {demo.BUILD_REL + '/' + name: self.sha(demo.BUILD_REL + '/' + name)
                                for name in ('axi_burst_demo_board.elf', 'text.bin', 'data.bin')}}
        self.report_path = self.build / 'build_report.json'
        self.save()

    def sha(self, name):
        return hashlib.sha256((self.root / name).read_bytes()).hexdigest()

    def save(self):
        self.report_path.write_text(json.dumps(self.report), encoding='utf-8')

    def test_matching_firmware_accepts_without_pds(self):
        demo.validate_axi_burst_demo_firmware(self.root)

    def test_wrong_hardware_or_legacy_identity_rejected(self):
        for name, value in (('firmware', 'coremark_d0_cache_on_btb_performance'),
                            ('clock_hz', 100000000), ('uart_baud', 5000000),
                            ('formal_hardware_init', False), ('cnn_integrated', True),
                            ('enable_d0_bram', 0), ('enable_dcache', 0), ('btb_entries', 128),
                            ('csr_base', '0x30000000'), ('buffer_bytes_each', 8192)):
            with self.subTest(name=name):
                previous = self.report[name]
                self.report[name] = value
                self.save()
                with self.assertRaisesRegex(RuntimeError, 'Incompatible'):
                    demo.validate_axi_burst_demo_firmware(self.root)
                self.report[name] = previous
                self.save()

    def test_all_source_and_images_are_hash_bound(self):
        for name in ('software/axi_burst_demo.c', 'rtl/axi4_read_1x2.v', demo.IMAGES[0], demo.IMAGES[1], demo.IMAGES[2]):
            with self.subTest(name=name):
                path = self.root / name
                old = path.read_bytes()
                path.write_bytes(old + b'changed')
                with self.assertRaisesRegex(RuntimeError, 'Stale'):
                    demo.validate_axi_burst_demo_firmware(self.root)
                path.write_bytes(old)

    def test_rehashed_hex_still_must_match_elf_binary(self):
        path = self.root / demo.IMAGES[1]
        path.write_text(path.read_text().replace('12345678', '00000000'), encoding='ascii')
        self.report['images_sha256'][demo.IMAGES[1]] = self.sha(demo.IMAGES[1])
        self.save()
        with self.assertRaisesRegex(RuntimeError, 'not its recorded ELF binary'):
            demo.validate_axi_burst_demo_firmware(self.root)

    def test_rehashed_wrong_top_parameters_rejected(self):
        name = 'rtl/axi_burst_demo_board_top.v'
        path = self.root / name
        path.write_text(path.read_text().replace('.UART_BAUD(115200)', '.UART_BAUD(5000000)'), encoding='utf-8')
        self.report['sources_sha256'][name] = self.sha(name)
        self.save()
        with self.assertRaisesRegex(RuntimeError, 'geometry/wiring: UART_BAUD'):
            demo.validate_axi_burst_demo_firmware(self.root)

    def test_generated_top_has_no_parameter_override(self):
        source = (self.root / 'rtl/axi_burst_demo_board_top.v').read_text().replace('module axi_burst_demo_board_top #(', 'module board_top #(')
        top = pds.bind_axi_burst_demo_board_parameters(source)
        self.assertNotIn('module board_top #(', top)
        self.assertIn('localparam integer RESET_HOLD_CYCLES = 50000;', top)
        with self.assertRaisesRegex(RuntimeError, 'reset hold'):
            pds.bind_axi_burst_demo_board_parameters(source.replace('RESET_HOLD_CYCLES = 50000', 'RESET_HOLD_CYCLES = 2'))

    def test_rehashed_disabled_d0_or_cache_is_rejected(self):
        name = 'rtl/soc_axi_burst_demo_top.v'
        path = self.root / name
        original = path.read_text()
        for feature in ('ENABLE_D0_BRAM', 'ENABLE_ICACHE', 'ENABLE_DCACHE', 'ENABLE_BRANCH_PRED'):
            with self.subTest(feature=feature):
                path.write_text(original.replace('.' + feature + '(1)', '.' + feature + '(0)'), encoding='utf-8')
                self.report['sources_sha256'][name] = self.sha(name)
                self.save()
                with self.assertRaisesRegex(RuntimeError, 'real-CPU configuration'):
                    demo.validate_axi_burst_demo_firmware(self.root)

    def test_wrong_variant_firmware_pairs_rejected_before_subprocess(self):
        pairs = (('axi_burst_demo_board', 'coremark_d0_cache_on_btb_performance'),
                 ('coremark_d0_btb', 'axi_burst_demo_board'), ('default', 'axi_burst_demo_board'))
        for variant, firmware in pairs:
            with self.subTest(variant=variant), mock.patch.object(sys, 'argv',
                    ['build_pds_board.py', '--variant', variant, '--firmware', firmware]), \
                    mock.patch.object(pds.subprocess, 'run') as run, contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    pds.main()
                self.assertEqual(error.exception.code, 2)
                run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
