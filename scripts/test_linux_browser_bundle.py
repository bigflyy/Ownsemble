"""Actual generated Linux SDK bundle checks; opt in with OWNSEMBLE_CEF_BUILD."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


@unittest.skipUnless(os.environ.get('OWNSEMBLE_CEF_BUILD'), 'requires built native helper')
class BrowserBundleTests(unittest.TestCase):
    def test_install_is_complete_relocatable_and_not_a_symlink_into_sdk(self):
        with tempfile.TemporaryDirectory(prefix='ownsemble-generated-bundle-') as temporary:
            root = Path(temporary)
            result = subprocess.run(['cmake', '--install', os.environ['OWNSEMBLE_CEF_BUILD'],
                                     '--prefix', str(root)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            folder = root / 'lib/ownsemble_browser'
            for name in ['ownsemble_browser', 'libcef.so', 'icudtl.dat', 'resources.pak',
                         'chrome_100_percent.pak', 'chrome_200_percent.pak',
                         'v8_context_snapshot.bin', 'locales/en-US.pak',
                         'LICENSE.txt', 'cef-runtime.json']:
                path = folder / name
                self.assertTrue(path.is_file(), name)
                self.assertFalse(path.is_symlink(), name)
            dynamic = subprocess.check_output(['readelf', '-d', str(folder / 'ownsemble_browser')], text=True)
            paths = [line for line in dynamic.splitlines() if 'RUNPATH' in line or 'RPATH' in line]
            self.assertEqual(len(paths), 1)
            self.assertIn('[$ORIGIN]', paths[0])
            self.assertNotIn('/opt/', dynamic)
            self.assertFalse((folder / 'chrome-sandbox').exists())
            # No setuid helper: require the runtime's attested userns/seccomp path.
            self.assertTrue(os.access(folder / 'ownsemble_browser', os.X_OK))


if __name__ == '__main__':
    unittest.main()
