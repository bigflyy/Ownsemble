"""Plan 10 I2c: GigaAmTranscriber's own GigaAM RNNT and Silero VAD on raw vocals.

The reference for the app's Dart port (app/tool/check_gigaam.dart): the same
16 kHz mono float vocals (<name>.vocals16.f32, as the app's VocalsJob writes
them) go through gigaam_app's SileroVad, ChunkFinder (VadOptions with the
research's threshold 0.15), AsrModel.encode, decode and words, on the CPU.
gigaam_app's Transcriber is not used because it decodes files through
ffmpeg; this feeds it the samples directly, otherwise the same steps.

    python -I gigaam_ref.py --models HEAR_WORDS_BUNDLE --vocals DIR --out DIR
        [--threads 8] [--ort FOLDER] [--tag ref] NAMES...

For each NAME: OUT/NAME.TAG.json (chunks, tokens, words, confidences, times),
OUT/NAME.TAG.vad.f32 (Silero's probability per window) and
OUT/NAME.TAG.enc0.f32 (the encoder's frames for the first chunk).
OUT/groups.TAG.json holds the letter groups. Prints no words.

--ort FOLDER puts another onnxruntime first on the path (an unpacked wheel):
the int8 encoder's output depends on the runtime version and thread count
(session 52: 1.23.0 against 1.31.1, or 8 threads against 1, about 27 dB
apart), so an exact comparison with the app needs its runtime, 1.31.1.

Env: GigaAmTranscriber's dev venv (~/.venvs/gigaam-app).
"""

import argparse
import json
import sys
import time
from pathlib import Path

if "--ort" in sys.argv:
    sys.path.insert(0, sys.argv[sys.argv.index("--ort") + 1])

import numpy as np  # noqa: E402
import onnxruntime  # noqa: E402

GIGAAM = Path(r"C:\MyProjects\GigaAmTranscriber")
sys.path.insert(0, str(GIGAAM))

from gigaam_app.asr import AsrModel, create_session  # noqa: E402
from gigaam_app.vad import ChunkFinder, SileroVad, VadOptions  # noqa: E402


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--models", required=True, type=Path,
                        help="the hear-words bundle folder (gigaam/, silero_vad_scan.onnx)")
    parser.add_argument("--vocals", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--threads", type=int, default=8)
    parser.add_argument("--ort", default=None, help="folder holding another onnxruntime package")
    parser.add_argument("--tag", default="ref")
    parser.add_argument("names", nargs="+")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    started = time.perf_counter()
    model = AsrModel(args.models / "gigaam", device="cpu", cpu_threads=args.threads)
    vad_session, _ = create_session(args.models / "silero_vad_scan.onnx", device="cpu", cpu_threads=1)
    vad = SileroVad(vad_session)
    print(f"onnxruntime {onnxruntime.__version__}, {args.threads} threads: loaded in "
          f"{time.perf_counter() - started:.1f} s on {model.device_label}", flush=True)
    groups = [None if group is None else group.tolist() for group in model.groups]
    (args.out / f"groups.{args.tag}.json").write_text(json.dumps(groups), encoding="utf-8")

    options = VadOptions(vad_threshold=0.15)
    for name in args.names:
        audio = np.fromfile(args.vocals / f"{name}.vocals16.f32", dtype="<f4")
        clock = time.perf_counter()
        finder = ChunkFinder(len(audio), options)
        probabilities, ranges = [], []
        for first, block in vad.blocks(audio):
            probabilities.append(block.astype(np.float32))
            for index, probability in enumerate(block.tolist(), first):
                ranges += finder.feed(index, probability)
        ranges += finder.finish()
        vad_s = time.perf_counter() - clock
        np.concatenate(probabilities).astype("<f4").tofile(args.out / f"{name}.{args.tag}.vad.f32")

        chunks, encode_s, decode_s = [], 0.0, 0.0
        for number, (start, end) in enumerate(ranges):
            clock = time.perf_counter()
            [encoded] = model.encode([audio[start:end]])
            encode_s += time.perf_counter() - clock
            if number == 0:
                encoded.astype("<f4").tofile(args.out / f"{name}.{args.tag}.enc0.f32")
            clock = time.perf_counter()
            tokens = model.decode(encoded)
            words = model.words(tokens, start / 16000)
            decode_s += time.perf_counter() - clock
            chunks.append({
                "start": int(start), "end": int(end), "frames": int(encoded.shape[0]),
                "tokens": [[int(t), int(f), None if c is None else float(c)] for t, f, c in tokens],
                "words": [[w.start, w.end, w.text, w.confidence] for w in words],
            })
        confidences = [w[3] for chunk in chunks for w in chunk["words"] if w[3] is not None]
        mean = float(np.mean(confidences)) if confidences else 0.0
        result = {
            "name": name, "samples": int(len(audio)), "speech_seconds": finder.speech_seconds,
            "regions": [[int(a), int(b)] for a, b in finder.regions],
            "chunks": chunks, "mean_confidence": mean,
            "onnxruntime": onnxruntime.__version__, "threads": args.threads,
            "vad_s": round(vad_s, 3), "encode_s": round(encode_s, 3), "decode_s": round(decode_s, 3),
        }
        (args.out / f"{name}.{args.tag}.json").write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")
        words = sum(len(chunk["words"]) for chunk in chunks)
        print(f"{name}: {len(audio) / 16000:.0f} s, {len(chunks)} chunks, {words} words, "
              f"mean confidence {mean:.3f}; vad {vad_s:.1f} s, encode {encode_s:.1f} s, "
              f"decode {decode_s:.1f} s", flush=True)


if __name__ == "__main__":
    main()
