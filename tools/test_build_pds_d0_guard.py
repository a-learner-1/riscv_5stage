"""D0 synthesis identity guards; no PDS executable is invoked."""
import contextlib
import io
from pathlib import Path
import sys
import unittest
from unittest import mock

import build_pds_board as pds


class D0BuildIdentityTests(unittest.TestCase):
    def top(self):
        text = (Path(__file__).resolve().parents[1] / 'rtl/coremark_axi_board_top.v').read_text(encoding='utf-8')
        return text.replace('module coremark_axi_board_top #(', 'module board_top #(')

    def test_distinct_firmware_names_and_backend(self):
        for profile in ('performance', 'validation'):
            self.assertEqual(pds.coremark_axi_firmware_name('coremark_d0_btb', profile),
                             'coremark_d0_cache_on_btb_' + profile)
            self.assertEqual(pds.coremark_axi_firmware_name('coremark_axi_btb', profile),
                             'coremark_axi_cache_on_btb_' + profile)
        self.assertEqual(pds.coremark_data_backend('coremark_d0_btb'), 'bram')
        self.assertEqual(pds.coremark_axi_btb_mode('coremark_d0_btb'), 'on')

    def test_backend_bound_to_localparams(self):
        for backend, value in (('axi', 0), ('bram', 1)):
            text = pds.bind_coremark_axi_board_parameters(self.top(), 'on', 'on', backend)
            self.assertNotIn('module board_top #(', text)
            self.assertRegex(text, r'localparam integer ENABLE_D0_BRAM = ' + str(value) + r';')
            self.assertRegex(text, r'ENABLE_ICACHE = 1, ENABLE_DCACHE = 1;')
            self.assertRegex(text, r'ENABLE_BRANCH_PRED = 1, BTB_ENTRIES = 64;')

    def test_default_must_remain_disabled(self):
        top = self.top().replace('ENABLE_D0_BRAM = 0', 'ENABLE_D0_BRAM = 1')
        with self.assertRaisesRegex(RuntimeError, 'default: ENABLE_D0_BRAM'):
            pds.bind_coremark_axi_board_parameters(top, 'on', 'on', 'bram')

    def test_bram_requires_both_caches_and_btb(self):
        for cache, btb in (('off', 'off'), ('on', 'off')):
            with self.assertRaisesRegex(RuntimeError, 'D0 BRAM requires'):
                pds.bind_coremark_axi_board_parameters(self.top(), cache, btb, 'bram')

    def test_unknown_backend_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'D0 BRAM requires'):
            pds.bind_coremark_axi_board_parameters(self.top(), 'on', 'on', 'unknown')

    def test_geometry_and_backend_forwarding_cannot_be_overridden(self):
        for original, replacement in (
            ('.DMEM_WORDS(4096)', '.DMEM_WORDS(2048)'),
            (".DMEM_BASE_ADDR(32'h00010000)", ".DMEM_BASE_ADDR(32'h00020000)"),
            ('.DCACHE_SETS(64)', '.DCACHE_SETS(128)'),
            ('.ENABLE_D0_BRAM(ENABLE_D0_BRAM)', '.ENABLE_D0_BRAM(0)'),
        ):
            with self.subTest(replacement=replacement), self.assertRaisesRegex(RuntimeError, 'geometry/wiring'):
                pds.bind_coremark_axi_board_parameters(self.top().replace(original, replacement), 'on', 'on', 'bram')

    def test_cross_backend_firmware_rejected_before_any_tool(self):
        for variant, firmware in (
            ('coremark_d0_btb', 'coremark_axi_cache_on_btb_performance'),
            ('coremark_axi_btb', 'coremark_d0_cache_on_btb_performance'),
            ('coremark_axi_on', 'coremark_d0_cache_on_btb_validation'),
        ):
            with self.subTest(variant=variant), mock.patch.object(sys, 'argv',
                    ['build_pds_board.py', '--variant', variant, '--firmware', firmware]), \
                    mock.patch.object(pds.subprocess, 'run') as run, contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as raised:
                    pds.main()
                self.assertEqual(raised.exception.code, 2)
                run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
