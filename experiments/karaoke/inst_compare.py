"""Plan 11 Stage A: two ways to take the voice out of a song, side by side.

Way 1, "minus" (no new model): the app's own Kim Vocal 2 separation, kept by
app/tool/check_separator.dart as SEP/<n>.mix.f32 (the decoded 44.1 kHz
stereo mix) and SEP/<n>.vocals.f32 (the vocals before the last scale), both
raw float32 little endian, interleaved stereo. The model saw the mix scaled
by scale_in (0.9 / peak when the peak is above 0.9, else 1), so the vocals
in the mix's own units are vocals / scale_in; the song without the voice is
mix - vocals / scale_in.

Way 2, "model": a dedicated instrumental model (default UVR-MDX-NET
Inst_HQ_5) by audio-separator, keeping its Instrumental stem.

Both written as 44.1 kHz stereo 24-bit FLAC to OUT/minus/<n>.flac and
OUT/model/<n>.flac, the original as OUT/original/<n>.flac, so the three
play at the same moment on the compare page. Prints per song: times, the
peaks (a peak above 1.0 would clip), and the RMS of each in dB.

    python inst_compare.py minus --sep SEP --out OUT 13 57 71
    PYTHONPATH=<pydeps-sep> python inst_compare.py model --audio DIR \
        --models DIR --out OUT [--model UVR-MDX-NET-Inst_HQ_5.onnx] 13 57 71

ffmpeg on PATH is used only to write FLAC (this experiment only; the app
never needs it).
"""

import argparse
import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

import numpy as np

SAMPLE_RATE = 44100
PEAK_LIMIT = 0.9


def write_flac(stereo, target):
    """Write interleaved float32 stereo samples as 24-bit FLAC with ffmpeg.

    A peak above 0.98 is first scaled down to 0.98 (the whole file by one
    gain), since FLAC clips at full scale and decoded MP3s and the mix minus
    the vocals go above it (session 65: peaks up to 1.42). Returns the gain.
    """
    peak = float(np.max(np.abs(stereo)))
    gain = 0.98 / peak if peak > 0.98 else 1.0
    stereo = stereo * gain
    target.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ar", str(SAMPLE_RATE),
         "-ac", "2", "-i", "pipe:0", "-c:a", "flac", "-sample_fmt", "s32",
         str(target)],
        input=np.ascontiguousarray(stereo, dtype="<f4").tobytes(), check=True)
    return gain


def read_flac(source):
    """Read a FLAC as interleaved float32 stereo at 44.1 kHz with ffmpeg."""
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(source), "-f", "f32le",
         "-ar", str(SAMPLE_RATE), "-ac", "2", "pipe:1"],
        capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype="<f4")


def db(samples):
    """RMS level in dB (full scale = 0 dB); -inf for silence."""
    rms = float(np.sqrt(np.mean(np.square(samples, dtype=np.float64))))
    return 20 * np.log10(rms) if rms > 0 else float("-inf")


def run_minus(args):
    """Way 1: mix minus the app's vocals, and the original mix itself."""
    sep = Path(args.sep)
    out = Path(args.out)
    for song in args.songs:
        clock = time.time()
        mix = np.fromfile(sep / f"{song}.mix.f32", dtype="<f4")
        vocals = np.fromfile(sep / f"{song}.vocals.f32", dtype="<f4")
        frames = min(len(mix), len(vocals)) // 2 * 2
        mix, vocals = mix[:frames], vocals[:frames]
        peak = float(np.max(np.abs(mix)))
        scale_in = PEAK_LIMIT / peak if peak > PEAK_LIMIT else 1.0
        minus = mix - vocals / scale_in
        mix_gain = write_flac(mix, out / "original" / f"{song}.flac")
        minus_gain = write_flac(minus, out / "minus" / f"{song}.flac")
        print(f"minus {song}: {time.time() - clock:.1f}s, mix peak {peak:.3f}, "
              f"minus peak {float(np.max(np.abs(minus))):.3f}, "
              f"gains {mix_gain:.3f} {minus_gain:.3f}, "
              f"mix {db(mix):.1f} dB, vocals {db(vocals / scale_in):.1f} dB, "
              f"minus {db(minus):.1f} dB", flush=True)


def run_model(args):
    """Way 2: a dedicated instrumental model by audio-separator."""
    import onnxruntime
    import torch

    # onnxruntime-gpu (CUDA 12) finds CUDA and cuDNN in PyTorch's own
    # folder; without this the MDX models fall back to the CPU.
    onnxruntime.preload_dlls(directory=os.path.join(torch.__path__[0], "lib"))
    from audio_separator.separator import Separator

    out = Path(args.out)
    with tempfile.TemporaryDirectory() as scratch:
        # Every stem is written; the kept one is the stem that is not the
        # vocals (named Instrumental, or Other / Karaoke in some models).
        separator = Separator(model_file_dir=args.models, output_dir=scratch,
                              output_format="FLAC", log_level=40)
        clock = time.time()
        separator.load_model(model_filename=args.model)
        print(f"model {args.model}: loaded in {time.time() - clock:.1f}s, "
              f"providers {onnxruntime.get_available_providers()}", flush=True)
        for song in args.songs:
            if (out / args.tag / f"{song}.flac").exists():
                continue
            clock = time.time()
            written = separator.separate(str(Path(args.audio) / f"{song}.mp3"))
            took = time.time() - clock
            names = [Path(name).name for name in written]
            kept = [n for n in names if "(instrumental)" in n.lower()] or \
                [n for n in names if "(vocals)" not in n.lower()]
            stem = Path(scratch) / kept[0]
            for name in names:
                if name != kept[0]:
                    (Path(scratch) / name).unlink(missing_ok=True)
            target = out / args.tag / f"{song}.flac"
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(stem), target)
            inst = read_flac(target)
            print(f"{args.tag} {song}: {took:.1f}s, stem {kept[0][-30:]}, peak "
                  f"{float(np.max(np.abs(inst))):.3f}, {db(inst):.1f} dB",
                  flush=True)


