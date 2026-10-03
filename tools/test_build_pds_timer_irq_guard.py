"""Ensure hardware builds reject a simulation image and stale timer firmware."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from build_pds_board import validate_timer_irq_board_firmware


class TimerBoardGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="timer_board_guard_")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "programs").mkdir()
        (self.root / "software").mkdir()
        (self.root / "build/timer_irq_board_firmware").mkdir(parents=True)
        payloads = {"programs/timer_irq_board.hex": "00000013\n",
                    "programs/timer_irq_board_data.hex": "017d7840\n",
                    "software/timer_irq_board.c": "fixture source\n"}
        for name, data in payloads.items():
            (self.root / name).write_text(data, encoding="ascii")
        self.report = {"image_kind": "MES50HP timer IRQ board", "clock_hz": 50000000,
                       "uart_baud": 115200, "requires_ENABLE_TRAPS": 1, "requires_ENABLE_TIMER_IRQ": 1,
                       "rom_words": 8192, "ram_words": 4096, "hardware_blink_cycles": 25000000,
                       "march": "rv32i_zicsr", "mabi": "ilp32",
                       "images_sha256": {name: self.digest(name) for name in payloads if name.startswith("programs/")},
                       "sources_sha256": {name: self.digest(name) for name in payloads if name.startswith("software/")}}
        self.path = self.root / "build/timer_irq_board_firmware/build_report.json"
        self.save()

    def digest(self, name):
        return hashlib.sha256((self.root / name).read_bytes()).hexdigest()

    def save(self):
        self.path.write_text(json.dumps(self.report), encoding="utf-8")

    def test_hardware_image_accepts(self):
        validate_timer_irq_board_firmware(self.root)

    def test_simulation_ram_rejected(self):
        (self.root / "programs/timer_irq_board_data.hex").write_text("000007d0\n", encoding="ascii")
        with self.assertRaisesRegex(RuntimeError, "does not match"):
            validate_timer_irq_board_firmware(self.root)

    def test_disabled_irq_or_wrong_clock_rejected(self):
        for key, value in (("requires_ENABLE_TIMER_IRQ", 0), ("clock_hz", 100000000)):
            old = self.report[key]
            self.report[key] = value;self.save()
            with self.assertRaisesRegex(RuntimeError, "incompatible"):
                validate_timer_irq_board_firmware(self.root)
            self.report[key] = old

    def test_changed_firmware_requires_rebuild(self):
        (self.root / "software/timer_irq_board.c").write_text("new source\n", encoding="ascii")
        with self.assertRaisesRegex(RuntimeError, "Stale"):
            validate_timer_irq_board_firmware(self.root)


if __name__ == "__main__":
    unittest.main()
