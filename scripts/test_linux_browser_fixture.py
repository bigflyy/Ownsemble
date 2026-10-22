"""The generated media server must support browser byte-range requests."""
import importlib.util
from pathlib import Path
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from http.server import ThreadingHTTPServer

PATH = Path(__file__).resolve().parent.parent / 'spikes/linux-browser/fixture.py'

class FixtureServerTest(unittest.TestCase):
    def test_audio_ranges(self):
        spec = importlib.util.spec_from_file_location('browser_fixture', PATH)
        fixture = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fixture)
        server = ThreadingHTTPServer(('127.0.0.1', 0), fixture.Fixture)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        base = f'http://127.0.0.1:{server.server_port}/tone.wav'
        try:
            with urlopen(base) as response:
                full = response.read()
            for value, expected in [('bytes=0-43', full[:44]), ('bytes=44-', full[44:]), ('bytes=-16', full[-16:])]:
                with self.subTest(value=value):
                    with urlopen(Request(base, headers={'Range': value})) as response:
                        self.assertEqual(response.status, 206)
                        self.assertEqual(response.read(), expected)
                        self.assertIn(f'/{len(full)}', response.headers['Content-Range'])
            with self.assertRaises(HTTPError) as error:
                urlopen(Request(base, headers={'Range': f'bytes={len(full)}-'}))
            self.assertEqual(error.exception.code, 416)
        finally:
            server.shutdown()
            server.server_close()
            worker.join(3)

if __name__ == '__main__':
    unittest.main()
