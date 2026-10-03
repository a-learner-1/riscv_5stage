"""Boundary checks for the build configuration and linked ISA/image contract."""
import contextlib
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "tools/build_coremark_images.py"
SPEC = importlib.util.spec_from_file_location("coremark_build", SCRIPT)
build = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = build
SPEC.loader.exec_module(build)


class CoreMarkBuildContract(unittest.TestCase):
    def test_defaults_separate_short_checks_and_formal_measurement(self):
        smoke, _ = build.parse_args([])
        self.assertEqual((smoke.clock_hz, smoke.uart_baud, smoke.iterations, smoke.formal),
                         (100000000, 5000000, 1, False))
        for profile in ("performance", "validation"):
            config, _ = build.parse_args(["--profile", profile])
            self.assertEqual((config.clock_hz, config.uart_baud, config.iterations, config.formal),
                             (50000000, 115200, 0, True))
        validation, _ = build.parse_args(["--profile", "smoke-validation"])
        reject, _ = build.parse_args(["--profile", "formal-short"])
        self.assertEqual(validation.name, "smoke_validation")
        self.assertEqual(validation.seeds, "validation")
        self.assertEqual((reject.name, reject.formal, reject.iterations), ("formal_short", True, 1))

    def test_invalid_values_fail_before_compiler_or_output_creation(self):
        cases = [["--clock-hz", "0"], ["--clock-hz", "-1"], ["--clock-hz", "2147483648"],
                 ["--uart-baud", "0"], ["--uart-baud", "-5"], ["--uart-baud", "2147483648"],
                 ["--clock-hz", "1", "--uart-baud", "2"],
                 ["--iterations", "-1"], ["--iterations", "2147483648"], ["--iterations", "0"],
                 ["--profile", "smoke-validation", "--iterations", "0"],
                 ["--name", "../performance"], ["--name", "x/y"], ["--name", ""]]
        for args in cases:
            with self.subTest(args=args), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                build.parse_args(args)

    def test_signed_seed_max_and_formal_auto_are_accepted(self):
        config, cross = build.parse_args(["--iterations", "2147483647", "--cross", "custom-"])
        self.assertEqual(config.iterations, 0x7fffffff)
        self.assertEqual(cross, "custom-")
        formal, _ = build.parse_args(["--profile", "performance", "--iterations", "0"])
        self.assertTrue(formal.formal)
        maximum, _ = build.parse_args(["--clock-hz", "2147483647", "--uart-baud", "2147483647"])
        self.assertEqual((maximum.clock_hz, maximum.uart_baud), (0x7fffffff, 0x7fffffff))

    def test_changed_formal_timing_cannot_replace_the_board_default(self):
        for profile in ("performance", "validation"):
            for changed in (["--clock-hz", "100000000"], ["--uart-baud", "5000000"]):
                for name in ([], ["--name", profile], ["--name", profile.upper()]):
                    with self.subTest(profile=profile, changed=changed, name=name):
                        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                            build.parse_args(["--profile", profile, *changed, *name])
                config, _ = build.parse_args(["--profile", profile, *changed, "--name", "custom_timing"])
                self.assertEqual(config.name, "custom_timing")

    def test_profile_output_names_cannot_be_reused_by_other_profiles(self):
        for profile in build.PROFILES:
            for other in build.PROFILES:
                if other == profile:
                    continue
                for name in (other.replace("-", "_"), other.replace("-", "_").upper()):
                    with self.subTest(profile=profile, name=name):
                        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                            build.parse_args(["--profile", profile, "--name", name])

    def test_rv32i_validation_rejects_library_extension_instructions(self):
        build.validate_rv32i(bytes.fromhex("13000000330000006f000000"))
        for word in (0x02000033, 0x0000202f, 0x00000053, 0x00000001, 0xc0002073):
            with self.subTest(word=word), self.assertRaises(RuntimeError):
                build.validate_rv32i(word.to_bytes(4, "little"))
        with self.assertRaises(RuntimeError):
            build.validate_rv32i(b"\x13\0")

    def test_image_little_endian_tail_and_physical_fill(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "image.hex"
            build.image(bytes.fromhex("12345678ab"), target, 3, 0x13)
            self.assertEqual(target.read_text(), "78563412\n000000ab\n00000013\n")
            with self.assertRaises(RuntimeError):
                build.image(bytes(13), target, 3, 0)


if __name__ == "__main__":
    unittest.main()
