"""Plan 10 I2h: scores what the release app heard in the hearAccept bench.

Reads the bench result (BENCH.json, part hearAccept), the songs' positions
and keys (KEYS.txt, lines "<index>=<key> <seconds>") and the heard words the
app saved (DATA_DIR/library.db, table heard_lyrics). Per song:

  parity   the app's words against the research transcript of the same model
           on the same song (Kim Vocal 2 vocals, GigaAM RNNT int8 or Whisper
           turbo q5_0 on the CPU; --research DIR/<rnnt|whisper-turbo>/
           <index>-transcript.json): word error rate between the two, and the
           route the research numbers give (GigaAM's mean word confidence >=
           0.80 = Russian) against the app's
  quality  word error rate, recall and precision (words equal on the
           least-edits alignment) against the song's lyrics
           (--truth DIRS: songs/<index>.json as the research saved them; else
           the lyrics the app found, from library.db), folded to a-z as
           stt_accuracy.py does; and whether the app marked it rough
  lines    for songs with timed lyrics: the app's heard line starts against
           the lyrics' line starts, paired one to one within 1 s (precision,
           recall); and each lyric line's first word, found in the heard
           words, against the line's own start

Prints numbers, routes and sources only, never words or keys.

    python -I stt_accept.py BENCH.json KEYS.txt DATA_DIR --research DIR
        --truth DIR [DIR ...] [--held 4,15,...]
"""

import argparse
import json
import re
import sqlite3
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from stt_accuracy import SOURCE_ORDER, edit_distance, folded, heard_words, score  # noqa: E402
from stt_lines import one_to_one  # noqa: E402

GOOD_WER = 0.3
RUSSIAN_LINE = 0.80


def app_words(words_json):
    """[(start s, folded word, confidence or None)] of the app's stored words."""
    out = []
    for word in json.loads(words_json or "[]"):
        for part in folded(word.get("t", "")):
            out.append((word["s"] / 1000.0, part, word.get("c")))
    return out


def research_route(transcript):
    """'gigaam' when the RNNT transcript's mean word confidence is >= 0.80."""
    confs = [float(w.get("confidence") or 0.0)
             for s in transcript.get("segments") or [] for w in s.get("words") or []]
    mean = float(np.mean(confs)) if confs else 0.0
    return ("gigaam" if mean >= RUSSIAN_LINE else "whisper"), mean


def truth_of(index, key, dirs, db):
    """(source, [(start s or None, text)]) of the song's lyrics."""
    for folder in dirs:
        path = folder / "songs" / f"{index}.json"
        if path.exists():
            sources = json.loads(path.read_text(encoding="utf-8")).get("sources") or {}
            names = SOURCE_ORDER + sorted(sources)
            # A timed source first, so the line timing has its truth (review).
            names.sort(key=lambda n: not (sources.get(n) and all(
                isinstance(line.get("s"), (int, float)) for line in sources[n])))
            for name in names:
                lines = sources.get(name)
                if lines:
                    return name, [(line["s"] / 1000.0 if isinstance(line.get("s"), (int, float))
                                   else None, line.get("t", "")) for line in lines]
    rows = db.execute("SELECT source, timed, body FROM lyrics WHERE ref = ? AND found = 1 "
                      "AND body IS NOT NULL", (key,)).fetchall()
    order = {name: i for i, name in enumerate(SOURCE_ORDER)}
    rows.sort(key=lambda r: (-r[1], order.get(r[0], 99)))
    for source, _, body in rows:
        lines = json.loads(body)
        if lines:
            return f"{source} (app)", [(line["s"] / 1000.0 if isinstance(line.get("s"), int)
                                        else None, line.get("t", "")) for line in lines]
    return None, None


