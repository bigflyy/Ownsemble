import importlib.util
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('linux_proof_source', Path(__file__).with_name('linux-proof-source.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class SourceArchiveTests(unittest.TestCase):
    def test_archive_contains_source_without_runtime_data_or_existing_builds(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            files = ['AGENTS.md', 'app/pubspec.yaml', 'app/pubspec.lock',
                     'app/lib/main.dart', 'app/assets/preview.mp3',
                     'app/test/example_test.dart', 'app/tool/probe.dart',
                     'app/linux/CMakeLists.txt',
                     '.local/sentinel.txt', 'app/build/sentinel.txt',
                     'app/.dart_tool/sentinel.txt', 'app/lib/.env',
                     'app/windows/sentinel.txt',
                     'app/linux/flutter/ephemeral/sentinel.txt']
            for name in files:
                file = root / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text('generated fixture')
            archive = root / 'source.tar'
            count = module.create_source_archive(root, archive)
            with tarfile.open(archive) as source:
                names = set(source.getnames())
            self.assertEqual(names, set(files[:8]))
            self.assertEqual(count, 8)

    def test_source_symlink_is_rejected_without_reading_its_target(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'app/lib').mkdir(parents=True)
            target = root / 'outside.txt'
            target.write_text('generated target')
            link = root / 'app/lib/link.dart'
            try:
                link.symlink_to(target)
            except OSError:
                self.skipTest('OS does not allow fixture symlinks')
            with self.assertRaisesRegex(ValueError, 'source_symlink'):
                module.create_source_archive(root, root / 'source.tar')

if __name__ == '__main__':
    unittest.main()
