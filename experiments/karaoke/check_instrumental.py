"""Plan 11 D1d: compare the app's Inst HQ 4 instrumental (Dart, written by
app/tool/check_instrumental.dart as DART/<n>.inst.f32: 44.1 kHz stereo raw
float32, at the song's level) with audio-separator's output of the same
model (plan 11 A3b: REF/<n>.flac, normalised to peak 0.9).

The two differ by one gain (audio-separator normalises its output), so the
reference is scaled by the least-squares gain first. A lag between the two
decoders is searched within +-LAG samples on the loudest 10 s. Prints per
song: lag, gain, and the difference against the Dart output in dB (lower is
closer; the plan's research checks of Kim Vocal 2 reached about -40 dB and
below), plus the peaks.

    python check_instrumental.py --dart DIR --ref DIR 13 57
"""

import argparse
import subprocess
from pathlib import Path

import numpy as np

SAMPLE_RATE = 44100
LAG = 2048


def read_flac(path):
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path), "-f", "f32le", "-ac", "2",
         "-ar", str(SAMPLE_RATE), "pipe:1"],
        capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype="<f4").reshape(-1, 2).astype(np.float64)


def read_f32(path):
    return np.fromfile(path, dtype="<f4").reshape(-1, 2).astype(np.float64)


def best_lag(a, b):
    """The shift of b against a (b[i + lag] ~ a[i]) on a's loudest 10 s."""
    window = 10 * SAMPLE_RATE
    if len(a) <= window + 2 * LAG:
        return 0
    # Energy of each 1 s window by a running sum (a convolution with a
    # 44100-wide window took minutes).
    power = np.concatenate([[0.0], np.cumsum((a ** 2).sum(axis=1))])
    energy = power[SAMPLE_RATE:] - power[:-SAMPLE_RATE]
    start = int(np.clip(np.argmax(energy), LAG, len(a) - window - LAG))
    seg = a[start:start + window, 0]
    best, lag_at = -np.inf, 0
    for lag in range(-LAG, LAG + 1, 1):
        other = b[start + lag:start + lag + window, 0]
        if len(other) < window:
            continue
        score = float(np.dot(seg, other))
        if score > best:
            best, lag_at = score, lag
    return lag_at


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dart", required=True)
    parser.add_argument("--ref", required=True)
    parser.add_argument("songs", nargs="+")
    args = parser.parse_args()
    for song in args.songs:
        dart = read_f32(Path(args.dart) / f"{song}.inst.f32")
        ref = read_flac(Path(args.ref) / f"{song}.flac")
        lag = best_lag(dart, ref)
        if lag >= 0:
            ref_aligned = ref[lag:]
            dart_aligned = dart
        else:
            ref_aligned = ref
            dart_aligned = dart[-lag:]
        n = min(len(dart_aligned), len(ref_aligned))
        a, b = dart_aligned[:n], ref_aligned[:n]
        gain = float((a * b).sum() / (b * b).sum())
        diff = a - gain * b
        db = 10 * np.log10((diff ** 2).sum() / (a ** 2).sum())
        print(f"song {song}: frames dart {len(dart)} ref {len(ref)}, lag {lag}, "
              f"gain {gain:.4f}, difference {db:.1f} dB, "
              f"peak dart {np.abs(dart).max():.3f} ref {np.abs(ref).max():.3f}")


if __name__ == "__main__":
    main()
