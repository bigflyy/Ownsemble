"""Plan 10 I2b: the app's Kim Vocal 2 (Dart) against audio-separator 0.48.0.

Reads what app/tool/check_separator.dart kept in OUT_DIR: for each song,
<name>.mix.f32 (the mix the app decoded, 44.1 kHz stereo float), <name>.vocals.f32
(the app's vocals before the last scale) and <name>.vocals16.f32 (16 kHz mono,
what the app keeps). Runs audio-separator's own MDX demix on the same mix (on the
CPU: the GPU is hidden), and prints per song:

- per channel, the signal to difference ratio of the app's vocals against
  audio-separator's (dB; higher is closer), on the whole song, around every chunk
  seam (where two chunks overlap) and over the last chunk, and the shift that
  lines them up best (must be 0);
- for the asymmetric song, the same with the channels crossed (must be low);
- the final scale both would apply;
- with --research DIR, the app's 16 kHz vocals against the research's FLAC
  (DIR/<name>.flac, audio-separator + ffmpeg), the same ratio and shift.

    PYTHONPATH=<pydeps-sep> CUDA_VISIBLE_DEVICES= python check_separator.py OUT_DIR
        --models DIR [--research DIR]

Prints numbers only (no song names).
"""

import argparse
import json
from pathlib import Path

import numpy as np

TRIM = 3840
CHUNK = 1024 * 255
STEP = int(0.75 * CHUNK)
GEN = CHUNK - 2 * TRIM


def ratio_db(ref, got):
    """10 log10(energy of ref / energy of the difference); inf when equal."""
    noise = float(np.sum((ref.astype(np.float64) - got) ** 2))
    signal = float(np.sum(ref.astype(np.float64) ** 2))
    if noise == 0:
        return float("inf")
    if signal == 0:
        return float("-inf")
    return 10 * np.log10(signal / noise)


