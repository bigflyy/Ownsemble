"""Local-file and failure-contract tests; none of these establish VK access."""

import io
import json
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch
import wave

import provider


def wav_bytes():
    output = io.BytesIO()
    with wave.open(output, "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(8000)
        audio.writeframes(b"\x00\x00" * 8000)
    return output.getvalue()


class ProviderTests(unittest.TestCase):
    def test_hls_source_codec_is_copied_into_a_compatible_browser_container(self):
        real_run = subprocess.run
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            source = directory / "source.wav"
            source.write_bytes(wav_bytes())
            fixture = directory / "synthetic.mka"
            real_run([shutil.which("ffmpeg"), "-nostdin", "-v", "error", "-y", "-i", str(source),
                      "-c:a", "libmp3lame", str(fixture)], check=True, capture_output=True, timeout=20)
            def run(command, **options):
                if "https://test.vkuseraudio.net/index.m3u8" in command:
                    self.assertIn("matroska", command)
                    Path(command[-1]).write_bytes(fixture.read_bytes())
                    return subprocess.CompletedProcess(command, 0, stdout=b"", stderr=b"")
                return real_run(command, **options)
            with patch.object(provider.subprocess, "run", side_effect=run):
                result = provider.download({"url": "https://test.vkuseraudio.net/index.m3u8", "userAgent": "synthetic",
                                            "outputBase": str(directory / "1_2"), "expectedDuration": 1})
            self.assertEqual(result["codec"], "mp3")
            self.assertEqual(result["filename"], "1_2.mp3")
            self.assertTrue(result["fullDecode"])
            self.assertFalse(any("partial" in path.name for path in directory.iterdir()))

    def test_hls_failure_category_omits_signed_destinations(self):
        source = b"https://test.vkuseraudio.net/song.m3u8?secret=DO_NOT_PRINT: Server returned 403 Forbidden"
        self.assertEqual(provider.hls_failure_category(source), "hls_http_403")
        self.assertEqual(provider.hls_failure_category(b"Protocol 'http' not on whitelist"), "hls_protocol_rejected")
        self.assertEqual(provider.hls_failure_category(b"URL secret=403"), "hls_download_failed")
        self.assertEqual(provider.hls_failure_category(b"Error opening input files: Option not found"), "hls_option_unsupported")
        self.assertEqual(provider.hls_failure_category(b"Could not find tag for codec: not currently supported"), "hls_codec_unsupported")

    def test_hls_failure_does_not_publish_audio_or_expose_stderr(self):
        result = subprocess.CompletedProcess([], 1, stdout=b"", stderr=b"HTTP error 403: https://test.vkuseraudio.net/?secret=DO_NOT_PRINT")
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(provider.shutil, "which", return_value="synthetic-ffmpeg"), patch.object(provider.subprocess, "run", return_value=result):
                with self.assertRaises(provider.ProbeError) as error:
                    provider.download({"url": "https://test.vkuseraudio.net/index.m3u8", "userAgent": "synthetic", "outputBase": str(Path(directory) / "1_2")})
            self.assertIn("hls_http_403", str(error.exception))
            self.assertNotIn("DO_NOT_PRINT", str(error.exception))
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_complete_local_file_decodes_without_network_protocols(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sample.wav"
            path.write_bytes(wav_bytes())
            result = provider.verify_audio(path)
            self.assertTrue(result["fullDecode"])
            self.assertAlmostEqual(result["duration"], 1, places=2)
            self.assertEqual(result["bytes"], path.stat().st_size)
            self.assertEqual(len(result["sha256"]), 64)

    def test_html_is_not_marked_as_audio(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "not-a-song.mp3"
            path.write_text("<html>Sign in</html>")
            with self.assertRaises(provider.ProbeError):
                provider.verify_audio(path)

    def test_session_credentials_rejected_before_network(self):
        with patch.object(provider.requests.Session, "request") as network:
            with self.assertRaisesRegex(provider.ProbeError, "not accepted"):
                provider.make_session({"cookies": [], "userAgent": "test"})
            network.assert_not_called()

    def test_audio_session_has_no_ambient_credentials(self):
        with provider.make_session({"userAgent": "test"}) as session:
            self.assertFalse(session.trust_env)
            self.assertEqual(len(session.cookies), 0)

    def test_incomplete_download_is_not_published(self):
        fake_session = MagicMock()
        response = fake_session.__enter__.return_value.get.return_value.__enter__.return_value
        response.is_redirect = False
        response.iter_content.return_value = [wav_bytes()]
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory) / "1_2"
            with patch.object(provider, "make_session", return_value=fake_session):
                with self.assertRaisesRegex(provider.ProbeError, "shorter"):
                    provider.download({"url": "https://test.vkuseraudio.net/test", "outputBase": str(base),
                                       "expectedDuration": 180})
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_untrusted_audio_destination_is_rejected(self):
        with self.assertRaisesRegex(provider.ProbeError, "outside"):
            provider.download({"url": "https://127.0.0.1/private"})

    def test_password_is_rejected_and_never_echoed(self):
        result = subprocess.run([sys.executable, str(Path(provider.__file__))],
                                input=json.dumps({"operation": "verify", "password": "DO_NOT_PRINT"}),
                                text=True, capture_output=True, timeout=10)
        self.assertFalse(json.loads(result.stdout)["ok"])
        self.assertNotIn("DO_NOT_PRINT", result.stdout + result.stderr)

    def test_failure_does_not_print_signed_url(self):
        payload = {"operation": "download", "url": "http://example.test/?secret=DO_NOT_PRINT"}
        result = subprocess.run([sys.executable, str(Path(provider.__file__))],
                                input=json.dumps(payload), text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0)
        body = json.loads(result.stdout)
        self.assertFalse(body["ok"])
        self.assertNotIn("DO_NOT_PRINT", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
