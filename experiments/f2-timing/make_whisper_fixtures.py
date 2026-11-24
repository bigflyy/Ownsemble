"""Plan 10 I2d: unit-test fixtures for the app's Whisper words, made by gigaam_app's own code.

    python -I make_whisper_fixtures.py OUT_DIR   (app/test/fixtures/whisper)

Writes words.json: token lists and what gigaam_app's whisper_model.words_from_tokens
gives for them (words with times and confidences), and confidence.json:
probabilities and whisper_confidence of each. Tokens are written as
[hex bytes, t0, t1, p]: t0 and t1 in whisper.cpp's 10 ms steps (both sides
multiply by 0.01), p a float32 value as whisper.cpp gives it.

Hand-made cases cover a Cyrillic word split inside its letters, CJK split
inside a character, a character cut off at the end, punctuation-only words,
whitespace that only str.strip() removes (no-break space, U+001C) and one it
keeps (U+FEFF), times that step back or run past the chunk; random cases mix
all of these.

Env: GigaAmTranscriber's dev venv (~/.venvs/gigaam-app).
"""

import json
import random
import sys
from pathlib import Path
from types import SimpleNamespace

import numpy as np

GIGAAM = Path(r"C:\MyProjects\GigaAmTranscriber")
sys.path.insert(0, str(GIGAAM))

from gigaam_app.whisper_cpp import TIME_STEP_SECONDS  # noqa: E402
from gigaam_app.whisper_model import whisper_confidence, words_from_tokens  # noqa: E402


def f32(value):
    return float(np.float32(value))


def token(data, t0, t1, p):
    return [data.hex(), int(t0), int(t1), f32(p)]


def run(tokens, offset, duration):
    objects = [SimpleNamespace(data=bytes.fromhex(h), start=t0 * TIME_STEP_SECONDS,
                               end=t1 * TIME_STEP_SECONDS, probability=p) for h, t0, t1, p in tokens]
    words = words_from_tokens(objects, offset, duration)
    return {"tokens": tokens, "offset": offset, "duration": duration,
            "words": [[w.start, w.end, w.text, w.confidence] for w in words]}


def hand_cases():
    cyr = "привет".encode("utf-8")      # 12 bytes, 2 per letter
    cjk = "你好世界".encode("utf-8")      # 12 bytes, 3 per character
    cases = [
        # Plain words, punctuation sticking to the word before.
        [token(b" Hello", 0, 40, 0.98), token(b",", 40, 42, 0.30), token(b" world", 45, 90, 0.66),
         token(b".", 90, 91, 0.10)],
        # A Cyrillic word cut inside letters: the middle token holds only parts.
        [token(b" " + cyr[:3], 10, 20, 0.9), token(cyr[3:7], 20, 30, 0.4), token(cyr[7:], 30, 50, 0.75)],
        # CJK without spaces, cut inside characters: one word.
        [token(cjk[:2], 0, 10, 0.95), token(cjk[2:4], 10, 20, 0.55), token(cjk[4:9], 20, 30, 0.85),
         token(cjk[9:], 30, 40, 0.99)],
        # A character cut off at the end (the replacement character).
        [token(b" ok", 0, 10, 0.9), token(b" " + cjk[:2], 10, 20, 0.6)],
        [token(b" ab" + cyr[:1], 0, 10, 0.9), token(b"\xff", 10, 20, 0.2), token(b"cd", 20, 30, 0.8)],
        # Punctuation only: no confidence.
        [token(b" ...", 0, 30, 0.5), token(b" !", 40, 50, 0.6), token(b" la", 60, 70, 0.99)],
        # Blank and empty tokens; whitespace only str.strip removes; U+FEFF kept.
        [token(b" ", 0, 5, 0.9), token(b"", 5, 6, 0.1), token(b" one", 6, 20, 0.8),
         token(b" \xc2\xa0", 20, 22, 0.7), token(b" \x1ctwo\x1c", 22, 40, 0.65),
         token(b" \xef\xbb\xbfthree", 40, 60, 0.45), token(b"\t", 60, 61, 0.2),
         token(b" four\xe3\x80\x80", 61, 70, 0.71)],
        # A byte order mark at byte zero (Dart's decoder drops it, Python keeps it).
        [token(b"\xef\xbb\xbfa", 0, 50, 0.9)],
        [token(b"\xef\xbb\xbf", 0, 50, 0.9), token(b" b", 50, 60, 0.8)],
        # Times stepping back and running past the chunk.
        [token(b" a", 50, 80, 0.9), token(b" b", 30, 40, 0.9), token(b" c", 20, 10, 0.9),
         token(b" d", 900, 1200, 0.9), token(b" e", 1100, 1000, 0.9)],
        # Digits are letters; a leading token without space starts the first word.
        [token(b"42", 0, 10, 0.51), token(b" 7", 10, 20, 0.49), token(b"th", 20, 30, 0.7)],
        [],
    ]
    out = []
    for tokens in cases:
        for offset, duration in ((0.0, None), (12.345, 9.5), (3.0, 0.25), (100.0005, 30.0)):
            out.append(run(tokens, offset, duration))
    return out


def random_cases(count, seed):
    rng = random.Random(seed)
    pieces = [b" the", b" love", b"ly", b",", b".", b"!", b" ", b"", b"\t", b" 12", b"3",
              b"\xc2\xa0", b" \xef\xbb\xbf", b" \x1d", b"'s", b" -", b"?"]
    words = ["ночь", "звезда", "Ёлка", "東京", "愛してる", "사랑", "café", "naïve", "Straße"]
    out = []
    for _ in range(count):
        tokens = []
        t = rng.randint(0, 50)
        for _ in range(rng.randint(0, 25)):
            if rng.random() < 0.45:
                data = (b" " if rng.random() < 0.6 else b"") + rng.choice(words).encode("utf-8")
                cut = sorted(rng.sample(range(1, len(data)), min(len(data) - 1, rng.randint(0, 3))))
                parts = [data[a:b] for a, b in zip([0] + cut, cut + [len(data)])]
            else:
                parts = [rng.choice(pieces)]
            for part in parts:
                step = rng.randint(-15, 40)
                t = max(0, t + step)
                t1 = t + rng.randint(-5, 30)
                tokens.append(token(part, t, max(0, t1), rng.random() ** 0.5))
        if tokens and rng.random() < 0.1:
            tokens[-1][0] = (bytes.fromhex(tokens[-1][0]) + "ё".encode()[:1]).hex()
        offset = rng.choice([0.0, round(rng.uniform(0, 300), 4), rng.uniform(0, 300)])
        duration = rng.choice([None, rng.uniform(0.5, 25.0), rng.randint(1, 25) * 1.0])
        out.append(run(tokens, offset, duration))
    return out


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    cases = hand_cases() + random_cases(400, 7)
    (out / "words.json").write_text(json.dumps(cases, ensure_ascii=False), encoding="utf-8")
    probabilities = [-0.25, 0.0, 1e-7, 0.1, 0.25, 0.4999999, 0.5, 0.5000001, 0.6, 0.6999999,
                     0.7, 0.7000001, 0.85, 0.99, 1.0, 1.5]
    rng = random.Random(3)
    probabilities += [f32(rng.random()) for _ in range(300)]
    (out / "confidence.json").write_text(
        json.dumps([[p, whisper_confidence(p)] for p in probabilities]), encoding="utf-8")
    words = sum(len(case["words"]) for case in cases)
    print(f"{len(cases)} token cases, {words} words, {len(probabilities)} probabilities -> {out}")


if __name__ == "__main__":
    main()
