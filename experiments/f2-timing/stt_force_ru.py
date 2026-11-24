"""Plan 10 I2e: on a Russian song, are Whisper's chunks in another language
better heard again as Russian? Per chunk: Whisper's own language and mean
confidence, the forced-Russian reading's confidence, and how well each
reading agrees with GigaAM's words over the same time span (GigaAM is sure
of this song, so it stands in for the truth): difflib ratio of the folded
word lists. Prints numbers only, no words.

    python -I stt_force_ru.py AUTO.json FORCED.json GIGAAM_HEARD.json

AUTO / FORCED: tool/check_whisper.dart output (chunks with start/end in
samples, words); GIGAAM_HEARD: tool/check_hear_words.dart output (words with
times in ms).
"""

import difflib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from stt_accuracy import folded  # noqa: E402


def as_dicts(words):
    """check_whisper.dart writes words as [start, end, text, confidence]."""
    return [w if isinstance(w, dict) else {"text": w[2], "confidence": w[3]} for w in words]


def mean_conf(words):
    values = [w["confidence"] for w in as_dicts(words) if w.get("confidence") is not None]
    return sum(values) / len(values) if values else 0.0


def text_of(words, key="text"):
    parts = []
    for word in as_dicts(words) if key == "text" else words:
        parts.extend(folded(word[key]))
    return parts


def main():
    auto = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    forced = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
    gigaam = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))["words"]
    for a, f in zip(auto["chunks"], forced["chunks"]):
        assert a["start"] == f["start"] and a["end"] == f["end"]
        start, end = a["start"] / 16000, a["end"] / 16000
        truth = text_of([w for w in gigaam if start <= w["s"] / 1000 < end], "t")
        def agree(words):
            heard = text_of(words)
            return difflib.SequenceMatcher(a=heard, b=truth, autojunk=False).ratio()
        print(f"chunk {start:6.1f}-{end:6.1f} s: auto {a['language']} conf "
              f"{mean_conf(a['words']):.3f} agree {agree(a['words']):.2f} "
              f"({len(a['words'])} words) | ru conf {mean_conf(f['words']):.3f} "
              f"agree {agree(f['words']):.2f} ({len(f['words'])} words) | "
              f"GigaAM {len(truth)} words")


if __name__ == "__main__":
    main()
