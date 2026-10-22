"""Real CMake orchestration with a tiny generated native subproject, no SDK."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

BUNDLE = Path(__file__).resolve().parent.parent / 'app/linux/browser_bundle.cmake'


class IncrementalBrowserTests(unittest.TestCase):
    def test_changed_native_source_rebuilds_inside_existing_flutter_build(self):
        with tempfile.TemporaryDirectory(prefix='ownsemble-generated-cmake-') as temporary:
            root = Path(temporary)
            (root / 'browser').mkdir()
            (root / 'browser_bundle.cmake').write_bytes(BUNDLE.read_bytes())
            (root / 'CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 3.21)
project(generated NONE)
set(BINARY_NAME generated_app)
set(CEF_ROOT generated_sdk CACHE PATH "")
add_custom_target(generated_app ALL)
include(browser_bundle.cmake)
''')
            (root / 'browser/CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 3.21)
project(generated_browser NONE)
add_custom_target(generated_output ALL
 COMMAND ${CMAKE_COMMAND} -E copy ${CMAKE_CURRENT_SOURCE_DIR}/version.txt ${CMAKE_CURRENT_BINARY_DIR}/version.txt)
''')
            version = root / 'browser/version.txt'
            version.write_text('first')
            build = root / 'build'
            def run(*args):
                result = subprocess.run(args, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            run('cmake', '-S', str(root), '-B', str(build), '-G', 'Ninja')
            run('cmake', '--build', str(build))
            output = build / 'browser_native/version.txt'
            self.assertEqual(output.read_text(), 'first')
            version.write_text('changed')
            run('cmake', '--build', str(build))
            self.assertEqual(output.read_text(), 'changed')
            # A verified engine upgrade must replace the prior CMake cache path.
            upgraded = str(root / 'new-generated-sdk')
            result = subprocess.run(['cmake', '-S', str(root), '-B', str(build)],
                env=dict(os.environ, OWNSEMBLE_CEF_ROOT=upgraded),
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            cache = (build / 'CMakeCache.txt').read_text()
            self.assertIn('CEF_ROOT:PATH=' + upgraded, cache)



if __name__ == '__main__':
    unittest.main()
