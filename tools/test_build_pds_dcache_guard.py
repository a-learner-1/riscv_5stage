"""Reject stale/mismatched cache board images before any hardware build."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from build_dcache_board_images import SOURCES
from build_pds_board import validate_dcache_board_firmware

class DataCacheBoardGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='dcache_board_guard_')
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.images=['programs/dcache_board'+suffix for suffix in ('.hex','_data.hex','_sim_data.hex','_symbols.vh')]
        for name in [*SOURCES,*self.images]:
            target=self.root/name
            target.parent.mkdir(parents=True,exist_ok=True)
            target.write_text('fixture '+name,encoding='utf-8')
        self.report={'image_kind':'MES50HP instruction and data cache board','clock_hz':50000000,
              'uart_baud':115200,'requires_ENABLE_ICACHE':1,'requires_ENABLE_DCACHE':1,
              'requires_ENABLE_TRAPS':1,'requires_ENABLE_TIMER_IRQ':1,
              'icache_ways':2,'icache_sets':64,'icache_line_bytes':16,
              'dcache_ways':2,'dcache_sets':64,'dcache_line_bytes':16,
              'dcache_policy':'write-through/no-write-allocate','rom_words':8192,'ram_words':4096,
              'hardware_blink_cycles':25000000,'march':'rv32i_zicsr','mabi':'ilp32',
              'sources_sha256':{name:self.digest(name) for name in SOURCES},
              'images_sha256':{name:self.digest(name) for name in self.images}}
        self.path=self.root/'build/dcache_board_firmware/build_report.json'
        self.path.parent.mkdir(parents=True)
        self.save()
    def digest(self,name):return hashlib.sha256((self.root/name).read_bytes()).hexdigest()
    def save(self):self.path.write_text(json.dumps(self.report),encoding='utf-8')
    def test_matching_board_accepted(self):validate_dcache_board_firmware(self.root)
    def test_mutated_images_and_symbols_rejected(self):
        for name in self.images:
            target=self.root/name
            original=target.read_bytes();target.write_bytes(b'changed image')
            with self.assertRaisesRegex(RuntimeError,'Stale'):validate_dcache_board_firmware(self.root)
            target.write_bytes(original)
    def test_mutated_source_rejected(self):
        (self.root/'software/dcache_workload.h').write_text('changed source',encoding='ascii')
        with self.assertRaisesRegex(RuntimeError,'Stale'):validate_dcache_board_firmware(self.root)
    def test_wrong_configuration_rejected(self):
        for name,value in [('requires_ENABLE_DCACHE',0),('requires_ENABLE_ICACHE',0),
                           ('clock_hz',100000000),('ram_words',8192),
                           ('hardware_blink_cycles',2000),('dcache_policy','write-back')]:
            prior=self.report[name];self.report[name]=value;self.save()
            with self.assertRaisesRegex(RuntimeError,'Incompatible'):validate_dcache_board_firmware(self.root)
            self.report[name]=prior
    def test_missing_report_rejected(self):
        self.path.unlink()
        with self.assertRaisesRegex(RuntimeError,'Run build_dcache_board'):validate_dcache_board_firmware(self.root)

if __name__=='__main__':unittest.main()
