"""Plan 10 I2c: compare the app's Dart GigaAM (check_gigaam.dart) with gigaam_app (gigaam_ref.py).

    python -I check_gigaam.py OUT_DIR [--a ref] [--b dart] NAMES...

Reads OUT/NAME.{A,B}.json, .vad.f32 and .enc0.f32 (A and B are the tags
gigaam_ref.py and check_gigaam.dart wrote; any two) and prints, per name,
numbers only (no words): Silero probabilities (largest difference, windows
on the other side of the 0.15 / 0.01 thresholds), chunks (same sample
ranges), the first chunk's encoder frames (largest difference, signal to
difference in dB), tokens (same ids and frames, the first difference),
words (same text, times, confidence), the mean confidence and the 0.80
route. Exit 1 when chunks, tokens, words or the route differ.
"""

import json
import sys
from pathlib import Path

import numpy as np

THRESHOLD, NEG_THRESHOLD, ROUTE = 0.15, 0.01, 0.80


def load(out, name, side):
    data = json.loads((out / f"{name}.{side}.json").read_text(encoding="utf-8"))
    vad = np.fromfile(out / f"{name}.{side}.vad.f32", dtype="<f4")
    enc_path = out / f"{name}.{side}.enc0.f32"
    enc = np.fromfile(enc_path, dtype="<f4") if enc_path.exists() else np.zeros(0, np.float32)
    return data, vad, enc


def times(side):
    """Stage times of either tool's json."""
    if "vad_ms" in side:
        return (f"vad {side['vad_ms'] / 1000:.2f} s, encode {side['encode_ms'] / 1000:.2f} s, decode "
                f"{side['decode_ms'] / 1000:.2f} s, peak {side['peak_ws_mb']} MB "
                f"(private {side['peak_private_mb']})")
    return f"vad {side['vad_s']:.2f} s, encode {side['encode_s']:.2f} s, decode {side['decode_s']:.2f} s"


