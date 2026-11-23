"""Plan 10 G4: score the release app's real fits against the heard truth.

The app's bench part fitLive (app/lib/bench/speed_bench.dart) writes, per
song, the source's line starts, the fitted starts and which lines are gaps
(numbers only). This script finds the research song with the same source
starts (so the same lyrics), takes the heard line starts (line_confidence.py's
word alignment of a recogniser's words: GigaAM for Russian songs, Whisper
for the others) and prints, per song, the share of lines within 1 s of the
heard start, for the lyrics as they come and for the app's fit.

    python -I score_bench_fit.py BENCH.json KEY=DATA_DIR:INDEX ...

KEY is the song's library key in the bench; DATA_DIR the research folder
(f2-live or f2-timing); INDEX its research number. Prints only numbers.
"""

import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import line_confidence as lc  # noqa: E402
import timing_probe as tp  # noqa: E402


def heard_starts(data, index, sung):
    """{sung line index: heard start (s)} from GigaAM, else Whisper."""
    for subdir in ("asr-rnnt", "asr-whisper"):
        path = data / subdir / f"{index}-transcript.json"
        if path.exists():
            asr = json.loads(path.read_text(encoding="utf-8"))
            words = [w for s in asr["segments"] for w in s.get("words", [])]
            return subdir, lc.heard_line_starts_nw(sung, words)
    return None, {}


def main():
    bench = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    places = {}
    for item in sys.argv[2:]:
        key, rest = item.split("=", 1)
        data, index = rest.rsplit(":", 1)
        places[key] = (Path(data), int(index))
    for row in bench["fitLive"]["songs"]:
        key = row["key"]
        if key not in places or "starts" not in row:
            print(f"{key}: no fitted starts")
            continue
        data, index = places[key]
        starts = row["starts"]
        app_source = [s for s, gap in zip(starts["source"], starts["gap"]) if not gap]
        app_fitted = [s for s, gap in zip(starts["fitted"], starts["gap"]) if not gap]
        song = json.loads((data / "songs" / f"{index}.json").read_text(encoding="utf-8"))
        match = None
        for source, lines in song["sources"].items():
            sung = tp.sung_lines(lines)
            if [round(s * 1000) for s, _, _ in sung] == app_source:
                match = (source, sung)
                break
        if match is None:
            print(f"#{index} {data.name}: the app's lyrics are not a research source "
                  f"({len(app_source)} lines)")
            continue
        source, sung = match
        subdir, heard = heard_starts(data, index, sung)
        errs_lyrics = [abs(sung[i][0] - heard[i]) for i in heard]
        errs_fit = [abs(app_fitted[i] / 1000 - heard[i]) for i in heard]
        print(f"#{index} {data.name} {source} vs {subdir}: {len(heard)} of {len(sung)} "
              f"lines heard; within 1 s: lyrics {np.mean(np.array(errs_lyrics) < 1):.2f}, "
              f"fit {np.mean(np.array(errs_fit) < 1):.2f}; median error lyrics "
              f"{np.median(errs_lyrics):.2f} s, fit {np.median(errs_fit):.2f} s")


if __name__ == "__main__":
    main()
