"""Plan 11 A5: can Unwa's MelBand RoFormer (InstVoc Duality V2) run in the
app's engine (ONNX Runtime with DirectML)?

The network between the STFT and the inverse STFT is exported, the way the
app runs Kim Vocal 2 (mdx_separator.dart): the app makes the spectrum and
turns the result back into sound; the ONNX graph takes one chunk's stereo
spectrum and gives the instrumental's spectrum. Only the Instrumental mask
estimator is kept (the app needs no vocals from it), which also drops half
of the mask weights from the file.

    export: build the PyTorch model from the checkpoint and YAML, export the
            middle part for a fixed chunk (485100 samples = 1101 frames),
            run both on a real chunk of AUDIO and print how far apart the
            outputs are (dB of the difference against the output).
            PYTHONPATH=<pydeps-sep>;<pydeps-onnx> python melband_onnx.py
                export --ckpt C --yaml Y --onnx OUT.onnx --audio SONG.flac
    time:   run OUT.onnx with ONNX Runtime DirectML on that chunk N times;
            print load time, time per chunk and the reference difference.
            PYTHONPATH=<pydeps-dml> python melband_onnx.py time --onnx OUT.onnx
                --audio SONG.flac
"""

import argparse
import subprocess
import time
from pathlib import Path

import numpy as np

SAMPLE_RATE = 44100
CHUNK = 485100
N_FFT = 2048
HOP = 441
INSTRUMENTAL = 1  # training.instruments: [Vocals, Instrumental]


def start_memory_watchdog(limit_gb):
    """Ends this process at once if its committed memory passes [limit_gb]:
    the first export run took the PC to 64 GB and crashed (session 65)."""
    import os
    import threading

    import psutil

    me = psutil.Process()

    def watch():
        while True:
            used = me.memory_info().private / 1e9
            if used > limit_gb:
                print(f"WATCHDOG: {used:.1f} GB committed, over {limit_gb} GB; stopping",
                      flush=True)
                os._exit(3)
            time.sleep(0.25)

    threading.Thread(target=watch, daemon=True).start()


def read_chunk(path, chunk=CHUNK, start_seconds=60.0):
    """One chunk of stereo float audio from the middle of a song, [2, chunk]."""
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-ss", str(start_seconds), "-i", str(path),
         "-f", "f32le", "-ar", str(SAMPLE_RATE), "-ac", "2", "-t",
         str(chunk / SAMPLE_RATE + 1), "pipe:1"],
        capture_output=True, check=True).stdout
    audio = np.frombuffer(raw, dtype="<f4")[: chunk * 2]
    return audio.reshape(-1, 2).T.copy()


