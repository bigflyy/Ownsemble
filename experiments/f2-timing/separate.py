"""Plan 10 F2/G0: the singing alone, for transcription as an independent check.

Runs Demucs (htdemucs, about 80 MB) on every DATA_DIR/audio/<index>.mp3 and
writes the vocals as 16 kHz mono FLAC to DATA_DIR/vocals/<index>.flac (16 bit,
3-4 MB a song). Files already there are skipped.

    PYTHONPATH=<demucs folder> python separate.py DATA_DIR [DATA_DIR ...] [--device cuda]

Needs PyTorch and Demucs (installed apart into .local/v2-tools/pydeps-demucs,
given by PYTHONPATH). Prints only indexes and timings.
"""

import argparse
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import soundfile
import torch
import torchaudio.functional as F
from demucs.apply import apply_model
from demucs.pretrained import get_model


def decode(path, rate):
    """Stereo float32 samples of an MP3 at `rate`, shape (2, n)."""
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path), "-ac", "2", "-ar", str(rate),
         "-f", "f32le", "-"], check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.float32).reshape(-1, 2).T.copy()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("dirs", nargs="+", type=Path)
    parser.add_argument("--device", default="cuda")
    args = parser.parse_args()
    model = get_model("htdemucs").to(args.device).eval()
    vocals_index = model.sources.index("vocals")
    for data in args.dirs:
        out = data / "vocals"
        out.mkdir(exist_ok=True)
        for mp3 in sorted((data / "audio").glob("*.mp3"), key=lambda p: int(p.stem)):
            target = out / f"{mp3.stem}.flac"
            if target.exists():
                continue
            clock = time.time()
            wave = torch.from_numpy(decode(mp3, model.samplerate))
            # Demucs works on a normalised mix and gives the sources back
            # at the same scale.
            mean, std = wave.mean(), wave.std() + 1e-8
            with torch.inference_mode():
                sources = apply_model(model, ((wave - mean) / std)[None],
                                      device=args.device, shifts=0, split=True,
                                      overlap=0.25, progress=False)[0]
            vocals = sources[vocals_index] * std + mean
            mono = F.resample(vocals.mean(0).cpu(), model.samplerate, 16000)
            peak = float(mono.abs().max()) or 1.0
            soundfile.write(str(target), (mono / max(peak, 1.0)).numpy(), 16000,
                            subtype="PCM_16")
            print(f"{data.name} #{mp3.stem} {wave.shape[1] / model.samplerate:.0f}s"
                  f" in {time.time() - clock:.1f}s", flush=True)


if __name__ == "__main__":
    sys.exit(main())
