"""Generated native CEF comparison gates; not live-provider acceptance."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent

class CefProbeTest(unittest.TestCase):
    def test_windowless_muted_input_and_media(self):
        with tempfile.TemporaryDirectory(prefix='ownsemble-cef-evidence-') as folder:
            report = Path(folder) / 'report.json'
            result = subprocess.run([sys.executable, str(ROOT / 'spikes/linux-browser/cef_probe.py'),
                '--output', str(report)], capture_output=True, text=True, timeout=60)
            data = json.loads(report.read_text())
            destination = os.environ.get('OWNSEMBLE_CEF_PROBE_EVIDENCE')
            if destination:
                Path(destination).write_text(json.dumps(data, indent=2) + chr(10))
            self.assertEqual(result.returncode, 0, (result.stdout + result.stderr)[-1600:])
            for key in ('windowless', 'native_mute_before_load', 'document_start', 'trusted_click',
                        'focused_click', 'native_capture_configured', 'native_capture_received',
                        'native_capture_discarded', 'audio_playing_while_native_muted', 'media_clock_advanced',
                        'cached_request_observed', 'closed_cleanly'):
                with self.subTest(capability=key):
                    self.assertIs(data['checks'].get(key), True)
            self.assertEqual(data['fixture_network_asset_requests'], 1)
            self.assertGreaterEqual(data['fixture_asset_observations'], 2)
            self.assertNotIn('http', json.dumps(data))

    def test_native_window_stays_hidden_with_same_media_contract(self):
        with tempfile.TemporaryDirectory(prefix='ownsemble-cef-views-evidence-') as folder:
            report = Path(folder) / 'report.json'
            result = subprocess.run([sys.executable, str(ROOT / 'spikes/linux-browser/cef_probe.py'),
                '--native-window', '--output', str(report)], capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, (result.stdout + result.stderr)[-1600:])
            data = json.loads(report.read_text())
            self.assertIs(data['checks']['windowless'], False)
            for key in ('native_window_hidden', 'native_mute_before_load', 'document_start',
                        'trusted_click', 'focused_click', 'native_capture_received',
                        'native_capture_discarded', 'audio_playing_while_native_muted',
                        'media_clock_advanced', 'cached_request_observed', 'closed_cleanly'):
                with self.subTest(capability=key):
                    self.assertIs(data['checks'].get(key), True)
            destination = os.environ.get('OWNSEMBLE_CEF_VIEWS_EVIDENCE')
            if destination:
                Path(destination).write_text(json.dumps(data, indent=2) + chr(10))

if __name__ == '__main__':
    unittest.main()
