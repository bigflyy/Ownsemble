"""Acceptance gates for a generated-only, native Linux browser feasibility probe."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent

class LinuxBrowserProbeTest(unittest.TestCase):
    def test_native_hidden_browser_capabilities(self):
        with tempfile.TemporaryDirectory(prefix='ownsemble-browser-evidence-') as folder:
            report = Path(folder) / 'capabilities.json'
            result = subprocess.run(
                [sys.executable, str(ROOT / 'spikes/linux-browser/probe.py'),
                 '--output', str(report)], capture_output=True, text=True, timeout=45)
            self.assertEqual(result.returncode, 0, 'native_probe_failed: ' + result.stderr[-1200:])
            data = json.loads(report.read_text())
            evidence = os.environ.get('OWNSEMBLE_BROWSER_PROBE_EVIDENCE')
            if evidence:
                destination = Path(evidence)
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_text(json.dumps(data, indent=2) + '\n')
            for key in ('sandbox_enabled', 'tls_fail_closed', 'ephemeral_session',
                        'dedicated_session', 'native_mute_before_load', 'document_start', 'hidden_document',
                        'trusted_click', 'focused_click', 'audio_playing_while_native_muted',
                        'cached_request_observed', 'independent_document', 'closed_cleanly'):
                with self.subTest(capability=key):
                    self.assertIs(data['checks'].get(key), True)
            self.assertEqual(data['fixture_network_asset_requests'], 1)
            self.assertGreaterEqual(data['fixture_asset_observations'], 2)
            self.assertNotIn('http', json.dumps(data))

    def test_visible_control_isolates_media_gate(self):
        with tempfile.TemporaryDirectory(prefix='ownsemble-browser-evidence-') as folder:
            report = Path(folder) / 'visible-control.json'
            result = subprocess.run(
                [sys.executable, str(ROOT / 'spikes/linux-browser/probe.py'),
                 '--visible-control', '--output', str(report)],
                capture_output=True, text=True, timeout=45)
            self.assertEqual(result.returncode, 0, result.stderr[-1200:])
            data = json.loads(report.read_text())
            self.assertIs(data['checks']['hidden_document'], False)
            self.assertIs(data['checks'].get('media_clock_advanced'), True)
            self.assertIs(data['checks']['audio_playing_while_native_muted'], True)
            self.assertEqual(data['fixture_audio_state']['audioCode'], 0)
            self.assertIs(data['checks']['sandbox_enabled'], True)
            evidence = os.environ.get('OWNSEMBLE_BROWSER_PROBE_CONTROL_EVIDENCE')
            if evidence:
                Path(evidence).write_text(json.dumps(data, indent=2) + chr(10))


if __name__ == '__main__':
    unittest.main()
