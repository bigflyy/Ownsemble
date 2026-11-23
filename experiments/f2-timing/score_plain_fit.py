"""Plan 10 H2e: score the app's real fits of plain words against a heard truth.

integration_test/lyrics_fit_plain_live_test.dart writes <copy>/plain-live.json
(per song the fitted starts of every line, numbers only) and, local only,
<copy>/plain-live/<index>.json (the lines' words and the stored song file).
A recogniser's transcript of the song's separated vocals (GigaAM for Russian
songs, else Whisper; gigaam-cli --formats json) gives the heard start of each
line whose first words it heard (line_confidence.py's word alignment). This
prints, per song, how many lines were heard and the share of fitted starts
within 1 s of the heard start.

    python -I score_plain_fit.py COPY_DIR ASR_DIR [ASR_DIR ...]

Each ASR_DIR holds <index>-transcript.json or <index>.json files; the first
that has a song is used. Prints only indexes and numbers: no words.
"""

import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import line_confidence as lc  # noqa: E402


def transcript(asr_dirs, index):
    for d in asr_dirs:
        for name in (f"{index}-transcript.json", f"{index}.json"):
            path = d / name
            if path.exists():
                return d.name, json.loads(path.read_text(encoding="utf-8"))
    return None, None


def main():
    copy = Path(sys.argv[1])
    asr_dirs = [Path(a) for a in sys.argv[2:]]
    bench = json.loads((copy / "plain-live.json").read_text(encoding="utf-8"))
    all_err = []
    for row in bench["fitLive"]["songs"]:
        index = row["index"]
        fit = row.get("fit") or {}
        if "starts" not in row:
            print(f"#{index}: no fitted starts ({'fits ' + str(fit.get('fits')) if fit else row.get('skipped', 'not fitted')},"
                  f" sure {fit.get('sure')})")
            continue
        words = json.loads((copy / "plain-live" / f"{index}.json").read_text(encoding="utf-8"))
        lines = words["lines"]
        fitted = row["starts"]["fitted"]
        # The lines with words, as (start, end, text) for the heard matching;
        # the start is not used there.
        sung = [(0.0, 0.0, text) for text in lines]
        which, asr = transcript(asr_dirs, index)
        if asr is None:
            print(f"#{index}: no transcript")
            continue
        heard_words = [w for s in asr["segments"] for w in s.get("words", [])]
        heard = lc.heard_line_starts_nw(sung, heard_words)
        heard = {i: t for i, t in heard.items() if lines[i].strip()}
        if not heard:
            print(f"#{index} vs {which}: no line heard")
            continue
        err = np.array([abs(fitted[i] / 1000 - t) for i, t in heard.items()])
        all_err += list(err)
        with_words = sum(1 for t in lines if t.strip())
        print(f"#{index} vs {which}: {len(heard)} of {with_words} lines heard; fitted within"
              f" 1 s {np.mean(err < 1):.2f}, median error {np.median(err):.2f} s; app sure"
              f" {fit.get('sure', 0):.2f}, fits {fit.get('fits')}")
    if all_err:
        all_err = np.array(all_err)
        print(f"all: {len(all_err)} heard lines, within 1 s {np.mean(all_err < 1):.2f},"
              f" median {np.median(all_err):.2f} s")


if __name__ == "__main__":
    main()
