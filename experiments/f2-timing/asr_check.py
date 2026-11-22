"""Plan 10 G0: line times heard by a speech recogniser, as an independent
check of the lyrics' times and of the aligner.

A recogniser (GigaAM or Whisper, through GigaAmTranscriber's gigaam-cli
--formats json) wrote word times for the separated vocals. Its words are
matched to the lyrics' words in order (difflib on folded words, Cyrillic
transliterated on both sides so Whisper's and GigaAM's spellings meet); a
lyric line gets the recogniser's time when its first or second word matched
(lines whose opening words were not heard get no time and do not count).

    python -I asr_check.py DATA_DIR ASR_DIR RESULTS.jsonl [--only 0,1]

ASR_DIR holds <index>-transcript.json. RESULTS.jsonl (from timing_probe.py)
gives the aligner's per-line times for the same lines. Prints numbers only.
"""

import difflib
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import timing_probe as tp  # noqa: E402


def folded(text):
    """Words in a-z for matching, whatever the script."""
    words, _ = tp.romanize(text.replace("ё", "е").replace("Ё", "Е"))
    return words


def heard_line_starts(sung, asr_words):
    """{line index: start (s)} for the lines whose first or second word the
    recogniser heard; and the share of lyric words heard at all."""
    lyric_words, owner, place = [], [], []
    for index, (_, _, text) in enumerate(sung):
        for k, word in enumerate(folded(text)):
            lyric_words.append(word)
            owner.append(index)
            place.append(k)
    heard, times = [], []
    for w in asr_words:
        for word in folded(w["text"]):
            heard.append(word)
            times.append(w["start"])
    matcher = difflib.SequenceMatcher(a=lyric_words, b=heard, autojunk=False)
    starts, matched = {}, 0
    for block in matcher.get_matching_blocks():
        for k in range(block.size):
            i = block.a + k
            matched += 1
            if place[i] <= 1 and owner[i] not in starts:
                starts[owner[i]] = times[block.b + k]
    return starts, matched / max(len(lyric_words), 1)


def main():
    data, asr_dir, results = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
    only = set()
    if "--only" in sys.argv:
        only = {int(i) for i in sys.argv[sys.argv.index("--only") + 1].split(",")}
    aligned_by = {}
    for line in open(results, encoding="utf-8"):
        record = json.loads(line)
        aligned_by[record["index"]] = record
    totals = {"lyrics": [], "aligner": [], "shift": []}
    for path in sorted(asr_dir.glob("*-transcript.json"), key=lambda p: int(p.stem.split("-")[0])):
        index = int(path.stem.split("-")[0])
        if only and index not in only:
            continue
        asr = json.loads(path.read_text(encoding="utf-8"))
        words = [w for s in asr["segments"] for w in s.get("words", [])]
        song = json.loads((data / "songs" / f"{index}.json").read_text(encoding="utf-8"))
        record = aligned_by.get(index, {"sources": {}})
        out = [f"#{index} {asr.get('model', '?')} {asr.get('elapsed_seconds', 0):.1f}s:"]
        for source, lines in song["sources"].items():
            sung = tp.sung_lines(lines)
            if len(sung) < 3:
                continue
            starts, heard_share = heard_line_starts(sung, words)
            if len(starts) < 3:
                out.append(f"{source} heard {heard_share:.2f}, {len(starts)} lines")
                continue
            vs_lyrics = np.array([starts[i] - sung[i][0] for i in starts])
            median = float(np.median(vs_lyrics))
            text = (f"{source} heard {heard_share:.2f} lines {len(starts)}/{len(sung)}:"
                    f" lyrics vs heard median {median:+.2f} within 1s of it"
                    f" {np.mean(np.abs(vs_lyrics - median) < 1):.2f}")
            totals["lyrics"] += list(np.abs(vs_lyrics))
            totals["shift"] += list(np.abs(vs_lyrics - median))
            a = (record["sources"].get(source) or {}).get("align") or {}
            if "deltas" in a:
                with_words = [i for i, (_, _, t) in enumerate(sung) if tp.romanize(t)[0]]
                if len(with_words) == len(a["deltas"]):
                    aligned = {i: sung[i][0] + d for i, d in zip(with_words, a["deltas"])}
                    vs_aligner = np.array([aligned[i] - starts[i] for i in starts if i in aligned])
                    totals["aligner"] += list(np.abs(vs_aligner))
                    text += (f"; aligner per line vs heard: median |d| {np.median(np.abs(vs_aligner)):.2f}"
                             f" <1s {np.mean(np.abs(vs_aligner) < 1):.2f}")
            out.append(text)
        print(" | ".join(out), flush=True)
    for name, values in totals.items():
        if values:
            v = np.array(values)
            print(f"TOTAL {name} vs heard (per line): n={len(v)} median {np.median(v):.2f}"
                  f" <0.5s {np.mean(v < 0.5):.2f} <1s {np.mean(v < 1):.2f}")


if __name__ == "__main__":
    main()
