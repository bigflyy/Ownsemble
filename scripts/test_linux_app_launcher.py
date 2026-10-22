"""Linux harness routing tests with a generated executable; no real app/data."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('linux-app.sh').resolve()

class LauncherTests(unittest.TestCase):
    def invoke(self, arguments):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sdk = root / 'sdk'
            (sdk / 'bin/internal').mkdir(parents=True)
            (sdk / 'bin/internal/engine.version').write_text('a' * 40)
            binary = root / 'proof/workspace/app/build/linux/x64/debug/bundle/ownsemble'
            binary.parent.mkdir(parents=True)
            binary.write_text('#!/bin/sh\nprintf "%s" "$1"\n')
            binary.chmod(0o700)
            env = dict(os.environ, OWNSEMBLE_FLUTTER_SDK=str(sdk), OWNSEMBLE_LINUX_PROOF_ROOT=str(root / 'proof'))
            return subprocess.run(['bash', str(SCRIPT), *arguments], env=env, text=True, capture_output=True)

    def test_default_routes_to_generated_preview(self):
        result = self.invoke([])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '--demo')

    def test_browser_routes_to_generated_fixture_only(self):
        result = self.invoke(['browser', 'debug'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '--browser-smoke')

    def test_invalid_build_mode_is_rejected_before_launch(self):
        result = self.invoke(['preview', 'invalid'])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

if __name__ == '__main__':
    unittest.main()
