"""Plan 10 I2d: GigaAmTranscriber's own Whisper (WhisperModel on whisper.cpp) on raw vocals.

The reference for the app's Dart port (app/tool/check_whisper.dart): the same
16 kHz mono float vocals (<name>.vocals16.f32) go through gigaam_app's
SileroVad and ChunkFinder (VadOptions with the research's threshold 0.15) and
then WhisperModel.encode / words chunk by chunk on the CPU, on the whisper.cpp
libraries of the app's whisper-turbo bundle (the same files the app loads).
gigaam_app's Transcriber is not used because it decodes files through ffmpeg;
this feeds it the samples directly, otherwise the same steps.

    python -I whisper_ref.py --hear HEAR_WORDS_BUNDLE --whisper WHISPER_BUNDLE
        --vocals DIR --out DIR --work DIR [--threads 8] [--language CODE]
        [--ort FOLDER] [--tag ref] NAMES...

WhisperModel wants a model folder with model.json: one is made in --work with
a hard link to the bundle's ggml file (no copy). For each NAME:
OUT/NAME.TAG.json (chunks with language, tokens as hex bytes with times and
probabilities, words, confidences, times). Prints no words.

--ort FOLDER puts another onnxruntime first on the path (an unpacked wheel),
so Silero runs on the app's runtime, 1.31.1 (see gigaam_ref.py).

Env: GigaAmTranscriber's dev venv (~/.venvs/gigaam-app).
"""

import argparse
import json
import os
import sys
import time
from pathlib import Path

if "--ort" in sys.argv:
    sys.path.insert(0, sys.argv[sys.argv.index("--ort") + 1])

import numpy as np  # noqa: E402
import onnxruntime  # noqa: E402

GIGAAM = Path(r"C:\MyProjects\GigaAmTranscriber")
sys.path.insert(0, str(GIGAAM))

from gigaam_app import whisper_cpp  # noqa: E402
from gigaam_app.asr import create_session  # noqa: E402
from gigaam_app.vad import ChunkFinder, SileroVad, VadOptions  # noqa: E402
from gigaam_app.whisper_model import WhisperModel  # noqa: E402

MODEL_FILE = "ggml-large-v3-turbo-q5_0.bin"


def model_folder(bundle, work):
    """A WhisperModel folder in WORK: model.json and a hard link to the ggml file."""
    folder = work / "whisper-model"
    folder.mkdir(parents=True, exist_ok=True)
    source = bundle / MODEL_FILE
    target = folder / MODEL_FILE
    if not target.exists():
        os.link(source, target)
    meta = {"format": 1, "name": "whisper-large-v3-turbo-q5_0", "type": "whisper", "sample_rate": 16000,
            "files": {"model": {"name": MODEL_FILE, "size": source.stat().st_size}}}
    (folder / "model.json").write_text(json.dumps(meta), encoding="utf-8")
    return folder


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--hear", required=True, type=Path, help="the hear-words bundle (silero_vad_scan.onnx)")
    parser.add_argument("--whisper", required=True, type=Path, help="the whisper-turbo bundle")
    parser.add_argument("--vocals", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--work", required=True, type=Path)
    parser.add_argument("--threads", type=int, default=8)
    parser.add_argument("--language", default=None)
    parser.add_argument("--ort", default=None, help="folder holding another onnxruntime package")
    parser.add_argument("--tag", default="ref")
    parser.add_argument("names", nargs="+")
    args = parser.parse_args()
    # os.add_dll_directory (in whisper_cpp.Library) takes only an absolute path.
    args.hear, args.whisper = args.hear.resolve(), args.whisper.resolve()
    args.out.mkdir(parents=True, exist_ok=True)

    started = time.perf_counter()
    library = whisper_cpp.Library(args.whisper / "whisper.cpp")
    model = WhisperModel(model_folder(args.whisper, args.work), device="cpu", cpu_threads=args.threads,
                         language=args.language, library=library)
    vad_session, _ = create_session(args.hear / "silero_vad_scan.onnx", device="cpu", cpu_threads=1)
    vad = SileroVad(vad_session)
    print(f"whisper.cpp {library.version} {library.backends()}, onnxruntime {onnxruntime.__version__}, "
          f"{args.threads} threads, language {args.language or 'auto'}: loaded in "
          f"{time.perf_counter() - started:.1f} s on {model.device_label}", flush=True)

    options = VadOptions(vad_threshold=0.15)
    for name in args.names:
        audio = np.fromfile(args.vocals / f"{name}.vocals16.f32", dtype="<f4")
        clock = time.perf_counter()
        finder = ChunkFinder(len(audio), options)
        ranges = []
        for first, block in vad.blocks(audio):
            for index, probability in enumerate(block.tolist(), first):
                ranges += finder.feed(index, probability)
        ranges += finder.finish()
        vad_s = time.perf_counter() - clock
        chunks, transcribe_s = [], 0.0
        for start, end in ranges:
            clock = time.perf_counter()
            [encoded] = model.encode([audio[start:end]])
            transcribe_s += time.perf_counter() - clock
            language, tokens, _ = encoded
            words = model.words(encoded, start / 16000)
            chunks.append({
                "start": int(start), "end": int(end), "language": language,
                "tokens": [[t.data.hex(), t.start, t.end, t.probability] for t in tokens],
                "words": [[w.start, w.end, w.text, w.confidence] for w in words],
            })
        confidences = [w[3] for chunk in chunks for w in chunk["words"] if w[3] is not None]
        mean = float(np.mean(confidences)) if confidences else 0.0
        result = {
            "name": name, "samples": int(len(audio)), "speech_seconds": finder.speech_seconds,
            "chunks": chunks, "mean_confidence": mean, "threads": args.threads,
            "language": args.language or "auto", "onnxruntime": onnxruntime.__version__,
            "vad_s": round(vad_s, 3), "transcribe_s": round(transcribe_s, 3),
        }
        (args.out / f"{name}.{args.tag}.json").write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")
        words = sum(len(chunk["words"]) for chunk in chunks)
        languages = sorted({chunk["language"] for chunk in chunks})
        print(f"{name}: {len(audio) / 16000:.0f} s, {len(chunks)} chunks ({', '.join(languages)}), {words} words, "
              f"mean confidence {mean:.3f}; vad {vad_s:.1f} s, whisper {transcribe_s:.1f} s", flush=True)
    model.close()


if __name__ == "__main__":
    main()
