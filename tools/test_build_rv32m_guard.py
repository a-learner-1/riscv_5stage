"""RV32IM build identity and instruction-set guards; no PDS/hardware."""
import contextlib
import io
from pathlib import Path
import sys
import unittest
from unittest import mock

import build_coremark_images as common
import build_coremark_axi_images as axi
import build_pds_board as pds
from coremark_axi_contract import validate_coremark_axi_firmware


def words(*values):
    return b"".join(value.to_bytes(4, "little") for value in values)


class Rv32mBuildGuards(unittest.TestCase):
    def top(self):
        return (Path(__file__).resolve().parents[1] / "rtl/coremark_axi_board_top.v").read_text(encoding="utf-8").replace("module coremark_axi_board_top #(", "module board_top #(")

    def test_legacy_defaults_and_m_outputs_are_distinct(self):
        for profile in ("smoke", "smoke-validation", "performance", "validation"):
            old, _ = axi.parse_args(["--cache", "on", "--btb", "on", "--backend", "bram", "--profile", profile])
            new, _ = axi.parse_args(["--cache", "on", "--btb", "on", "--backend", "bram", "--profile", profile, "--isa", "rv32im"])
            self.assertEqual(old[0].isa, "rv32i")
            self.assertEqual(new[0].isa, "rv32im")
            self.assertEqual(old[0].clock_hz, 50000000)
            self.assertEqual(new[0].clock_hz, 50000000)
            self.assertEqual(old[0].name, "d0_cache_on_btb_" + profile.replace("-", "_"))
            self.assertEqual(new[0].name, "d0_m_cache_on_btb_" + profile.replace("-", "_"))
            self.assertEqual(new[0].seeds, old[0].seeds)

    def test_all_eight_m_encodings_only_accepted_by_m_guard(self):
        for funct3 in range(8):
            instruction = (1 << 25) | (2 << 20) | (1 << 15) | (funct3 << 12) | (3 << 7) | 0x33
            common.validate_linked_text(words(instruction), "rv32im")
            with self.assertRaisesRegex(RuntimeError, "Non-RV32I instruction"):
                common.validate_rv32i(words(instruction))

    def test_m_guard_still_rejects_compressed_csr_and_other_extensions(self):
        for instruction in (0x00000001, 0x04000033, 0x02001013, 0x300110f3, 0x00002007):
            with self.subTest(instruction=hex(instruction)), self.assertRaises(RuntimeError):
                common.validate_linked_text(words(instruction), "rv32im")
        with self.assertRaises(RuntimeError):
            common.validate_linked_text(b"\x01\x00", "rv32im")

    def test_strict_multilib_no_implicit_fallback(self):
        available = ".;\nrv32i/ilp32;@march=rv32i@mabi=ilp32\nrv32im/ilp32;@march=rv32im@mabi=ilp32\nrv32imc/ilp32;@march=rv32imc@mabi=ilp32\n"
        common.validate_multilib("rv32im", "rv32im/ilp32", available)
        common.validate_multilib("rv32i", "rv32i/ilp32", available)
        for selected in (".", "rv32i/ilp32", "rv32imc/ilp32", "missing"):
            with self.subTest(selected=selected), self.assertRaisesRegex(RuntimeError, "explicit rv32im/ilp32"):
                common.validate_multilib("rv32im", selected, available)

    def test_board_variant_binds_m_and_old_variant_disables_m(self):
        for isa, enabled in (("rv32i", 0), ("rv32im", 1)):
            bound = pds.bind_coremark_axi_board_parameters(self.top(), "on", "on", "bram", isa)
            self.assertNotIn("module board_top #(", bound)
            self.assertRegex(bound, r"localparam integer ENABLE_M = " + str(enabled) + r";")
        self.assertEqual(pds.coremark_isa("coremark_d0_btb"), "rv32i")
        self.assertEqual(pds.coremark_isa("coremark_d0_m_btb"), "rv32im")
        self.assertEqual(pds.coremark_axi_firmware_name("coremark_d0_m_btb", "performance"), "coremark_d0_m_cache_on_btb_performance")

    def test_documented_seed_is_exclusive_to_m_variant(self):
        self.assertEqual(pds.place_route_command("coremark_d0_m_btb"),
                         "pnr -gplace_seed 1 -groute_seed 1")
        for variant in ("default", "axi_burst_demo_board", *pds.COREMARK_AXI_VARIANTS):
            if variant != "coremark_d0_m_btb":
                with self.subTest(variant=variant):
                    self.assertEqual(pds.place_route_command(variant), "pnr")

    def test_top_default_and_m_forwarding_cannot_drift(self):
        for old, new in (("ENABLE_M = 0", "ENABLE_M = 1"), (".ENABLE_M(ENABLE_M)", ".ENABLE_M(0)")):
            with self.subTest(new=new), self.assertRaises(RuntimeError):
                pds.bind_coremark_axi_board_parameters(self.top().replace(old, new), "on", "on", "bram", "rv32im")

    def test_cross_isa_variant_rejected_before_any_tool(self):
        for variant, firmware in (("coremark_d0_m_btb", "coremark_d0_cache_on_btb_performance"), ("coremark_d0_btb", "coremark_d0_m_cache_on_btb_performance")):
            with self.subTest(variant=variant), mock.patch.object(sys, "argv", ["build_pds_board.py", "--variant", variant, "--firmware", firmware]), mock.patch.object(pds.subprocess, "run") as run, contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    pds.main()
                run.assert_not_called()

    def test_contract_requires_explicit_matching_instruction_set(self):
        for firmware, isa in (("coremark_d0_m_cache_on_btb_smoke", "rv32i"), ("coremark_d0_cache_on_btb_smoke", "rv32im")):
            with self.subTest(isa=isa), self.assertRaisesRegex(RuntimeError, "hardware ISA"):
                validate_coremark_axi_firmware(firmware, "on", simulation=True, btb_mode="on", backend="bram", isa=isa)

    def test_legacy_reserved_image_names_reject_m(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            common.parse_args(["--isa", "rv32im", "--name", "smoke"])


if __name__ == "__main__":
    unittest.main()