def stft_numpy(audio):
    """torch.stft(center=True, reflect pad, periodic Hann, not normalized) in
    numpy, as [2, 1025, frames, 2] (real, imaginary): what the app will do."""
    window = 0.5 - 0.5 * np.cos(2 * np.pi * np.arange(N_FFT) / N_FFT)
    padded = np.pad(audio, ((0, 0), (N_FFT // 2, N_FFT // 2)), mode="reflect")
    frames = 1 + (padded.shape[1] - N_FFT) // HOP
    index = np.arange(N_FFT)[None, :] + HOP * np.arange(frames)[:, None]
    spectrum = np.fft.rfft(padded[:, index] * window, axis=-1)  # [2, t, f]
    spectrum = spectrum.transpose(0, 2, 1)
    return np.stack([spectrum.real, spectrum.imag], -1).astype(np.float32)


def diff_db(a, b):
    """How far b is from a: 10 log10(energy of the difference / energy of a)."""
    return 10 * np.log10(np.sum((a - b) ** 2) / max(np.sum(a ** 2), 1e-20))


def run_export(args):
    import torch
    import yaml
    from einops import rearrange, pack, unpack
    from torch import nn

    from audio_separator.separator.uvr_lib_v5.roformer.mel_band_roformer import \
        MelBandRoformer

    config = yaml.load(open(args.yaml, encoding="utf-8"), Loader=yaml.FullLoader)
    model_args = dict(config["model"])
    model_args["flash_attn"] = False
    model = MelBandRoformer(**model_args)
    state = torch.load(args.ckpt, map_location="cpu", weights_only=False)
    model.load_state_dict(state.get("state_dict", state) if isinstance(state, dict) else state)
    del state
    model.eval()
    # No autograd bookkeeping anywhere: the first export kept every layer's
    # activations (about 2.3 GB per attention at this chunk) and ran out.
    model.requires_grad_(False)
    torch.set_grad_enabled(False)

    class Middle(nn.Module):
        """Stereo spectrum [2, 1025, T, 2] -> instrumental spectrum, same shape."""

        def __init__(self, m):
            super().__init__()
            self.m = m
            freqs, channels = 1025, 2
            rows = freqs * channels
            indices = m.freq_indices.long()
            # Averaging the overlapping band masks back onto each frequency
            # row is a fixed linear map: one matrix multiply in the graph.
            average = torch.zeros(rows, len(indices))
            average[indices, torch.arange(len(indices))] = 1.0
            denom = m.num_bands_per_freq.repeat_interleave(channels).float()
            average = average / denom.clamp(min=1e-8)[:, None]
            self.register_buffer("average", average)
            self.register_buffer("indices", indices)

        def forward(self, spec):
            m = self.m
            stft_repr = rearrange(spec, "s f t c -> 1 (f s) t c")
            x = stft_repr[:, self.indices]
            x = rearrange(x, "b f t c -> b t (f c)")
            x = m.band_split(x)
            for time_transformer, freq_transformer in m.layers:
                x = rearrange(x, "b t f d -> b f t d")
                x, ps = pack([x], "* t d")
                x = time_transformer(x)
                (x,) = unpack(x, ps, "* t d")
                x = rearrange(x, "b f t d -> b t f d")
                x, ps = pack([x], "* f d")
                x = freq_transformer(x)
                (x,) = unpack(x, ps, "* f d")
            mask = m.mask_estimators[INSTRUMENTAL](x)
            mask = rearrange(mask, "b t (f c) -> b f t c", c=2)
            # A plain MatMul, not an einsum: DirectML refused the graph with
            # einsum "rj,bjtc->brtc" in it (session 65).
            bands, frames = mask.shape[1], mask.shape[2]
            mask = torch.matmul(self.average, mask.reshape(bands, frames * 2))
            mask = mask.reshape(1, -1, frames, 2)
            a, b = stft_repr[..., 0], stft_repr[..., 1]
            c, d = mask[..., 0], mask[..., 1]
            out = torch.stack([a * c - b * d, a * d + b * c], -1)
            return rearrange(out, "1 (f s) t c -> s f t c", s=2)

    middle = Middle(model).eval()
    audio = read_chunk(args.audio, args.chunk)
    spec = torch.from_numpy(stft_numpy(audio))
    print(f"spectrum {tuple(spec.shape)}", flush=True)

    with torch.no_grad():
        clock = time.time()
        mine = middle(spec).numpy()
        print(f"middle in PyTorch (CPU): {time.time() - clock:.1f}s", flush=True)
        if not args.skip_full:
            # The full model's own instrumental, for the reference (passed
            # at -118.8 dB in session 65; skipped since, to save memory).
            full = model(torch.from_numpy(audio)[None])[0, INSTRUMENTAL].numpy()
            ri = torch.from_numpy(mine)
            sound = torch.istft(torch.complex(ri[..., 0], ri[..., 1]), n_fft=N_FFT,
                                hop_length=HOP, win_length=N_FFT,
                                window=torch.hann_window(N_FFT)).numpy()
            n = min(sound.shape[-1], full.shape[-1])
            print(f"middle vs full model: {diff_db(full[:, :n], sound[:, :n]):.1f} dB",
                  flush=True)
            del full
        if args.long_ref and args.chunk < CHUNK:
            # What the shorter chunk costs: its output against the 11 s
            # chunk's over the same frames, leaving out 40 frames (0.4 s) at
            # each edge, where a chunk is always weaker (the app overlaps
            # chunks and fades the edges).
            long_ref = np.load(args.long_ref)
            frames = mine.shape[2]
            inner = slice(40, frames - 40)
            print(f"{args.chunk / SAMPLE_RATE:.1f} s chunk vs 11 s chunk (inner frames): "
                  f"{diff_db(long_ref[:, :, inner], mine[:, :, inner]):.1f} dB", flush=True)

    clock = time.time()
    torch.onnx.export(middle, (spec,), args.onnx, input_names=["spec"],
                      output_names=["inst"], opset_version=17, dynamo=False,
                      do_constant_folding=False)
    print(f"exported in {time.time() - clock:.0f}s: "
          f"{Path(args.onnx).stat().st_size / 1e6:.0f} MB", flush=True)
    np.save(Path(args.onnx).with_suffix(".ref.npy"), mine)
    # No ONNX run on the CPU here: it passed 14 GB (session 65); the
    # DirectML run in the time step compares with this reference instead.


def run_time(args):
    import onnxruntime

    audio = read_chunk(args.audio, args.chunk)
    spec = stft_numpy(audio)
    reference = np.load(Path(args.onnx).with_suffix(".ref.npy"))
    options = onnxruntime.SessionOptions()
    options.enable_mem_pattern = False  # DirectML needs these two off
    options.execution_mode = onnxruntime.ExecutionMode.ORT_SEQUENTIAL
    if args.verbose:
        options.log_severity_level = 0
        options.log_verbosity_level = 1
    clock = time.time()
    # The discrete GPU, as the app picks it (DML2 HighPerformance, GPU only):
    # adapter 0 on a laptop can be the integrated one.
    dml = {"performance_preference": "high_performance", "device_filter": "gpu"}
    session = onnxruntime.InferenceSession(
        args.onnx, options, providers=[("DmlExecutionProvider", dml), "CPUExecutionProvider"])
    print(f"DirectML session in {time.time() - clock:.1f}s, providers "
          f"{session.get_providers()}", flush=True)
    times = []
    for i in range(args.runs):
        clock = time.time()
        out = session.run(None, {"spec": spec})[0]
        times.append(time.time() - clock)
        if i == 0:
            print(f"first run {times[0]:.2f}s, vs PyTorch {diff_db(reference, out):.1f} dB",
                  flush=True)
    steady = np.median(times[1:]) if len(times) > 1 else times[0]
    # A song of S seconds at overlap 2 needs about 2 * S / 11 chunks.
    print(f"per chunk {steady:.2f}s; a 3.5 min song at overlap 2: "
          f"{steady * 2 * 210 / (args.chunk / SAMPLE_RATE):.0f}s", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("step", choices=["export", "time"])
    parser.add_argument("--ckpt")
    parser.add_argument("--yaml")
    parser.add_argument("--onnx", required=True)
    parser.add_argument("--audio", required=True)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--device", type=int, default=0)
    parser.add_argument("--limit-gb", type=float, default=20)
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--skip-full", action="store_true")
    # Samples per chunk (the model was trained on 485100 = 11 s), and the
    # 11 s reference to measure a shorter chunk against.
    parser.add_argument("--chunk", type=int, default=CHUNK)
    parser.add_argument("--long-ref")
    args = parser.parse_args()
    start_memory_watchdog(args.limit_gb)
    run_export(args) if args.step == "export" else run_time(args)


if __name__ == "__main__":
    main()
