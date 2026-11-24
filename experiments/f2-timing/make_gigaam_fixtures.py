"""Plan 10 I2c: unit-test fixtures for the app's GigaAM port, made by gigaam_app's own code.

    python -I make_gigaam_fixtures.py OUT_DIR   (app/test/fixtures/gigaam)

Writes:
- typed.onnx: a tiny model with a float input x [1, N] and an int64 input n [1],
  outputs y = 2 x (float), m = n + 1 (int64) and k = m as int32 (GigaAM's
  encoder gives its length as int32): the typed binding's test.
- rnnt_small.json: a small random RNNT head as numpy.savez writes it (base64),
  a vocabulary, encoder frames, and what gigaam_app's RnntHead.decode,
  letter_groups and AsrModel.words give for them.
- chunks.json: Silero-like probability runs and what gigaam_app's ChunkFinder
  gives (chunks, regions, speech seconds) at thresholds 0.15 and 0.5.
- rounding.json: values and Python's round(x, 1) / round(x, 3).

Env: a venv with numpy, onnx and onnxruntime (~/.venvs/diar-exp).
"""

import base64
import io
import json
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import onnx
from onnx import TensorProto, helper

GIGAAM = Path(r"C:\MyProjects\GigaAmTranscriber")
sys.path.insert(0, str(GIGAAM))

from gigaam_app.asr import AsrModel, RnntHead, letter_groups  # noqa: E402
from gigaam_app.vad import ChunkFinder, VadOptions  # noqa: E402


def typed_model(path):
    two = helper.make_tensor("two", TensorProto.FLOAT, [], [2.0])
    one = helper.make_tensor("one", TensorProto.INT64, [], [1])
    graph = helper.make_graph(
        [helper.make_node("Mul", ["x", "two"], ["y"]), helper.make_node("Add", ["n", "one"], ["m"]),
         helper.make_node("Cast", ["m"], ["k"], to=TensorProto.INT32)],
        "typed",
        [helper.make_tensor_value_info("x", TensorProto.FLOAT, [1, "samples"]),
         helper.make_tensor_value_info("n", TensorProto.INT64, [1])],
        [helper.make_tensor_value_info("y", TensorProto.FLOAT, [1, "samples"]),
         helper.make_tensor_value_info("m", TensorProto.INT64, [1]),
         helper.make_tensor_value_info("k", TensorProto.INT32, [1])],
        [two, one])
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 17)])
    model.ir_version = 8
    onnx.checker.check_model(model)
    onnx.save(model, str(path))


def rnnt_case(seed, pred_scale, enc_scale, blank_bias):
    """One small random head and what gigaam_app decodes with it. Random weights
    either repeat a token to the 10-symbol limit (many words) or, with a strong
    prediction network, emit one to three tokens a frame: two cases cover both."""
    rng = np.random.default_rng(seed)
    hidden, joint, enc_dim = 8, 12, 16
    vocab = ["▁Вы", "▁вы,", "ла", ",",
             "▁", "▁ёж", "ё", "▁Еж."]
    outputs = len(vocab) + 1
    blank = len(vocab)
    weights = {
        "embed": rng.normal(0, 1, (outputs, hidden)),
        "w_ih": rng.normal(0, 0.6, (4 * hidden, hidden)),
        "w_hh": rng.normal(0, 0.6, (4 * hidden, hidden)),
        "bias": rng.normal(0, 0.3, 4 * hidden),
        "enc_w": rng.normal(0, enc_scale, (joint, enc_dim)),
        "enc_b": rng.normal(0, 0.2, joint),
        "pred_w": rng.normal(0, pred_scale, (joint, hidden)),
        "pred_b": rng.normal(0, 0.2, joint),
        "out_w": rng.normal(0, 0.8, (outputs, joint)),
        "out_b": rng.normal(0, 0.2, outputs),
    }
    weights = {k: v.astype(np.float32) for k, v in weights.items()}
    weights["out_b"][blank] += blank_bias  # mostly blank, as a real model
    buffer = io.BytesIO()
    np.savez(buffer, **weights)
    npz = buffer.getvalue()
    frames = 40
    encoded = rng.normal(0, 1.5, (frames, enc_dim)).astype(np.float32)
    with tempfile.TemporaryDirectory() as folder:
        file = Path(folder) / "head.npz"
        file.write_bytes(npz)
        head = RnntHead(file, blank)
    groups = letter_groups(vocab, blank)
    tokens = head.decode(encoded, groups)
    words_of = SimpleNamespace(vocab=vocab, frame_seconds=0.04)
    offset = 1000 / 16000  # 0.0625: an exact tie for round(x, 3)
    words = AsrModel.words(words_of, tokens, offset)
    plain = head.decode(encoded)
    print(f"rnnt case {seed}: {len(tokens)} tokens, {len(words)} words")
    return {
        "npz_base64": base64.b64encode(npz).decode("ascii"),
        "shapes": {k: list(v.shape) for k, v in weights.items()},
        "blank_id": blank, "vocab": vocab,
        "frames": frames, "encoder_dim": enc_dim,
        "encoded": [float(x) for x in encoded.reshape(-1)],
        "groups": [None if g is None else g.tolist() for g in groups],
        "tokens": [[int(t), int(f), None if c is None else float(c)] for t, f, c in tokens],
        "plain_tokens": [[int(t), int(f)] for t, f in plain],
        "offset": offset,
        "words": [[w.start, w.end, w.text, w.confidence] for w in words],
    }