def aligned(a, b):
    """{index in a: index in b} of equal words on a least-edits alignment.

    difflib's longest-block matching pairs a repeated chorus with the wrong
    repeat (#103: every first word 10+ s off while the line starts paired
    by time were fine), so the first words use the edit-distance path."""
    n, m = len(a), len(b)
    cost = np.zeros((n + 1, m + 1), dtype=np.int32)
    cost[:, 0] = np.arange(n + 1)
    cost[0, :] = np.arange(m + 1)
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            cost[i, j] = min(cost[i - 1, j] + 1, cost[i, j - 1] + 1,
                             cost[i - 1, j - 1] + (a[i - 1] != b[j - 1]))
    pairs, i, j = {}, n, m
    while i > 0 and j > 0:
        if a[i - 1] == b[j - 1] and cost[i, j] == cost[i - 1, j - 1]:
            pairs[i - 1] = j - 1
            i, j = i - 1, j - 1
        elif cost[i, j] == cost[i - 1, j - 1] + 1:
            i, j = i - 1, j - 1
        elif cost[i, j] == cost[i - 1, j] + 1:
            i -= 1
        else:
            j -= 1
    return pairs


def line_scores(heard_body, words, truth_lines):
    """Line-start precision / recall within 1 s and first-word offsets, or None."""
    timed = [(s, t) for s, t in truth_lines if s is not None and t.strip()]
    if len(timed) < len([t for _, t in truth_lines if t.strip()]) or not timed or not words:
        return None
    heard_starts = np.array([line["s"] / 1000.0 for line in json.loads(heard_body or "[]")
                             if line.get("t", "").strip() and isinstance(line.get("s"), int)])
    span = (words[0][0] - 1.0, words[-1][0] + 2.0)
    refs = np.array([s for s, _ in timed if span[0] <= s <= span[1]])
    matched = one_to_one(heard_starts, refs)
    # First words: each lyric line's first word in the heard words.
    lyric, firsts, starts = [], [], []
    for start, text in timed:
        parts = folded(text)
        firsts.append(len(lyric) if parts else None)
        starts.append(start)
        lyric.extend(parts)
    heard_of = aligned(lyric, [w[1] for w in words])
    offsets = [abs(words[heard_of[f]][0] - starts[i]) for i, f in enumerate(firsts)
               if f is not None and f in heard_of]
    return {
        "heardLines": len(heard_starts), "lyricLines": len(refs), "allLyricLines": len(timed),
        "pairs": matched,
        "precision": matched / max(1, len(heard_starts)), "recall": matched / max(1, len(refs)),
        "firstWords": len(offsets), "offsets": offsets,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("bench", type=Path)
    parser.add_argument("keys", type=Path)
    parser.add_argument("data_dir", type=Path)
    parser.add_argument("--research", type=Path, required=True)
    parser.add_argument("--truth", type=Path, nargs="+", default=[])
    parser.add_argument("--held", default="", help="indices counted as held-out songs")
    parser.add_argument("--jsonl", type=Path)
    args = parser.parse_args()
    held = {int(i) for i in args.held.split(",") if i.strip()}
    index_of = {}
    for line in args.keys.read_text(encoding="utf-8").splitlines():
        m = re.match(r"(\d+)=(\S+)", line.strip())
        if m:
            index_of[m.group(2)] = int(m.group(1))
    bench = json.loads(args.bench.read_text(encoding="utf-8"))["hearAccept"]
    db = sqlite3.connect(f"file:{args.data_dir / 'library.db'}?mode=ro", uri=True)
    rows = []
    print(f"threads {bench.get('threads')}, memory before {bench.get('memoryBefore')}, "
          f"after {bench.get('memoryAfter')}")
    print("idx  s    route   lang rough conf  ruconf words lines  total sep  gigaam whisp "
          "peakMB | parity wer, research route | truth wer rec prec | lines p r, first-word med")
    for song in bench["songs"]:
        key = song["key"]
        index = index_of.get(key, -1)
        r = {"index": index, "seconds": song.get("seconds"), "error": song.get("error"),
             "outcome": song.get("outcome"), "heard": song.get("heard"),
             "model": song.get("model"), "language": song.get("language"),
             "rough": song.get("rough"), "confidence": song.get("confidence"),
             "ruConfidence": song.get("russianConfidence"), "words": song.get("words"),
             "lines": song.get("lines"), "ms": song.get("ms"), "peak": song.get("peak"),
             "play": song.get("play"), "before": song.get("before"),
             "after": song.get("after"), "placeAsExpected": song.get("placeAsExpected"),
             "held": index in held}
        steps = song.get("steps") or []
        for k, step in enumerate(steps):
            end = steps[k + 1]["atMs"] if k + 1 < len(steps) else song.get("ms", 0)
            r.setdefault("stepMs", {})[step["step"]] = end - step["atMs"]
        row = db.execute("SELECT words, body, model, outcome FROM heard_lyrics WHERE ref = ?",
                         (key,)).fetchone()
        # Only this run's result counts: a failed or stopped run must not score an older
        # row, and the stored row must be the one the bench saw (review).
        if song.get("outcome") != "done":
            row = None
        elif row is None:
            r["problem"] = "no stored row (another upload key?)"
        elif row[3] != song.get("heard") or (row[2] or None) != (song.get("model") or None):
            r["problem"] = "stored row differs from the run"
            row = None
        words = app_words(row[0]) if row else []
        # Parity with the research transcript of the same model.
        model = song.get("model")
        rnnt = args.research / "rnnt" / f"{index}-transcript.json"
        if rnnt.exists():
            route, mean = research_route(json.loads(rnnt.read_text(encoding="utf-8")))
            r["researchRoute"], r["researchRuConfidence"] = route, mean
            folder = "rnnt" if model == "gigaam" else "whisper-turbo"
            ref = args.research / folder / f"{index}-transcript.json"
            if model and ref.exists():
                ref_words, _ = heard_words(json.loads(ref.read_text(encoding="utf-8")))
                app = [w[1] for w in words]
                r["parityWer"] = edit_distance(ref_words, app) / max(1, len(ref_words))
                r["parityWords"] = [len(ref_words), len(app)]
        # Quality against the lyrics.
        source, truth = truth_of(index, key, args.truth, db)
        r["truthSource"] = source
        if truth and row is not None:
            # A sung song heard as no words or no singing counts as nothing heard (review).
            lyric = folded(" ".join(t for _, t in truth))
            heard_list = [w[1] for w in words]
            wer, _, _ = score(lyric, heard_list)
            # Recall and precision on the same least-edits path as the error rate
            # (difflib's blocks gave #103 recall 0.40 beside a 0.25 error rate).
            matched = len(aligned(lyric, heard_list))
            recall = matched / max(1, len(lyric))
            precision = matched / max(1, len(heard_list))
            r.update(truthWer=wer, recall=recall, precision=precision)
            if words:
                r["lineScores"] = line_scores(row[1], words, truth)
        elif truth:
            r["problem"] = r.get("problem") or "not scored: no result of this run"
        rows.append(r)

        def f(v, fmt):
            return format(v, fmt) if isinstance(v, (int, float)) else "-"
        st = r.get("stepMs", {})
        ls = r.get("lineScores")
        print(f"{index:3d} {f(r['seconds'], '4d')} {str(model or r['heard'] or r['outcome']):7s} "
              f"{str(r['language'] or '-'):4s} {str(r['rough'])[:1]:5s} "
              f"{f(r['confidence'], '.3f')} {f(r['ruConfidence'], '.3f')} {f(r['words'], '5d')} "
              f"{f(r['lines'], '4d')} {f((r['ms'] or 0) / 1000, '6.0f')} "
              f"{f(st.get('separate', 0) / 1000, '4.0f')} {f(st.get('gigaam', 0) / 1000, '5.0f')} "
              f"{f(st.get('whisper', 0) / 1000, '5.0f')} {f((r['peak'] or {}).get('workingSetMB'), '5d')} | "
              f"{f(r.get('parityWer'), '.2f')} {r.get('researchRoute', '-')} | "
              f"{f(r.get('truthWer'), '.2f')} {f(r.get('recall'), '.2f')} {f(r.get('precision'), '.2f')} "
              f"{source or '-'} | "
              + (f"{ls['precision']:.2f} {ls['recall']:.2f} {np.median(ls['offsets']) if ls['offsets'] else float('nan'):.2f}"
                 if ls else "-")
              + ("" if r["placeAsExpected"] else "  PLACE?")
              + ("  ERROR" if r["error"] else "")
              + (f"  ({r['problem']})" if r.get("problem") else ""))
    # Summaries.
    print()
    par = [r for r in rows if "parityWer" in r]
    with_research = [r for r in rows if "researchRoute" in r]
    print(f"research transcripts for {len(with_research)} songs, parity computed for {len(par)} "
          f"(others: no words in the app or no reference)")
    if par:
        same = sum(1 for r in par if r.get("researchRoute") == r.get("model"))
        print(f"parity: {len(par)} songs, route as research {same} of {len(par)}, wer to research "
              f"median {np.median([r['parityWer'] for r in par]):.2f}, max {max(r['parityWer'] for r in par):.2f}")
    for name, group in (("held-out", [r for r in rows if r["held"]]),
                        ("all with lyrics", [r for r in rows if "truthWer" in r])):
        group = [r for r in group if "truthWer" in r]
        if not group:
            continue
        good = [r for r in group if r["truthWer"] <= GOOD_WER]
        bad = [r for r in group if r["truthWer"] > GOOD_WER]
        print(f"{name}: {len(group)} songs, wer median {np.median([r['truthWer'] for r in group]):.2f}; "
              f"good (wer <= {GOOD_WER}) {len(good)}: rough {sum(1 for r in good if r['rough'])}; "
              f"bad {len(bad)}: rough {sum(1 for r in bad if r['rough'])}, "
              f"shown as not rough {sum(1 for r in bad if not r['rough'])}")
        for model in ("gigaam", "whisper"):
            sub = [r for r in group if r["model"] == model]
            if sub:
                print(f"  {model}: {len(sub)}, wer median {np.median([r['truthWer'] for r in sub]):.2f}")
    timed = [r for r in rows if r.get("lineScores")]
    if timed:
        pairs = sum(r["lineScores"]["pairs"] for r in timed)
        heard_lines = sum(r["lineScores"]["heardLines"] for r in timed)
        lyric_lines = sum(r["lineScores"]["lyricLines"] for r in timed)
        offsets = np.array([o for r in timed for o in r["lineScores"]["offsets"]])
        all_lines = sum(r["lineScores"]["allLyricLines"] for r in timed)
        print(f"lines: lyric lines inside the heard span {lyric_lines} of {all_lines}")
        print(f"lines: {len(timed)} timed songs, precision {pairs / max(1, heard_lines):.2f}, recall "
              f"{pairs / max(1, lyric_lines):.2f}, heard lines per lyric line "
              f"{heard_lines / max(1, lyric_lines):.2f}; first words {len(offsets)}: median "
              f"{np.median(offsets):.2f} s, <= 0.5 s {np.mean(offsets <= 0.5):.0%}, <= 1 s "
              f"{np.mean(offsets <= 1.0):.0%}")
    failed = [r for r in rows if r["outcome"] != "done" or r["error"]]
    problems = [r for r in rows if r.get("problem")]
    print(f"runs not done: {len(failed)}, rows with problems: {len(problems)}, place not as "
          f"expected: {sum(1 for r in rows if not r['placeAsExpected'])}, playback not verified: "
          f"{sum(1 for r in rows if not ((r['play'] or {}).get('ok') and (r['play'] or {}).get('stillPlayingAfter1s')))}")
    if args.jsonl:
        with args.jsonl.open("w", encoding="utf-8") as out:
            for r in rows:
                if r.get("lineScores"):
                    r["lineScores"] = {k: v for k, v in r["lineScores"].items() if k != "offsets"}
                out.write(json.dumps(r) + "\n")


if __name__ == "__main__":
    main()
