import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('prepare_cef', Path(__file__).with_name('prepare-linux-browser.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def build(chromium, channel='stable', kind='minimal'):
    return {'channel': channel, 'chromium_version': chromium,
            'cef_version': chromium + '+fixture',
            'files': [{'type': kind, 'name': 'fixture_linux64_minimal.tar.bz2',
                       'size': 5, 'sha1': '0' * 40}]}


class PrepareBrowserTests(unittest.TestCase):
    def test_version_order_beats_upload_order_and_ignores_beta(self):
        index = {'linux64': {'versions': [build('152.0.9.8'), build('155.0.1.1', 'beta'),
                  build('154.0.10.9'), build('154.0.9.99')]}}
        self.assertEqual(module.select_stable(index)['chromium_version'], '154.0.10.9')

    def test_no_matching_stable_artifact_is_an_error(self):
        for versions in [[], [build('154.0.1.1', kind='client')], [build('154.0.1.1', 'beta')]]:
            with self.assertRaisesRegex(ValueError, 'stable_minimal_missing'):
                module.select_stable({'linux64': {'versions': versions}})

    def test_archive_requires_size_and_both_digests(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'generated.tar.bz2'
            path.write_bytes(b'generated fixture')
            pin = {'size': path.stat().st_size, 'sha1': hashlib.sha1(path.read_bytes()).hexdigest(),
                   'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
            module.verify_archive(path, pin)
            for key in ['size', 'sha1', 'sha256']:
                corrupt = dict(pin)
                corrupt[key] = 1 if key == 'size' else '0' * len(pin[key])
                with self.assertRaisesRegex(ValueError, 'archive_integrity'):
                    module.verify_archive(path, corrupt)

    def test_extract_rejects_traversal_and_links(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, link in [('sdk/../../escape', False), ('/escape', False), ('sdk/link', True)]:
                path = root / 'generated.tar'
                with tarfile.open(path, 'w') as archive:
                    item = tarfile.TarInfo(name)
                    if link:
                        item.type = tarfile.SYMTYPE
                        item.linkname = '/outside'
                    archive.addfile(item, None if link else io.BytesIO(b''))
                with self.assertRaisesRegex(ValueError, 'archive_path'):
                    module.extract_archive(path, root / 'out', 'sdk')

    def test_extract_valid_sdk_to_separate_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / 'generated.tar'
            with tarfile.open(path, 'w') as archive:
                item = tarfile.TarInfo('sdk/Release/generated.txt')
                item.size = 7
                archive.addfile(item, io.BytesIO(b'fixture'))
            module.extract_archive(path, root / 'out', 'sdk')
            self.assertEqual((root / 'out/sdk/Release/generated.txt').read_text(), 'fixture')


if __name__ == '__main__':
    unittest.main()
