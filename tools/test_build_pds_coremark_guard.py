"""Focused metadata/image integrity checks; never invoke PDS or hardware."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from build_pds_board import validate_coremark_board_firmware


class CoreMarkBoardGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="coremark_board_guard_")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def fixture(self, profile="performance", clock_hz=50000000):
        stem = "coremark_" + profile
        programs = self.root / "programs"
        programs.mkdir(exist_ok=True)
        report_dir = self.root / "build/coremark" / profile
        report_dir.mkdir(parents=True, exist_ok=True)
        payloads = {stem + ".hex": "00000013\n", stem + "_data.hex": "00000000\n",
                    stem + "_config.vh": f"`define COREMARK_CLOCK_HZ 32'd{clock_hz}\n"
                    "`define COREMARK_UART_BAUD 32'd115200\n`define COREMARK_FORMAL 1\n"}
        for name, payload in payloads.items():
            (programs / name).write_text(payload, encoding="ascii")
        report = {"profile": profile, "output_name": profile, "formal": True,
                  "clock_hz": clock_hz, "tick_hz": clock_hz, "uart_baud": 115200,
                  "seed_profile": profile, "rom_bytes": 32768, "ram_bytes": 16384,
                  "march": "rv32i", "mabi": "ilp32",
                  "images_sha256": {"programs/" + name: hashlib.sha256((programs / name).read_bytes()).hexdigest()
                                    for name in payloads}}
        report_path = report_dir / "build_report.json"
        report_path.write_text(json.dumps(report), encoding="utf-8")
        return stem, report_path

    def test_both_formal_profiles_accept_matching_build(self):
        for profile in ("performance", "validation"):
            stem, _ = self.fixture(profile)
            validate_coremark_board_firmware(stem, self.root)

    def test_rom_or_ram_replacement_rejected(self):
        for suffix in (".hex", "_data.hex"):
            stem, _ = self.fixture()
            (self.root / "programs" / (stem + suffix)).write_text("12345678\n", encoding="ascii")
            with self.assertRaisesRegex(RuntimeError, "does not match"):
                validate_coremark_board_firmware(stem, self.root)

    def test_unbound_config_rejected(self):
        stem, _ = self.fixture()
        path = self.root / "programs" / (stem + "_config.vh")
        path.write_text(path.read_text(encoding="ascii") + "// swapped metadata\n", encoding="ascii")
        with self.assertRaisesRegex(RuntimeError, "does not match"):
            validate_coremark_board_firmware(stem, self.root)

    def test_simulation_clock_rejected_even_with_matching_hashes(self):
        stem, _ = self.fixture(clock_hz=100000000)
        with self.assertRaisesRegex(RuntimeError, "CLOCK_HZ=50000000"):
            validate_coremark_board_firmware(stem, self.root)

    def test_wrong_profile_build_report_rejected(self):
        stem, path = self.fixture()
        report = json.loads(path.read_text(encoding="utf-8"))
        report["seed_profile"] = "validation"
        path.write_text(json.dumps(report), encoding="utf-8")
        with self.assertRaisesRegex(RuntimeError, "incompatible"):
            validate_coremark_board_firmware(stem, self.root)


if __name__ == "__main__":
    unittest.main()
