"""Plan 10 I2e: does Whisper's per-chunk language guess write chunks in the
wrong script on the songs it would get (not Russian)?

For each song with a Whisper transcript in ASR_DIR (gigaam-cli JSON) and
truth lyrics in DATA_DIR/songs, every segment's script is taken from its
letters (Cyrillic, Latin, CJK, Hangul, Kana, other). A segment is a flip
when its script is not the song's main heard script. A flip is "wrong" when
the lyrics hold almost none of that script (under 5% of their letters):
the song is not sung in it, so Whisper wrote the wrong language there.
Prints numbers only, no words.

    python -I stt_flips.py DATA_DIR ASR_DIR
"""

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import stt_accuracy as acc  # noqa: E402


def script_of(ch):
    code = ord(ch)
    if 0x0400 <= code <= 0x04FF:
        return "cyr"
    if ch.isascii() or 0x00C0 <= code <= 0x024F:
        return "lat"
    if 0x3040 <= code <= 0x30FF:
        return "kana"
    if 0xAC00 <= code <= 0xD7AF or 0x1100 <= code <= 0x11FF:
        return "hangul"
    if 0x4E00 <= code <= 0x9FFF:
        return "cjk"
    return "other"


def scripts(text):
    return Counter(script_of(ch) for ch in text if ch.isalpha())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("data_dir")
    parser.add_argument("asr_dir")
    args = parser.parse_args()
    songs = {}
    for path in sorted(Path(args.data_dir, "songs").glob("*.json")):
        song = json.loads(path.read_text(encoding="utf-8"))
        songs[path.stem.split("-")[0]] = song
    totals = Counter()
    for path in sorted(Path(args.asr_dir).glob("*-transcript.json")):
        index = path.stem.split("-")[0]
        song = songs.get(index)
        truth = acc.lyric_text(song) if song else None
        if not truth:
            continue
        russian = acc.is_cyrillic(truth)
        group = "ru" if russian else "other"
        transcript = json.loads(path.read_text(encoding="utf-8"))
        segments = transcript.get("segments") or []
        heard = Counter()
        seg_scripts = []
        for segment in segments:
            counts = scripts(segment.get("text", ""))
            if not counts:
                continue
            main_script = counts.most_common(1)[0][0]
            letters = sum(counts.values())
            seg_scripts.append((main_script, letters,
                                segment["end"] - segment["start"]))
            heard[main_script] += letters
        if not seg_scripts:
            continue
        song_script = heard.most_common(1)[0][0]
        truth_counts = scripts(truth)
        truth_letters = sum(truth_counts.values()) or 1
        flips = [s for s in seg_scripts if s[0] != song_script]
        wrong = [s for s in flips if truth_counts[s[0]] / truth_letters < 0.05]
        totals[f"{group} songs"] += 1
        totals[f"{group} segments"] += len(seg_scripts)
        totals[f"{group} flip segments"] += len(flips)
        totals[f"{group} wrong-script segments"] += len(wrong)
        if flips:
            totals[f"{group} songs with a flip"] += 1
        if wrong:
            totals[f"{group} songs with a wrong-script flip"] += 1
            print(f"#{index} {group}: main {song_script}, "
                  f"{len(wrong)} of {len(seg_scripts)} segments wrong "
                  f"({', '.join(sorted({s[0] for s in wrong}))}; "
                  f"{sum(s[2] for s in wrong):.0f} s), "
                  f"truth {dict(truth_counts.most_common(3))}")
    for key in sorted(totals):
        print(f"{key}: {totals[key]}")


if __name__ == "__main__":
    main()