def rnnt_small(path):
    cases = [rnnt_case(7, 0.5, 0.5, 1.2), rnnt_case(7, 2.5, 0.4, 6.0)]
    path.write_text(json.dumps(cases, ensure_ascii=False), encoding="utf-8")


def probability_runs():
    """(name, n_samples, probabilities): speech-like runs with pauses, a long run
    that forces a cut, silence, and noise."""
    rng = np.random.default_rng(11)
    runs = []
    # Speech with pauses of different lengths, about 120 s.
    p = []
    while len(p) < 3750:
        speech = int(rng.integers(20, 400))
        pause = int(rng.choice([3, 10, 40, 70, 200]))
        p += list(np.clip(rng.normal(0.6, 0.25, speech), 0, 1)) + list(np.clip(rng.normal(0.02, 0.02, pause), 0, 1))
    runs.append(("pauses", len(p) * 512 - 137, p))
    # One long run of 60 s with only short dips: forced cuts.
    p = list(np.clip(rng.normal(0.7, 0.2, 1875), 0, 1))
    for at in rng.integers(100, 1800, 12):
        p[at:at + int(rng.integers(2, 8))] = [0.005] * 5
    runs.append(("long", len(p) * 512, p))
    # Silence and near silence.
    runs.append(("silence", 900 * 512 - 5, list(np.clip(rng.normal(0.003, 0.002, 900), 0, 1))))
    # Noise around the low threshold.
    runs.append(("noise", 2500 * 512, list(np.clip(rng.normal(0.15, 0.1, 2500), 0, 1))))
    # Speech to the very end.
    p = list(np.clip(rng.normal(0.02, 0.01, 300), 0, 1)) + list(np.clip(rng.normal(0.8, 0.1, 500), 0, 1))
    runs.append(("to_end", len(p) * 512 - 300, p))
    return runs


def chunks():
    cases = []
    for name, n_samples, probabilities in probability_runs():
        probabilities = [round(float(x), 4) for x in probabilities]
        for threshold in (0.15, 0.5):
            finder = ChunkFinder(n_samples, VadOptions(vad_threshold=threshold))
            found = []
            for index, probability in enumerate(probabilities):
                found += finder.feed(index, probability)
            found += finder.finish()
            cases.append({"name": name, "threshold": threshold, "samples": n_samples,
                          "probabilities": probabilities,
                          "chunks": [[int(a), int(b)] for a, b in found],
                          "regions": [[int(a), int(b)] for a, b in finder.regions],
                          "speech_seconds": finder.speech_seconds})
            print(f"chunks {name} {threshold}: {len(found)} chunks")
    return cases


def rounding():
    rng = np.random.default_rng(3)
    values = [0.25, 0.75, 1.25, 0.05, 0.35, 0.0625, 0.1875, 2.675, 0.15, 0.45, 12.25, 0.0]
    values += [int(s) / 16000 for s in rng.integers(0, 16000 * 300, 300)]
    values += [int(s) / 16000 + 0.04 * int(f) for s, f in zip(rng.integers(0, 16000 * 30, 300), rng.integers(0, 600, 300))]
    values += [k / 16 for k in range(0, 200)]
    return [[v, round(v, 1), round(v, 3)] for v in values]


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    typed_model(out / "typed.onnx")
    rnnt_small(out / "rnnt_small.json")
    (out / "chunks.json").write_text(json.dumps(chunks()), encoding="utf-8")
    (out / "rounding.json").write_text(json.dumps(rounding()), encoding="utf-8")


if __name__ == "__main__":
    main()
