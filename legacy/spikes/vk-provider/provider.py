"""Audio-only helper. Does not accept account passwords, tokens, or cookies."""

import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys

import requests
from vk_api.audio_url_decoder import decode_audio_url


class ProbeError(Exception):
    pass


def hls_failure_category(stderr):
    """Classify audio-helper stderr internally; never return its signed URLs."""
    text = stderr.decode("utf-8", errors="replace") if isinstance(stderr, bytes) else str(stderr)
    for status in (400, 401, 403, 404, 429):
        if re.search(rf"(?:HTTP error|Server returned)\s+{status}\b", text, re.I):
            return f"hls_http_{status}"
    lowered = text.lower()
    if "not on whitelist" in lowered:
        return "hls_protocol_rejected"
    if "extension" in lowered and any(word in lowered for word in ("allowed_extensions", "not allowed", "blocked", "mismatches")):
        return "hls_extension_rejected"
    if "unable to open key" in lowered or "error opening key" in lowered:
        return "hls_key_unavailable"
    if "tls" in lowered or "ssl" in lowered:
        return "hls_tls_failed"
    if "invalid data" in lowered:
        return "hls_invalid_data"
    if any(phrase in lowered for phrase in ("option not found", "unrecognized option", "error splitting the argument list")):
        return "hls_option_unsupported"
    if "codec" in lowered and any(phrase in lowered for phrase in ("not currently supported", "could not find tag", "not supported")):
        return "hls_codec_unsupported"
    if any(phrase in lowered for phrase in ("error when loading first segment", "failed to open segment", "error opening segment")):
        return "hls_segment_unavailable"
    if "permission denied" in lowered:
        return "hls_access_denied"
    if "failed to resolve" in lowered or "name or service not known" in lowered:
        return "hls_dns_failed"
    if "connection refused" in lowered or "connection reset" in lowered:
        return "hls_connection_failed"
    if "error opening output" in lowered or "unable to choose an output format" in lowered:
        return "hls_output_failed"
    if "error opening input" in lowered:
        return "hls_input_failed"
    return "hls_download_failed"


def make_session(payload):
    if any(key in payload for key in ("cookies", "password", "token", "authorization")):
        raise ProbeError("Account credentials are not accepted by the audio helper.")
    session = requests.Session()
    session.trust_env = False  # Avoid ambient .netrc credentials and proxy auth.
    session.headers.update({"User-Agent": payload["userAgent"]})
    return session


def decode_tracks(payload):
    tracks = []
    for track in payload["tracks"]:
        url = track["url"]
        if "audio_api_unavailable" in url:
            if not payload.get("userId"):
                raise ProbeError("VK account identifier is required to decode this audio link.")
            url = decode_audio_url(url, payload["userId"])
        tracks.append({**track, "url": url})
    return {"tracks": tracks}


