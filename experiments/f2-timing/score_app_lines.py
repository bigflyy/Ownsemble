"""Plan 10 G1: score the app's whole fitting path against the heard truth.

app/tool/check_emission.dart --mpv --out writes, for every line, the start
the app's path gives (libmpv decode, int8 ONNX in Dart, Dart aligner) and
the start the research baseline gives (fp32 PyTorch output, same Dart
aligner), each with its sure value and its final start (unsure lines moved
by their sure neighbours). This script takes the heard line starts
(line_confidence.py's word alignment of a recogniser's words) and prints,
for both, the share of lines within 1 s of the heard start.

    python -I score_app_lines.py DATA_DIR ASR_SUBDIR APP_LINES.jsonl

Prints only numbers.
"""

import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import line_confidence as lc  # noqa: E402
import timing_probe as tp  # noqa: E402


def main():
    data, asr_subdir, rows_path = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
    by_pair = {}
    for line in open(rows_path, encoding="utf-8"):
        row = json.loads(line)
        by_pair.setdefault((row["index"], row["source"]), []).append(row)
    err = {k: [] for k in ("lyrics", "app_start", "app_final", "research_start",
                           "research_final")}
    kept = {"app": [], "research": []}
    for (index, source), rows in sorted(by_pair.items()):
        asr = json.loads((data / asr_subdir / f"{index}-transcript.json")
                         .read_text(encoding="utf-8"))
        words = [w for s in asr["segments"] for w in s.get("words", [])]
        song = json.loads((data / "songs" / f"{index}.json").read_text(encoding="utf-8"))
        sung = tp.sung_lines(song["sources"][source])
        if tp.romanize(" ".join(t for _, _, t in sung))[1] < 0.8:
            continue
        heard = lc.heard_line_starts_nw(sung, words)
        if len(heard) < 3:
            continue
        for row in rows:
            i = row["line"]
            if i not in heard:
                continue
            err["lyrics"].append(abs(sung[i][0] - heard[i]))
            for key in ("app_start", "app_final", "research_start", "research_final"):
                err[key].append(abs(row[key] - heard[i]))
            for who in ("app", "research"):
                good = abs(row[f"{who}_start"] - heard[i]) < 1
                kept[who].append((row[f"{who}_sure"] >= 0.7, good))
    print(f"{data.name}: {len(err['lyrics'])} lines with a heard start")
    for key, values in err.items():
        v = np.array(values)
        print(f"  {key:15s} within 1 s {np.mean(v < 1):.3f}  median {np.median(v):.2f} s")
    for who, pairs in kept.items():
        sure = np.array([s for s, _ in pairs])
        good = np.array([g for _, g in pairs])
        print(f"  {who} sure >= 0.7 keeps {sure.mean():.2f} of lines, {good[sure].mean():.3f}"
              f" of those right")


if __name__ == "__main__":
    main()