def run_page(args):
    """The listening page (compare_page.html beside this script): the
    original and every no-voice version given as tag=Label, the no-voice
    ones matched to the same RMS loudness (the quietest one's)."""
    import json

    out = Path(args.out)
    versions = [{"tag": "original", "label": "Original (with voice)"}]
    for pair in args.versions:
        tag, label = pair.split("=", 1)
        versions.append({"tag": tag, "label": label})
    songs = []
    for song in args.songs:
        levels = {}
        seconds = 0.0
        for version in versions[1:]:
            samples = read_flac(out / version["tag"] / f"{song}.flac")
            levels[version["tag"]] = db(samples)
            seconds = len(samples) / 2 / SAMPLE_RATE
        quietest = min(levels.values())
        gains = {"original": 1.0}
        gains.update({tag: 10 ** ((quietest - level) / 20)
                      for tag, level in levels.items()})
        residue_file = out / "residue.json"
        residue = (json.loads(residue_file.read_text(encoding="utf-8")).get(song, {})
                   if residue_file.exists() else {})
        songs.append({"id": song, "seconds": round(seconds, 1), "gains": gains,
                      "residue": residue})
        print(f"page {song}: " + ", ".join(
            f"{tag} {level:.1f} dB x{gains[tag]:.2f}"
            for tag, level in levels.items()), flush=True)
    page = (Path(__file__).parent / "compare_page.html").read_text(encoding="utf-8")
    data = json.dumps({"versions": versions, "songs": songs})
    (out / "compare.html").write_text(page.replace("__DATA__", data),
                                      encoding="utf-8")


def run_residue(args):
    """How much voice each no-voice version still has, measured by a vocal
    model that is not Kim Vocal 2 (default Mel-Band RoFormer Kim vocals), so
    way 1 is not judged by the model that made it.

    For each song: the model's vocals of the original mark the sung parts
    (0.5 s windows whose vocals are within 30 dB of the song's loudest
    vocal window). In those windows, voice left = 10 log10(energy of the
    vocals found in the version / energy of the whole version), in dB
    (lower is cleaner; scale free). The original's own figure is printed
    for reference. Results also go to OUT/residue.json for the page."""
    import json

    import onnxruntime
    import torch

    onnxruntime.preload_dlls(directory=os.path.join(torch.__path__[0], "lib"))
    from audio_separator.separator import Separator

    out = Path(args.out)
    tags = ["original"] + [pair.split("=", 1)[0] for pair in args.versions]
    window = SAMPLE_RATE // 2
    results = {}
    with tempfile.TemporaryDirectory() as scratch:
        separator = Separator(model_file_dir=args.models, output_dir=scratch,
                              output_format="FLAC", output_single_stem="Vocals",
                              log_level=40)
        separator.load_model(model_filename=args.model)
        for song in args.songs:
            energies = {}
            for tag in tags:
                source = out / tag / f"{song}.flac"
                clock = time.time()
                written = separator.separate(str(source))
                vocals_path = Path(scratch) / Path(written[0]).name
                vocals = read_flac(vocals_path)
                vocals_path.unlink()
                whole = read_flac(source)
                frames = min(len(vocals), len(whole)) // (2 * window)
                cut = frames * 2 * window
                v = np.square(vocals[:cut].reshape(frames, -1), dtype=np.float64).sum(1)
                w = np.square(whole[:cut].reshape(frames, -1), dtype=np.float64).sum(1)
                energies[tag] = (v, w, time.time() - clock)
            v0, _, _ = energies["original"]
            sung = v0 > v0.max() * 10 ** (-30 / 10)
            row = {}
            for tag, (v, w, took) in energies.items():
                n = min(len(sung), len(v))
                mask = sung[:n]
                left = 10 * np.log10(max(v[:n][mask].sum(), 1e-12) /
                                     max(w[:n][mask].sum(), 1e-12))
                row[tag] = round(float(left), 1)
                print(f"residue {song} {tag}: voice {left:.1f} dB of the sound "
                      f"in {int(mask.sum())} sung windows ({took:.0f}s)", flush=True)
            results[song] = row
    (out / "residue.json").write_text(json.dumps(results), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("way", choices=["minus", "model", "page", "residue"])
    parser.add_argument("songs", nargs="+")
    parser.add_argument("--out", required=True)
    parser.add_argument("--sep")
    parser.add_argument("--audio")
    parser.add_argument("--models")
    parser.add_argument("--model", default="UVR-MDX-NET-Inst_HQ_5.onnx")
    # model: the output folder name; page: tag=Label pairs of the versions.
    parser.add_argument("--tag", default="model")
    parser.add_argument("--versions", nargs="*", default=[])
    args = parser.parse_args()
    if args.way == "minus":
        run_minus(args)
    elif args.way == "residue":
        run_residue(args)
    elif args.way == "page":
        run_page(args)
    else:
        run_model(args)


if __name__ == "__main__":
    main()