def best_shift(ref, got, most=50):
    """The shift of got against ref (samples) with the highest correlation,
    over a middle stretch."""
    n = min(len(ref), len(got))
    mid = n // 2
    half = min(n // 4, 30 * 44100 // 2)
    a = ref[mid - half: mid + half].astype(np.float64)
    best, best_value = 0, -np.inf
    for shift in range(-most, most + 1):
        b = got[mid - half + shift: mid + half + shift].astype(np.float64)
        if len(b) != len(a):
            continue
        value = float(np.dot(a, b))
        if value > best_value:
            best, best_value = shift, value
    return best


def regions(n):
    """Sample ranges (in the song) around each chunk seam and the last chunk."""
    pad = GEN + TRIM - n % GEN
    padded = TRIM + n + pad
    starts = list(range(0, padded, STEP))
    seams = []
    for start in starts[1:]:
        # chunk i+1 starts at `start`; chunk i ends at start + CHUNK - STEP
        lo = max(0, start - TRIM)
        hi = min(n, start - TRIM + (CHUNK - STEP))
        if hi > lo:
            seams.append((lo, hi))
    last = (max(0, starts[-1] - TRIM), n)
    return seams, last, len(starts)


def read_stereo(path):
    data = np.fromfile(path, dtype="<f4")
    return data.reshape(-1, 2).T.copy()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out_dir")
    parser.add_argument("--models", required=True)
    parser.add_argument("--research")
    args = parser.parse_args()
    out = Path(args.out_dir)

    import tempfile
    from audio_separator.separator import Separator
    from audio_separator.separator.uvr_lib_v5 import spec_utils

    runs = [json.loads(line) for line in (out / "dart-runs.jsonl").read_text().splitlines() if line.strip()]
    seen = set()
    with tempfile.TemporaryDirectory() as scratch:
        separator = Separator(model_file_dir=args.models, output_dir=scratch, log_level=40)
        separator.load_model(model_filename="Kim_Vocal_2.onnx")
        model = separator.model_instance
        import onnxruntime
        print(json.dumps({"ort": onnxruntime.__version__, "ort_device": onnxruntime.get_device(),
                          "requested_providers": [str(p) for p in separator.onnx_execution_provider or []]}), flush=True)
        for run in runs:
            name = run["song"]
            if name in seen:
                continue
            seen.add(name)
            mix = read_stereo(out / f"{name}.mix.f32")
            app = read_stereo(out / f"{name}.vocals.f32")
            mix = model.prepare_mix(mix.T)
            peak = float(np.abs(mix).max())
            normalized = spec_utils.normalize(wave=mix.copy(), max_peak=0.9, min_peak=0.0)
            import time
            clock = time.time()
            ref = model.demix(normalized)
            ref_seconds = time.time() - clock
            scaled = ref * peak
            loud = float(np.abs(scaled).max())
            ref_scale = peak * (0.9 / loud if loud > 0.9 else 1.0)
            n = mix.shape[1]
            seams, last, chunks = regions(n)
            line = {"song": name, "seconds": round(n / 44100, 1), "chunks": chunks,
                    "app_frames": app.shape[1], "ref_frames": ref.shape[1],
                    "ref_cpu_s": round(ref_seconds, 1), "app_separate_s": round(run["separate_ms"] / 1000, 1),
                    "ref_scale": round(ref_scale, 6), "app_scale": round(run.get("scale", float("nan")), 6)}
            for c, label in ((0, "L"), (1, "R")):
                line[f"db_{label}"] = round(ratio_db(ref[c], app[c]), 1)
                if seams:
                    worst = min(seams, key=lambda r: ratio_db(ref[c, r[0]:r[1]], app[c, r[0]:r[1]]))
                    lo, hi = worst
                    line[f"seam_db_{label}"] = round(ratio_db(ref[c, lo:hi], app[c, lo:hi]), 1)
                    # The same in absolute terms: a quiet stretch has a low ratio for a small difference.
                    line[f"seam_diff_rms_{label}"] = float(np.sqrt(np.mean((ref[c, lo:hi].astype(np.float64) - app[c, lo:hi]) ** 2)))
                    line[f"seam_ref_rms_{label}"] = float(np.sqrt(np.mean(ref[c, lo:hi].astype(np.float64) ** 2)))
                    line[f"diff_rms_{label}"] = float(np.sqrt(np.mean((ref[c].astype(np.float64) - app[c]) ** 2)))
                line[f"last_db_{label}"] = round(ratio_db(ref[c, last[0]:last[1]], app[c, last[0]:last[1]]), 1)
                line[f"shift_{label}"] = best_shift(ref[c], app[c])
                line[f"max_diff_{label}"] = float(np.abs(ref[c] - app[c]).max())
            if name == "asym":
                line["crossed_db_LR"] = round(ratio_db(ref[0], app[1]), 1)
                line["crossed_db_RL"] = round(ratio_db(ref[1], app[0]), 1)
            if args.research and name != "asym":
                flac = Path(args.research) / f"{name}.flac"
                if flac.exists():
                    import soundfile
                    research, rate = soundfile.read(str(flac), dtype="float32")
                    app16 = np.fromfile(out / f"{name}.vocals16.f32", dtype="<f4")
                    m = min(len(research), len(app16))
                    line["e2e_rate"] = rate
                    line["e2e_len_research"] = len(research)
                    line["e2e_len_app"] = len(app16)
                    line["e2e_shift"] = best_shift(research[:m], app16[:m], most=400)
                    s = line["e2e_shift"]
                    if s >= 0:
                        a, b = research[: m - s], app16[s:m]
                    else:
                        a, b = research[-s:m], app16[: m + s]
                    line["e2e_db"] = round(ratio_db(a, b), 1)
                    line["e2e_db_unshifted"] = round(ratio_db(research[:m], app16[:m]), 1)
                    line["e2e_rms_research"] = float(np.sqrt(np.mean(research.astype(np.float64) ** 2)))
                    line["e2e_rms_app"] = float(np.sqrt(np.mean(app16.astype(np.float64) ** 2)))
            print(json.dumps(line), flush=True)


if __name__ == "__main__":
    main()
