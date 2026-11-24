"""Plan 10 I1b/I1e: any GigaAM or whisper.cpp model folder on the files, as gigaam-cli does.

gigaam-cli knows only its catalog's models (Whisper is large-v3-turbo). This
runs GigaAmTranscriber's own Transcriber with a model root (a folder holding
silero_vad_scan.onnx and the model folders), so a smaller Whisper (ggml base or
small) or an int8 GigaAM goes through the same Silero VAD chunks and writes the
same <name>-transcript.json that stt_accuracy.py reads. Per file it also logs
the audio length, the time taken and the process's peak memory (cost, I1e).

    python -I stt_small.py --root MODEL_ROOT --model FOLDER -o OUT_DIR
        [--device cpu|gpu|auto] [--threads N] [--language auto] [--vad-threshold 0.15]
        [--times TIMES.jsonl] FILES...

Env: GigaAmTranscriber's dev venv (~/.venvs/gigaam-app). Prints no words.
"""

import argparse
import ctypes
import ctypes.wintypes
import dataclasses
import json
import sys
import time
from pathlib import Path

GIGAAM = Path(r"C:\MyProjects\GigaAmTranscriber")
sys.path.insert(0, str(GIGAAM))

from gigaam_app import config  # noqa: E402
from gigaam_app.engine import Transcriber  # noqa: E402
from gigaam_app.outputs import write_outputs  # noqa: E402


class _Counters(ctypes.Structure):
    """PROCESS_MEMORY_COUNTERS from psapi (no psutil in the dev venv)."""

    _fields_ = [("cb", ctypes.wintypes.DWORD), ("PageFaultCount", ctypes.wintypes.DWORD),
                ("PeakWorkingSetSize", ctypes.c_size_t), ("WorkingSetSize", ctypes.c_size_t),
                ("QuotaPeakPagedPoolUsage", ctypes.c_size_t), ("QuotaPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                ("PagefileUsage", ctypes.c_size_t), ("PeakPagefileUsage", ctypes.c_size_t)]


def memory_mb():
    """(current, peak) working set of this process in MB."""
    counters = _Counters()
    counters.cb = ctypes.sizeof(counters)
    kernel32 = ctypes.WinDLL("kernel32")
    kernel32.GetCurrentProcess.restype = ctypes.wintypes.HANDLE
    info = kernel32.K32GetProcessMemoryInfo
    info.argtypes = [ctypes.wintypes.HANDLE, ctypes.POINTER(_Counters), ctypes.wintypes.DWORD]
    info.restype = ctypes.wintypes.BOOL
    info(kernel32.GetCurrentProcess(), ctypes.byref(counters), counters.cb)
    return counters.WorkingSetSize / 2**20, counters.PeakWorkingSetSize / 2**20


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--model", required=True)
    parser.add_argument("-o", "--out", required=True, type=Path)
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--threads", type=int, default=None)
    parser.add_argument("--language", default="auto")
    parser.add_argument("--vad-threshold", type=float, default=0.15)
    parser.add_argument("--times", type=Path, default=None)
    parser.add_argument("files", nargs="+", type=Path)
    args = parser.parse_args()

    settings = config.load(None)
    options = settings.vad
    options.vad_threshold = args.vad_threshold
    transcriber = Transcriber(args.model, device=args.device, cpu_threads=args.threads,
                              model_root=args.root, language=args.language)
    _, peak = memory_mb()
    print(f"{args.model} on {transcriber.device_label}, loaded in "
          f"{transcriber.load_seconds:.1f} s, peak {peak:.0f} MB", flush=True)
    args.out.mkdir(parents=True, exist_ok=True)
    times = open(args.times, "a", encoding="utf-8") if args.times else None
    total_audio = total_time = 0.0
    for path in args.files:
        started = time.perf_counter()
        result = transcriber.transcribe(path, options)
        elapsed = time.perf_counter() - started
        words = sum(len(segment.words) for segment in result.segments)
        if result.segments:
            write_outputs(result, ["json"], args.out)
        else:
            # An explicit empty result, so a rerun never leaves an older transcript in place.
            empty = {"source": str(path), "model": args.model, "audio_seconds": result.audio_seconds,
                     "speech_seconds": 0.0, "segments": [], "text": ""}
            (args.out / f"{path.stem}-transcript.json").write_text(json.dumps(empty), encoding="utf-8")
        current, peak = memory_mb()
        total_audio += result.audio_seconds
        total_time += elapsed
        row = {"file": path.stem, "model": args.model, "device": transcriber.device_label,
               "vad": dataclasses.asdict(options),
               "threads": args.threads, "audio_s": round(result.audio_seconds, 1),
               "elapsed_s": round(elapsed, 2), "words": words,
               "ram_mb": round(current), "peak_mb": round(peak)}
        if times:
            times.write(json.dumps(row) + "\n")
            times.flush()
        print(f"{path.stem}: {result.audio_seconds:.0f} s audio in {elapsed:.1f} s, "
              f"{words} words, peak {peak:.0f} MB", flush=True)
    if total_time:
        print(f"total {total_audio:.0f} s audio in {total_time:.0f} s "
              f"({total_audio / total_time:.1f}x realtime)")


if __name__ == "__main__":
    main()
