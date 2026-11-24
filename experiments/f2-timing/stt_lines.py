"""Plan 10 I1d: heard words as timed lines.

Two questions, on songs whose truth lyrics are timed (studio set):

1. Are the recogniser's own word times good enough to time lines, or must the
   app's aligner run on the heard text? Each lyric line's first word is found in
   the heard words (difflib on folded words); its heard start is compared with
   the lyric line's own start. F2 measured the app's MMS_FA aligner at a median
   0.28 s from the same lyrics times, so that is the number to beat.

2. How to cut heard words into lines: a new line at a pause of at least PAUSE
   seconds, and a line longer than MAX words is split at its widest pause.
   Heard line starts and lyric line starts are paired one to one (closest
   first, within 1 s): precision = pairs / heard lines, recall = pairs / lyric
   lines starting inside the heard words' span.

    python -I stt_lines.py DATA_DIR ASR_DIR [--label NAME] [--songs 1,2,...]

Prints numbers only.
"""

import argparse
import difflib
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from stt_accuracy import folded  # noqa: E402
from stt_junk import timed_lines  # noqa: E402

HIT_S = 1.0


def heard(transcript):
    """[(start, end, folded word, break before)] in time order, one entry per folded
    part. break: 2 when the word starts with a capital or the word before ended a
    sentence (. ! ?), 1 when the word before ended with , ; : and 0 otherwise
    (both models write punctuation and capitals)."""
    out, ended = [], 2
    for segment in transcript.get("segments") or []:
        for word in segment.get("words") or []:
            text = word.get("text", "").strip()
            starts_capital = bool(text) and text.lstrip("\"'(-")[:1].isupper()
            strength = 2 if starts_capital else ended
            for k, part in enumerate(folded(text)):
                out.append((float(word["start"]), float(word["end"]), part, strength if k == 0 else 0))
            if text:
                ended = 2 if text[-1] in ".!?" else 1 if text[-1] in ",;:" else 0
    return sorted(out, key=lambda w: w[0])


def lyric_words(lines):
    """(folded words, index of each line's first word or None, line starts)."""
    words, firsts, starts = [], [], []
    for start, text in lines:
        parts = folded(text)
        firsts.append(len(words) if parts else None)
        starts.append(start)
        words.extend(parts)
    return words, firsts, starts


def cut(words, pause, max_words, marks=0, min_words=1):
    """Line starts (seconds) of heard words cut at pauses and, with marks, at
    breaks of that strength or more (2: capitals and sentence ends only, 1: also
    commas); a line shorter than min_words joins the next; long lines split."""
    if not words:
        return []
    lines, current = [], [words[0]]
    for prev, word in zip(words, words[1:]):
        if word[0] - prev[1] >= pause or (marks and word[3] >= marks):
            lines.append(current)
            current = []
        current.append(word)
    lines.append(current)
    joined = []
    for line in lines:
        if joined and len(joined[-1]) < min_words:
            joined[-1] = joined[-1] + line
        else:
            joined.append(line)
    lines = joined
    done = []
    while lines:
        line = lines.pop(0)
        if len(line) <= max_words:
            done.append(line)
            continue
        # Split at the widest pause, keeping at least 2 words on each side.
        gaps = [(line[i][0] - line[i - 1][1], i) for i in range(2, len(line) - 1)]
        _, at = max(gaps)
        lines[:0] = [line[:at], line[at:]]
    return [line[0][0] for line in done]


def one_to_one(cuts, refs):
    """Pairs of a cut and a lyric line start within HIT_S, each used once, closest first."""
    if not len(cuts) or not len(refs):
        return 0
    pairs = sorted((abs(c - r), i, j) for i, c in enumerate(cuts) for j, r in enumerate(refs)
                   if abs(c - r) <= HIT_S)
    used_cut, used_ref, matched = set(), set(), 0
    for _, i, j in pairs:
        if i not in used_cut and j not in used_ref:
            used_cut.add(i)
            used_ref.add(j)
            matched += 1
    return matched


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("data_dir", type=Path)
    parser.add_argument("asr_dir", type=Path)
    parser.add_argument("--label", default="")
    args = parser.parse_args()
    errors, songs = [], []
    for path in sorted(args.asr_dir.glob("*-transcript.json"), key=lambda p: int(p.stem.split("-")[0])):
        index = int(path.stem.split("-")[0])
        song_file = args.data_dir / "songs" / f"{index}.json"
        if not song_file.exists():
            continue
        lines = timed_lines(json.loads(song_file.read_text(encoding="utf-8")))
        words = heard(json.loads(path.read_text(encoding="utf-8")))
        if not lines or not words:
            continue
        lyric, firsts, starts = lyric_words(lines)
        matcher = difflib.SequenceMatcher(None, lyric, [w[2] for w in words], autojunk=False)
        heard_of = {}
        for block in matcher.get_matching_blocks():
            for k in range(block.size):
                heard_of[block.a + k] = block.b + k
        found = [(starts[i], words[heard_of[first]][0]) for i, first in enumerate(firsts)
                 if first is not None and first in heard_of]
        errors.extend(abs(h - s) for s, h in found)
        # Cutting is scored against every lyric line start inside the heard span (review
        # 2026-11-24: scoring only lines whose first word was heard can reverse rankings).
        span = (words[0][0] - HIT_S, words[-1][1] + HIT_S)
        songs.append((words, [s for s in starts if span[0] <= s <= span[1]], len(lines)))
    if not errors:
        print(f"{args.label}: no songs")
        return
    e = np.array(errors)
    print(f"{args.label}: {len(songs)} songs, {len(e)} lyric lines whose first word was heard "
          f"(of {sum(n for _, _, n in songs)})")
    print(f"  own word times vs lyric line starts: median {np.median(e):.2f} s, "
          f"<= 0.5 s {np.mean(e <= 0.5):.0%}, <= 1 s {np.mean(e <= 1.0):.0%}")
    print("  cutting (marks 0 none / 1 with commas / 2 capitals and . ! ?, pause s, min words, "
          "max words): precision / recall of line starts within 1 s, heard lines per lyric line")
    variants = [(0, 0.5, 1, m) for m in (6, 10)]
    variants += [(marks, pause, low, high) for marks in (1, 2) for pause in (0.7, 99.0)
                 for low in (1, 3, 4) for high in (8, 12)]
    for marks, pause, min_words, max_words in variants:
        if True:
            hits = total = recalled = lyric_total = 0
            for words, lyric_starts, _ in songs:
                cuts = np.array(cut(words, pause, max_words, marks, min_words))
                ls = np.array(lyric_starts)
                total += len(cuts)
                lyric_total += len(ls)
                matched = one_to_one(cuts, ls)
                hits += matched
                recalled += matched
            p, r = hits / max(1, total), recalled / max(1, lyric_total)
            print(f"    {marks} {pause:4.1f} {min_words} {max_words:2d}: precision {p:.2f} recall {r:.2f} "
                  f"f1 {2 * p * r / max(1e-9, p + r):.2f} lines {total / max(1, lyric_total):.2f}")


if __name__ == "__main__":
    main()
