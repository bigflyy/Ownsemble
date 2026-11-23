"""Plan 10 I1b: how well a recogniser's text could stand in for lyrics.

For every song in DATA_DIR/songs with lyrics and a transcript in ASR_DIR
(<index>-transcript.json from gigaam-cli --formats json), the heard words are
compared with the lyrics' words (folded to a-z like asr_check.py, so Cyrillic
and Latin spellings meet):
  wer        word error rate: word edit distance / lyric words
  recall     share of lyric words heard (in order, difflib)
  precision  share of heard words that are lyric words (the rest is invented
             or misheard text a reader would see)
  conf       mean word confidence the recogniser gave
Songs are grouped as Russian (Cyrillic lyrics) or other. Prints numbers only.

    python -I stt_accuracy.py DATA_DIR ASR_DIR [--jsonl OUT.jsonl] [--label NAME]
        [--expect OTHER_ASR_DIR]

--expect: every song with a transcript in OTHER_ASR_DIR counts; one missing
in ASR_DIR (the recogniser found no speech) counts as nothing heard.
"""

import argparse
import difflib
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import timing_probe as tp  # noqa: E402

# The source whose lyrics count as the truth, first one present wins.
SOURCE_ORDER = ["vk", "lrclib", "netease", "qq", "truth"]


def folded(text):
    """Words in a-z for matching, whatever the script."""
    words, _ = tp.romanize(text.replace("ё", "е").replace("Ё", "Е"))
    return words


def is_cyrillic(text):
    """True when most letters of the text are Cyrillic."""
    letters = [ch for ch in text if ch.isalpha()]
    if not letters:
        return False
    cyr = sum(1 for ch in letters if "Ѐ" <= ch <= "ӿ")
    return cyr / len(letters) > 0.5


def edit_distance(a, b):
    """Word-level Levenshtein distance between two word lists."""
    previous = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        current = [i]
        for j, y in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1,
                               previous[j - 1] + (x != y)))
        previous = current
    return previous[-1]


def lyric_text(song):
    """The truth lyrics of a saved song as one string, or None."""
    sources = song.get("sources") or {}
    for name in SOURCE_ORDER + sorted(sources):
        lines = sources.get(name)
        if lines:
            return " ".join(line.get("t", "") for line in lines)
    return None


def heard_words(transcript):
    """(folded words, confidences) of a gigaam-cli JSON transcript."""
    words, confs = [], []
    for segment in transcript.get("segments") or []:
        for word in segment.get("words") or []:
            for part in folded(word.get("text", "")):
                words.append(part)
                confs.append(float(word.get("confidence") or 0.0))
    return words, confs


def score(lyric, heard):
    """wer, recall and precision of heard words against lyric words."""
    matcher = difflib.SequenceMatcher(None, lyric, heard, autojunk=False)
    matched = sum(block.size for block in matcher.get_matching_blocks())
    return (edit_distance(lyric, heard) / max(1, len(lyric)),
            matched / max(1, len(lyric)),
            matched / max(1, len(heard)))


def describe(values):
    """Median and quartiles as text."""
    if not values:
        return "-"
    q1, q2, q3 = np.percentile(values, [25, 50, 75])
    return f"median {q2:.2f} (q1 {q1:.2f}, q3 {q3:.2f})"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("data_dir")
    parser.add_argument("asr_dir")
    parser.add_argument("--jsonl")
    parser.add_argument("--label", default="")
    parser.add_argument("--expect")
    args = parser.parse_args()
    data, asr = Path(args.data_dir), Path(args.asr_dir)
    rows = []
    for song_file in sorted((data / "songs").glob("*.json"),
                            key=lambda p: int(p.stem)):
        index = int(song_file.stem)
        transcript_file = asr / f"{index}-transcript.json"
        expected = (args.expect and
                    (Path(args.expect) / f"{index}-transcript.json").exists())
        if not transcript_file.exists() and not expected:
            continue
        text = lyric_text(json.loads(song_file.read_text(encoding="utf-8")))
        if not text:
            continue
        lyric = folded(text)
        transcript = (json.loads(transcript_file.read_text(encoding="utf-8"))
                      if transcript_file.exists() else {})
        heard, confs = heard_words(transcript)
        if not lyric:
            continue
        wer, recall, precision = score(lyric, heard)
        rows.append({
            "index": index, "ru": is_cyrillic(text), "lyric_words": len(lyric),
            "heard_words": len(heard), "wer": wer, "recall": recall,
            "precision": precision,
            "conf": float(np.mean(confs)) if confs else 0.0,
            "speech_s": float(transcript.get("speech_seconds") or 0.0),
        })
    print(f"{args.label} {len(rows)} songs")
    for name, group in (("russian", [r for r in rows if r["ru"]]),
                        ("other", [r for r in rows if not r["ru"]])):
        if not group:
            continue
        print(f"  {name} {len(group)}:")
        for key in ("wer", "recall", "precision", "conf"):
            print(f"    {key:9s} {describe([r[key] for r in group])}")
        good = sum(1 for r in group if r["wer"] <= 0.3)
        print(f"    wer <= 0.3: {good} of {len(group)}")
    if args.jsonl:
        with open(args.jsonl, "w", encoding="utf-8") as out:
            for row in rows:
                out.write(json.dumps(row) + "\n")


if __name__ == "__main__":
    main()
