"""Plan 10 I1b2: vocals by other separators, to compare with htdemucs.

For every DATA_DIR/audio/<index>.mp3, runs one audio-separator model and keeps
only the vocals, as 16 kHz mono FLAC in DATA_DIR/vocals-<tag>/<index>.flac
(the same form separate.py writes, so the transcripts compare). The
separator's own 44.1 kHz stereo output is deleted at once. Files already there
are skipped. Prints only indexes and timings.

    PYTHONPATH=<pydeps-sep> python separate_other.py MODEL_FILE TAG DATA_DIR [...]
        --models DIR [--every N]

--every N: only every Nth song of each folder (by index order), for a quicker
comparison on a fixed subset.

MODEL_FILE is audio-separator's name, for example Kim_Vocal_2.onnx,
htdemucs_ft.yaml or vocals_mel_band_roformer.ckpt.
"""

import argparse
import os
import subprocess
import tempfile
import time
from pathlib import Path

import onnxruntime
import torch

# onnxruntime-gpu 1.23 (CUDA 12) finds CUDA and cuDNN in PyTorch's own folder
# (torch 2.12 cu126); without this the MDX models fall back to the CPU.
onnxruntime.preload_dlls(directory=os.path.join(torch.__path__[0], "lib"))

from audio_separator.separator import Separator  # noqa: E402


def to_16k_mono(source, target):
    """Write `source` as 16 kHz mono 16-bit FLAC to `target` with ffmpeg."""
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-i", str(source), "-ac", "1",
         "-ar", "16000", "-sample_fmt", "s16", str(target)],
        check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("model_file")
    parser.add_argument("tag")
    parser.add_argument("data_dirs", nargs="+")
    parser.add_argument("--models", required=True)
    parser.add_argument("--every", type=int, default=1)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as scratch:
        separator = Separator(model_file_dir=args.models, output_dir=scratch,
                              output_format="FLAC", output_single_stem="Vocals",
                              log_level=40)
        clock = time.time()
        separator.load_model(model_filename=args.model_file)
        print(f"{args.tag}: model loaded in {time.time() - clock:.1f}s", flush=True)
        for data_dir in map(Path, args.data_dirs):
            out_dir = data_dir / f"vocals-{args.tag}"
            out_dir.mkdir(exist_ok=True)
            songs = sorted((data_dir / "audio").glob("*.mp3"),
                           key=lambda p: int(p.stem))[::args.every]
            for mp3 in songs:
                target = out_dir / f"{mp3.stem}.flac"
                if target.exists():
                    continue
                clock = time.time()
                outputs = separator.separate(str(mp3))
                vocals = [Path(scratch) / name for name in outputs]
                to_16k_mono(vocals[0], target)
                for path in vocals:
                    path.unlink(missing_ok=True)
                print(f"{data_dir.name} {args.tag} #{mp3.stem} in "
                      f"{time.time() - clock:.1f}s", flush=True)


if __name__ == "__main__":
    main()
