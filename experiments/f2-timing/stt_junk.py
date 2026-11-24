"""Plan 10 I1c: junk a recogniser writes over music, and a song-level trust signal.

Junk over music: on songs whose truth lyrics are timed (a source with line
starts), the stretches with no singing are taken from the lyrics: before the
first line (minus 1 s), after the last line (plus 8 s), and inside a gap
between two line starts longer than 12 s (from line start + 8 s to the next
start - 1 s). Heard words starting there are counted per song, and how many of
them are not lyric words at all (invented text, not a chorus heard early).

Trust: per song the signals a reader of the app could compute without the
lyrics -- mean word confidence, share of words below 0.80, heard words per
second of found speech -- against the truth "good" = word error rate <= 0.3
(stt_accuracy.py's jsonl). For each signal: AUC, and for thresholds that
refuse a song, how many bad songs still pass and how many good ones are refused.

    python -I stt_junk.py DATA_DIR ASR_DIR ACC_JSONL [--label NAME]

Prints numbers only.
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from stt_accuracy import folded  # noqa: E402

GAP_S = 12.0     # a gap between line starts longer than this holds music
LINE_S = 8.0     # a line is taken to last at most this long
LOW_CONF = 0.80  # GigaAmTranscriber's doubt_strong mark


def timed_lines(song):
    """[(start s, text)] of the first source whose lines carry start times (saved in ms)."""
    lines = timed_lines_with_ends(song)
    return [(start, text) for start, _, text in lines] if lines else None


def timed_lines_with_ends(song):
    """[(start s, end s or None, text)] of the first source whose lines carry start
    times; VK's lines also carry end times ("e", ms)."""
    for lines in (song.get("sources") or {}).values():
        if lines and all(isinstance(line.get("s"), (int, float)) for line in lines):
            return [(line["s"] / 1000.0,
                     line["e"] / 1000.0 if isinstance(line.get("e"), (int, float)) else None,
                     line.get("t", "")) for line in lines if line.get("t")]
    return None


def music_spans(lines, seconds):
    """Stretches of the song where the timed lyrics have no singing. A line lasts
    until its own end time when the source gives one, else at most LINE_S."""
    spans = [(0.0, lines[0][0] - 1.0)]
    for (start, end, _), following in zip(lines, lines[1:] + [None]):
        until = following[0] if following else seconds
        sung_to = end if end is not None else start + LINE_S
        if following is None or end is not None or until - start > GAP_S:
            spans.append((sung_to, until - 1.0 if following else until))
    return [(a, b) for a, b in spans if b - a > 1.0]


def words_with_times(transcript):
    """[(start, folded word, confidence)] of a gigaam-cli JSON transcript."""
    out = []
    for segment in transcript.get("segments") or []:
        for word in segment.get("words") or []:
            for part in folded(word.get("text", "")):
                out.append((float(word.get("start") or 0.0), part,
                            float(word.get("confidence") or 0.0)))
    return out


def auc(scores, good):
    """Probability that a good song scores above a bad one (ties half)."""
    pos = [s for s, g in zip(scores, good) if g]
    neg = [s for s, g in zip(scores, good) if not g]
    if not pos or not neg:
        return float("nan")
    wins = sum((p > n) + 0.5 * (p == n) for p in pos for n in neg)
    return wins / (len(pos) * len(neg))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("data_dir", type=Path)
    parser.add_argument("asr_dir", type=Path)
    parser.add_argument("acc_jsonl", type=Path)
    parser.add_argument("--label", default="")
    args = parser.parse_args()
    accuracy = {row["index"]: row for row in
                map(json.loads, args.acc_jsonl.read_text(encoding="utf-8").splitlines())}
    junk_rows, trust_rows = [], []
    for index, acc in sorted(accuracy.items()):
        song = json.loads((args.data_dir / "songs" / f"{index}.json").read_text(encoding="utf-8"))
        path = args.asr_dir / f"{index}-transcript.json"
        transcript = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
        heard = words_with_times(transcript)
        confs = [c for _, _, c in heard]
        speech = float(transcript.get("speech_seconds") or 0.0)
        trust_rows.append({
            "index": index, "ru": acc["ru"], "good": acc["wer"] <= 0.3,
            "conf": float(np.mean(confs)) if confs else 0.0,
            "low": float(np.mean([c < LOW_CONF for c in confs])) if confs else 1.0,
            "wps": len(heard) / speech if speech else 0.0})
        lines = timed_lines_with_ends(song)
        if not lines:
            continue
        # A song with no heard words still counts its music time (with nothing over it).
        lyric_vocab = set(folded(" ".join(text for _, _, text in lines)))
        spans = music_spans(lines, float(song.get("seconds") or lines[-1][0] + 10))
        over = [(t, w) for t, w, _ in heard if any(a <= t < b for a, b in spans)]
        junk_rows.append({"index": index, "ru": acc["ru"], "music_s": sum(b - a for a, b in spans),
                          "heard": len(heard), "over": len(over),
                          "invented": sum(1 for _, w in over if w not in lyric_vocab)})
    print(f"{args.label}: junk over music ({len(junk_rows)} timed songs)")
    for name, group in (("russian", [r for r in junk_rows if r["ru"]]),
                        ("other", [r for r in junk_rows if not r["ru"]])):
        if not group:
            continue
        music = sum(r["music_s"] for r in group)
        over = sum(r["over"] for r in group)
        invented = sum(r["invented"] for r in group)
        with_junk = sum(1 for r in group if r["invented"] >= 5)
        share = over / max(1, sum(r["heard"] for r in group))
        print(f"  {name} {len(group)}: music {music / 60:.0f} min, words there {over} "
              f"({share:.1%} of heard), not lyric words {invented}, "
              f"songs with >= 5 invented {with_junk}; per song invented median "
              f"{np.median([r['invented'] for r in group]):.0f}, max {max(r['invented'] for r in group)}")
    print(f"{args.label}: trust ({len(trust_rows)} songs, good = wer <= 0.3)")
    for name, group in (("russian", [r for r in trust_rows if r["ru"]]),
                        ("other", [r for r in trust_rows if not r["ru"]])):
        if not group:
            continue
        good = [r["good"] for r in group]
        print(f"  {name} {len(group)} ({sum(good)} good): AUC conf {auc([r['conf'] for r in group], good):.2f}, "
              f"low-share {auc([-r['low'] for r in group], good):.2f}, "
              f"words/s {auc([r['wps'] for r in group], good):.2f}")
        for threshold in (0.80, 0.85, 0.88, 0.90, 0.92, 0.94):
            passed = [r for r in group if r["conf"] >= threshold]
            bad_pass = sum(1 for r in passed if not r["good"])
            good_refused = sum(1 for r in group if r["good"] and r["conf"] < threshold)
            print(f"    conf >= {threshold:.2f}: shown {len(passed)}, of them bad {bad_pass}; "
                  f"good refused {good_refused} of {sum(good)}")


if __name__ == "__main__":
    main()
