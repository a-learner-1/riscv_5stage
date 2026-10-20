"""Reject stale/failed bitstream-flow timing without starting PDS."""
import os
from pathlib import Path
import tempfile
import unittest

import build_pds_board as builder


def sta_text(slack="1.300", sequential_rows=8, pulse_rows=2):
    rows = ["Design Summary : All Constraints Met."]
    rows.extend(f"clk_50m clk_50m {slack} 0.000 0 26188"
                for _ in range(sequential_rows))
    rows.extend("clk_50m 8.100 0.000 0 8951" for _ in range(pulse_rows))
    return "\n".join(rows) + "\n"


class FinalStaGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.build = Path(self.temp.name)
        self.report = self.build / "report_timing/board_top.rtr"
        self.router = self.build / "place_route/board_top_timing_summary_after_hold_fix.txt"
        self.route = self.build / "place_route/board_top_pnr.adf"
        for path in (self.report, self.router, self.route):
            path.parent.mkdir(parents=True, exist_ok=True)
        self.report.write_text(sta_text(), encoding="utf-8")
        self.router.write_text(sta_text(slack="1.594", pulse_rows=0), encoding="utf-8")
        self.route.write_bytes(b"route used by the bitstream flow")
        # File mtimes and time.time() can differ by one floating-point ULP on
        # Windows even for a file written after the sampled start time. Make
        # these three deliberately fresh fixtures strictly newer than their
        # synthetic flow start; stale cases below still set start - 1 second.
        # The production bitstream guard retains its zero mtime tolerance.
        self.bit_started = min(path.stat().st_mtime for path in
                               (self.report, self.router, self.route)) - 0.001

    def verify(self):
        return builder.verify_post_bitstream_timing(self.build, self.bit_started)

    def test_replaces_initial_pass_with_bitstream_flow_rows(self):
        initial_rows, _ = builder.read_final_sta_report(self.report, self.bit_started)
        self.report.write_text(sta_text(slack="0.400"), encoding="utf-8")
        self.router.write_text(sta_text(slack="0.694", pulse_rows=0), encoding="utf-8")
        router_rows, final_rows, pulse_rows, route_hash = self.verify()
        self.assertEqual(initial_rows[0][0], "1.300")
        self.assertEqual(router_rows[0][0], "0.694")
        self.assertEqual(final_rows[0][0], "0.400")
        self.assertEqual((len(final_rows), len(pulse_rows)), (8, 2))
        self.assertEqual(len(route_hash), 64)

    def test_initial_pass_cannot_hide_subsequent_failure(self):
        builder.read_final_sta_report(self.report, self.bit_started)
        self.report.write_text(sta_text(slack="-0.100"), encoding="utf-8")
        with self.assertRaisesRegex(RuntimeError, "Final STA failed/incomplete"):
            self.verify()

    def test_initial_pass_cannot_replace_missing_new_report(self):
        builder.read_final_sta_report(self.report, self.bit_started)
        self.report.unlink()
        with self.assertRaisesRegex(RuntimeError, "Missing or stale.*require final STA"):
            self.verify()

    def test_stale_initial_pass_is_rejected_even_within_two_seconds(self):
        builder.read_final_sta_report(self.report, self.bit_started)
        old_time = self.bit_started - 1
        os.utime(self.report, (old_time, old_time))
        with self.assertRaisesRegex(RuntimeError, "Missing or stale.*require final STA"):
            self.verify()

    def test_all_eight_sequential_and_two_pulse_rows_are_required(self):
        for sequential, pulse in ((7, 2), (8, 1), (9, 2), (8, 3)):
            with self.subTest(sequential=sequential, pulse=pulse):
                self.report.write_text(sta_text(sequential_rows=sequential,
                                               pulse_rows=pulse), encoding="utf-8")
                with self.assertRaisesRegex(RuntimeError, "Final STA failed/incomplete"):
                    self.verify()

    def test_failed_pulse_width_and_failing_endpoint_are_rejected(self):
        for text in (sta_text().replace("8.100 0.000", "-0.100 0.000", 1),
                     sta_text().replace("0.000 0 26188", "-0.100 1 26188", 1),
                     sta_text().replace("0.000 0 26188", "0.000 0 0", 1),
                     sta_text().replace("All Constraints Met.", "Some Constraints Violated.")):
            with self.subTest(text=text):
                self.report.write_text(text, encoding="utf-8")
                with self.assertRaisesRegex(RuntimeError, "Final STA failed/incomplete"):
                    self.verify()

    def test_bitstream_flow_router_is_rechecked(self):
        for state in ("failed", "missing", "stale"):
            with self.subTest(state=state):
                self.router.write_text(sta_text(pulse_rows=0), encoding="utf-8")
                if state == "failed":
                    self.router.write_text(sta_text(slack="-0.100", pulse_rows=0),
                                           encoding="utf-8")
                elif state == "missing":
                    self.router.unlink()
                else:
                    old_time = self.bit_started - 1
                    os.utime(self.router, (old_time, old_time))
                with self.assertRaisesRegex(RuntimeError, "post-route|Post-route"):
                    self.verify()

    def test_missing_or_stale_route_database_is_rejected(self):
        for state in ("missing", "stale"):
            with self.subTest(state=state):
                self.route.write_bytes(b"route used by the bitstream flow")
                if state == "missing":
                    self.route.unlink()
                else:
                    old_time = self.bit_started - 1
                    os.utime(self.route, (old_time, old_time))
                with self.assertRaisesRegex(RuntimeError, "Missing or stale bitstream route"):
                    self.verify()

    def test_fresh_sbit_cannot_hide_stale_bin(self):
        bit_dir = self.build / "generate_bitstream"
        bit_dir.mkdir()
        (bit_dir / "board_top.sbit").write_bytes(b"new SBIT")
        bin_path = bit_dir / "board_top.bin"
        bin_path.write_bytes(b"old BIN")
        old_time = self.bit_started - 1
        os.utime(bin_path, (old_time, old_time))
        with self.assertRaisesRegex(RuntimeError, "stale bitstream output"):
            builder.read_bitstream_outputs(self.build, self.bit_started)
        bin_path.write_bytes(b"new BIN")
        outputs = builder.read_bitstream_outputs(self.build, self.bit_started)
        self.assertEqual(set(outputs), {"generate_bitstream/board_top.sbit",
                                        "generate_bitstream/board_top.bin"})


if __name__ == "__main__":
    unittest.main()