def main():
    out = Path(sys.argv[1])
    rest = sys.argv[2:]
    a_tag, b_tag = "ref", "dart"
    if "--a" in rest:
        at = rest.index("--a")
        a_tag = rest[at + 1]
        del rest[at:at + 2]
    if "--b" in rest:
        at = rest.index("--b")
        b_tag = rest[at + 1]
        del rest[at:at + 2]
    names = rest
    print(f"{a_tag} against {b_tag}")
    bad = False
    ref_groups = json.loads((out / f"groups.{a_tag}.json").read_text(encoding="utf-8"))
    dart_groups = json.loads((out / f"groups.{b_tag}.json").read_text(encoding="utf-8"))
    same_groups = ref_groups == dart_groups
    print(f"letter groups: {'same' if same_groups else 'DIFFERENT'} ({len(ref_groups)} tokens)")
    bad |= not same_groups
    for name in names:
        ref, ref_vad, ref_enc = load(out, name, a_tag)
        dart, dart_vad, dart_enc = load(out, name, b_tag)
        print(f"== {name}: {ref['samples'] / 16000:.1f} s")
        # Silero.
        if len(ref_vad) != len(dart_vad):
            print(f"  vad: window counts differ {len(ref_vad)} / {len(dart_vad)}")
            bad = True
        else:
            diff = float(np.abs(ref_vad - dart_vad).max()) if len(ref_vad) else 0.0
            crossed = int(sum(((ref_vad >= t) != (dart_vad >= t)).sum() for t in (THRESHOLD, NEG_THRESHOLD)))
            print(f"  vad: {len(ref_vad)} windows, largest difference {diff:.2e}, "
                  f"threshold crossings that differ {crossed}")
        # Chunks.
        ref_ranges = [(c["start"], c["end"]) for c in ref["chunks"]]
        dart_ranges = [(c["start"], c["end"]) for c in dart["chunks"]]
        print(f"  chunks: {len(ref_ranges)} / {len(dart_ranges)}, "
              f"{'same ranges' if ref_ranges == dart_ranges else 'RANGES DIFFER'}; speech "
              f"{ref['speech_seconds']:.2f} / {dart['speech_seconds']:.2f} s")
        if ref_ranges != dart_ranges:
            bad = True
            for i, (a, b) in enumerate(zip(ref_ranges, dart_ranges)):
                if a != b:
                    print(f"    first difference at chunk {i}: {a} / {b}")
                    break
            continue
        # Encoder, first chunk.
        if len(ref_enc) or len(dart_enc):
            if len(ref_enc) != len(dart_enc):
                print(f"  encoder: sizes differ {len(ref_enc)} / {len(dart_enc)}")
                bad = True
            else:
                diff = ref_enc - dart_enc
                snr = 10 * np.log10(float((ref_enc ** 2).sum()) / max(float((diff ** 2).sum()), 1e-30))
                print(f"  encoder chunk 0: {len(ref_enc) // 768} frames, largest difference "
                      f"{float(np.abs(diff).max()):.2e}, {snr:.1f} dB")
        # Tokens and words.
        tokens_same = words_same = 0
        tokens_total = words_total = 0
        conf_diff = word_conf_diff = 0.0
        time_diff = 0.0
        first_token_diff = first_word_diff = None
        for i, (rc, dc) in enumerate(zip(ref["chunks"], dart["chunks"])):
            if rc["frames"] != dc["frames"]:
                print(f"  chunk {i}: frames {rc['frames']} / {dc['frames']}")
                bad = True
            rt = [(t, f) for t, f, _ in rc["tokens"]]
            dt = [(t, f) for t, f, _ in dc["tokens"]]
            tokens_total += max(len(rt), len(dt))
            tokens_same += sum(a == b for a, b in zip(rt, dt))
            if rt != dt and first_token_diff is None:
                at = next((k for k, (a, b) in enumerate(zip(rt, dt)) if a != b), min(len(rt), len(dt)))
                first_token_diff = (i, at, len(rt), len(dt))
            for (_, _, a), (_, _, b) in zip(rc["tokens"], dc["tokens"]):
                if (a is None) != (b is None):
                    conf_diff = float("inf")
                elif a is not None:
                    conf_diff = max(conf_diff, abs(a - b))
            words_total += max(len(rc["words"]), len(dc["words"]))
            for k, (a, b) in enumerate(zip(rc["words"], dc["words"])):
                same = a[2] == b[2] and a[0] == b[0] and a[1] == b[1]
                words_same += same
                if a[2] == b[2]:
                    time_diff = max(time_diff, abs(a[0] - b[0]), abs(a[1] - b[1]))
                    if (a[3] is None) != (b[3] is None):
                        word_conf_diff = float("inf")
                    elif a[3] is not None:
                        word_conf_diff = max(word_conf_diff, abs(a[3] - b[3]))
                if not same and first_word_diff is None:
                    first_word_diff = (i, k)
            if len(rc["words"]) != len(dc["words"]) and first_word_diff is None:
                first_word_diff = (i, min(len(rc["words"]), len(dc["words"])))
        print(f"  tokens: {tokens_same} of {tokens_total} same (id and frame); token confidence "
              f"largest difference {conf_diff:.2e}"
              + ("" if first_token_diff is None else f"; first difference chunk {first_token_diff[0]} "
                 f"token {first_token_diff[1]} (counts {first_token_diff[2]} / {first_token_diff[3]})"))
        print(f"  words: {words_same} of {words_total} same (text and times); times largest "
              f"difference {time_diff:.3f} s; word confidence largest difference {word_conf_diff:.3f}"
              + ("" if first_word_diff is None else f"; first difference chunk {first_word_diff[0]} "
                 f"word {first_word_diff[1]}"))
        ref_mean, dart_mean = ref["mean_confidence"], dart["mean_confidence"]
        ref_route, dart_route = ref_mean >= ROUTE, dart_mean >= ROUTE
        print(f"  mean confidence {ref_mean:.4f} / {dart_mean:.4f} -> "
              f"{'Russian' if ref_route else 'Whisper'} / {'Russian' if dart_route else 'Whisper'}"
              f"{'' if ref_route == dart_route else '  ROUTE DIFFERS'}")
        print(f"  time: {a_tag} {times(ref)}; {b_tag} {times(dart)}")
        bad |= tokens_same != tokens_total or words_same != words_total or ref_route != dart_route
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