def inspect_audio(path):
    probe = shutil.which("ffprobe")
    if not probe:
        raise ProbeError("FFprobe was not found on PATH.")
    result = subprocess.run(
        [probe, "-v", "error", "-protocol_whitelist", "file,pipe", "-show_format",
         "-show_streams", "-of", "json", str(path)],
        capture_output=True, timeout=30, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    if result.returncode:
        raise ProbeError("Saved response is not a readable audio file.")
    metadata = json.loads(result.stdout)
    streams = [stream for stream in metadata.get("streams", []) if stream["codec_type"] == "audio"]
    if not streams:
        raise ProbeError("Saved response contains no audio stream.")
    duration = float(metadata.get("format", {}).get("duration", 0))
    return {"duration": duration, "codec": streams[0]["codec_name"],
            "format": metadata["format"]["format_name"]}


def verify_audio(path):
    metadata = inspect_audio(path)
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise ProbeError("FFmpeg was not found on PATH.")
    result = subprocess.run(
        [ffmpeg, "-nostdin", "-v", "error", "-xerror", "-protocol_whitelist", "file,pipe",
         "-i", str(path), "-map", "0:a:0", "-f", "null", "-"],
        capture_output=True, timeout=max(90, metadata["duration"] * 2),
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    if result.returncode:
        raise ProbeError("Full offline audio decoding failed; cache was not marked complete.")
    metadata["bytes"] = path.stat().st_size
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    metadata["sha256"] = digest.hexdigest()
    metadata["fullDecode"] = True
    return metadata


def remux_for_browser(source, base):
    metadata = inspect_audio(source)
    containers = {"mp3": (".mp3", "mp3"), "aac": (".m4a", "ipod"),
                  "alac": (".m4a", "ipod"), "opus": (".webm", "webm"),
                  "vorbis": (".webm", "webm"), "flac": (".flac", "flac")}
    if metadata["codec"] not in containers:
        raise ProbeError("Audio codec has no verified browser container (hls_codec_unsupported).")
    extension, container = containers[metadata["codec"]]
    target = base.with_suffix(f".partial{extension}")
    command = [shutil.which("ffmpeg"), "-nostdin", "-v", "error", "-y",
               "-protocol_whitelist", "file,pipe", "-i", str(source), "-map", "0:a:0",
               "-c:a", "copy", "-f", container]
    if container == "ipod":
        command += ["-movflags", "+faststart"]
    result = subprocess.run(command + [str(target)], capture_output=True, timeout=90,
                            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    if result.returncode:
        target.unlink(missing_ok=True)
        raise ProbeError("Local audio remux failed (hls_codec_unsupported).")
    return target


def download(payload):
    from urllib.parse import urlparse

    url = payload["url"]
    parsed = urlparse(url)
    suffixes = ("vkuseraudio.net", "vkuseraudio.com", "useraudio.com", "userapi.com", "vk-cdn.net", "vk-cdn.me")
    host = parsed.hostname or ""
    if (parsed.scheme != "https" or parsed.username or parsed.password or parsed.port
            or not any(host == suffix or host.endswith("." + suffix) for suffix in suffixes)):
        raise ProbeError("The audio link is outside the allowed HTTPS VK audio CDNs.")
    # Only provider-returned URLs enter this operation; no URL input exists in UI.
    base = Path(payload["outputBase"])
    base.parent.mkdir(parents=True, exist_ok=True)
    partial = base.with_suffix(".partial.bin")
    source_partial = None
    hls = ".m3u8" in parsed.path.lower()
    if hls:
        # Matroska accepts source audio codecs that M4A rejects. The completed
        # local stream is then copied into a codec-appropriate browser container.
        partial = source_partial = base.with_suffix(".partial.mka")
    try:
        if hls:
            ffmpeg = shutil.which("ffmpeg")
            if not ffmpeg:
                raise ProbeError("FFmpeg is required to save this HLS track.")
            result = subprocess.run(
                [ffmpeg, "-nostdin", "-v", "error", "-y", "-rw_timeout", "30000000",
                 "-protocol_whitelist", "https,tls,tcp,crypto",
                 "-user_agent", payload["userAgent"], "-i", url, "-map", "0:a:0",
                 "-c:a", "copy", "-f", "matroska", str(partial)],
                capture_output=True, timeout=300,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
            if result.returncode:
                category = hls_failure_category(result.stderr)
                raise ProbeError(f"VK HLS download/remux failed ({category}). No complete cache file was published.")
            partial = remux_for_browser(partial, base)
        else:
            with make_session(payload) as session:
                with session.get(url, stream=True, timeout=(15, 45), allow_redirects=False) as response, partial.open("wb") as output:
                    if response.is_redirect:
                        raise ProbeError("Audio redirects require inspection; refresh the browser import first.")
                    response.raise_for_status()
                    for chunk in response.iter_content(128 * 1024):
                        output.write(chunk)
        metadata = verify_audio(partial)
        expected = float(payload.get("expectedDuration") or 0)
        if expected > 10 and metadata["duration"] < expected - 5:
            raise ProbeError("Retrieved audio is shorter than VK metadata; possible preview or incomplete file.")
        extension = (".m4a" if "mp4" in metadata["format"] else ".mp3" if metadata["format"] == "mp3"
                     else ".webm" if "webm" in metadata["format"] else ".flac" if metadata["format"] == "flac" else ".audio")
        final = base.with_suffix(extension)
        os.replace(partial, final)
        return {**metadata, "filename": final.name, "sourceKind": "hls" if hls else "direct"}
    finally:
        partial.unlink(missing_ok=True)
        if source_partial and source_partial != partial:
            source_partial.unlink(missing_ok=True)


def main():
    # Raw network exceptions can contain cookies or signed URLs; never return them.
    try:
        payload = json.load(sys.stdin)
        if any(key in payload for key in ("cookies", "password", "token", "authorization")):
            raise ProbeError("Account credentials are not accepted by the audio helper.")
        operation = payload["operation"]
        if operation == "decode":
            result = decode_tracks(payload)
        elif operation == "download":
            result = download(payload)
        elif operation == "verify":
            result = verify_audio(Path(payload["path"]))
        else:
            raise ProbeError("Unknown probe operation.")
        print(json.dumps({"ok": True, **result}, ensure_ascii=True))
    except ProbeError as error:
        print(json.dumps({"ok": False, "error": str(error)}))
    except requests.exceptions.Timeout:
        print(json.dumps({"ok": False, "error": "VK request timed out."}))
    except requests.exceptions.SSLError:
        print(json.dumps({"ok": False, "error": "TLS certificate validation failed. No validation was bypassed."}))
    except Exception as error:
        print(json.dumps({"ok": False, "error": f"Provider response was not supported ({type(error).__name__})."}))


if __name__ == "__main__":
    main()
