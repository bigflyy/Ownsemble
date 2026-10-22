"""Fixture cleanup may terminate only processes using the exact probe executable."""
import importlib.util
from pathlib import Path
import signal
import sys
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parent.parent / 'spikes/linux-browser'
sys.path.insert(0, str(SOURCE))

class CefCleanupTest(unittest.TestCase):
    def test_cleanup_matches_only_exact_generated_helper(self):
        spec = importlib.util.spec_from_file_location('cef_probe', SOURCE / 'cef_probe.py')
        probe = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(probe)
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            target = root / 'ownsemble_cef_probe'
            target.touch()
            for pid, executable in [('44', target), ('45', root / 'unrelated-app')]:
                (root / pid).mkdir()
                (root / pid / 'exe').symlink_to(executable)
            with patch.object(probe.os, 'kill') as kill:
                probe.kill_fixture_processes(target, root)
            kill.assert_called_once_with(44, signal.SIGKILL)

if __name__ == '__main__':
    unittest.main()
