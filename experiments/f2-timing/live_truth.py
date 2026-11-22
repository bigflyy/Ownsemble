"""Plan 10 F2: on live uploads, how far off are the studio lyrics really,
and how close did each method come?

The truth is LRCLIB's lyrics timed for the live upload itself (source
"truth", saved by probe_lyrics_timing.dart --live). The studio lyrics' lines
are matched to the truth's lines by their words (in order), and the
difference of their starts is how late each studio line should be.

    python -I live_truth.py LIVE_DIR RESULTS.jsonl

Prints only indexes and numbers.
"""

import difflib
import json
import re
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import timing_probe as tp  # noqa: E402


def words(text):
    return re.sub(r"[^\w]+", " ", text.lower()).strip()


def true_shifts(studio, truth):
    """Start differences (s) of the lines both lyrics share, in order."""
    a = [l for l in studio if "s" in l and l["t"].strip()]
    b = [l for l in truth if "s" in l and l["t"].strip()]
    matcher = difflib.SequenceMatcher(
        a=[words(l["t"]) for l in a], b=[words(l["t"]) for l in b], autojunk=False)
    shifts = []
    for block in matcher.get_matching_blocks():
        for k in range(block.size):
            shifts.append((b[block.b + k]["s"] - a[block.a + k]["s"]) / 1000)
    return shifts


def per_line_errors(studio, truth, deltas):
    """For the lines both lyrics share: |aligned start - truth start| (the
    aligner's own line times) and |studio start + median offset - truth
    start| (one shift for the whole song), in seconds."""
    sung = tp.sung_lines(studio)
    with_words = [i for i, (_, _, t) in enumerate(sung) if tp.romanize(t)[0]]
    if len(with_words) != len(deltas):
        return None
    aligned = {sung[i][0]: sung[i][0] + d for i, d in zip(with_words, deltas)}
    offset = float(np.median(deltas))
    a = [l for l in studio if "s" in l and l["t"].strip()]
    b = [l for l in truth if "s" in l and l["t"].strip()]
    matcher = difflib.SequenceMatcher(
        a=[words(l["t"]) for l in a], b=[words(l["t"]) for l in b], autojunk=False)
    own, shifted = [], []
    for block in matcher.get_matching_blocks():
        for k in range(block.size):
            start = a[block.a + k]["s"] / 1000
            true = b[block.b + k]["s"] / 1000
            if start in aligned:
                own.append(abs(aligned[start] - true))
                shifted.append(abs(start + offset - true))
    return own, shifted


def main():
    live, results = Path(sys.argv[1]), sys.argv[2]
    by_index = {}
    for line in open(results, encoding="utf-8"):
        record = json.loads(line)
        by_index[record["index"]] = record
    rows = []
    for path in sorted((live / "songs").glob("*.json"), key=lambda p: int(p.stem)):
        song = json.loads(path.read_text(encoding="utf-8"))
        record = by_index.get(song["index"])
        truth = song["sources"].get("truth")
        if record is None:
            continue
        for source, lines in song["sources"].items():
            if source == "truth":
                continue
            r = record["sources"].get(source)
            if r is None:
                continue
            a = r.get("align") or {}
            line = (f"#{song['index']} {source}: align {a.get('offset')} within"
                    f" {a.get('within_1s')} head {a.get('head_offset')}"
                    f" vad_first {r.get('vad_first')} ctc_corr {(r.get('ctc_corr') or [None])[0]}")
            if truth and [l.get("s") for l in truth] == [l.get("s") for l in lines]:
                line += " | truth is these same lyrics (LRCLIB gave the studio row)"
            elif truth:
                shifts = true_shifts(lines, truth)
                if len(shifts) >= 3:
                    median = float(np.median(shifts))
                    drift = float(np.percentile(shifts, 90) - np.percentile(shifts, 10))
                    line += f" | TRUE median {median:.2f} (10-90% range {drift:.2f}, {len(shifts)} lines)"
                    if "offset" in a:
                        rows.append((median, a["offset"], a["within_1s"]))
                        errors = per_line_errors(lines, truth, a.get("deltas", []))
                        if errors and errors[0]:
                            own, shifted = (np.array(e) for e in errors)
                            line += (f" | per line: aligned <1s {np.mean(own < 1):.2f}"
                                     f" median {np.median(own):.2f}; one shift <1s"
                                     f" {np.mean(shifted < 1):.2f} median {np.median(shifted):.2f}")
            print(line)
    if rows:
        errors = [abs(t - o) for t, o, _ in rows]
        print(f"align vs truth: n={len(rows)} |err|<0.5 {sum(e < 0.5 for e in errors)}"
              f" <1 {sum(e < 1 for e in errors)} median {np.median(errors):.2f}")


if __name__ == "__main__":
    main()
