"""Totals for timing_probe.py's results (plan 10 F2).

    python -I summarize.py RESULTS.jsonl [--truth]

For every method: how many song+source pairs it judged, and how many of its
suggested offsets were near 0 (studio songs, whose lyrics are mostly right,
should get about 0) or far from it. --truth (live uploads) compares the
studio lyrics' suggested offset with the live lyrics' own timing instead.
Prints numbers only.
"""

import json
import sys

import numpy as np


def share(values, test):
    return f"{sum(1 for v in values if test(v))}/{len(values)}"


def describe(name, offsets):
    offsets = [o for o in offsets if o is not None]
    if not offsets:
        print(f"{name}: none")
        return
    a = np.abs(offsets)
    print(f"{name}: n={len(offsets)} |off|<0.3 {share(a, lambda v: v < 0.3)}"
          f" <0.5 {share(a, lambda v: v < 0.5)} <1 {share(a, lambda v: v < 1)}"
          f" >2 {share(a, lambda v: v > 2)} median|off| {np.median(a):.2f}")


def main():
    path = sys.argv[1]
    records = [json.loads(l) for l in open(path, encoding="utf-8")]
    pairs = [(r, s, v) for r in records for s, v in r["sources"].items()]
    studio = [(r, s, v) for r, s, v in pairs if s != "truth"]
    print(f"songs {len(records)}, song+source pairs {len(studio)}")
    describe("vad-first", [v.get("vad_first") for _, _, v in studio])
    describe("vad-corr", [v["vad_corr"][0] for _, _, v in studio if "vad_corr" in v])
    describe("ctc-corr", [v["ctc_corr"][0] for _, _, v in studio if "ctc_corr" in v])
    aligned = [(r, s, v["align"]) for r, s, v in studio
               if isinstance(v.get("align"), dict) and "offset" in v["align"]]
    skipped = [v["align"]["skipped"] for _, _, v in studio
               if isinstance(v.get("align"), dict) and "skipped" in v["align"]]
    print(f"align skipped (other letters): {len(skipped)}")
    describe("align (all)", [a["offset"] for _, _, a in aligned])
    for cut in (0.5, 0.6, 0.7, 0.8):
        sure = [a for _, _, a in aligned if a["within_1s"] >= cut]
        describe(f"align within_1s>={cut}", [a["offset"] for a in sure])
    describe("align head (first 60 s)", [a.get("head_offset") for _, _, a in aligned])
    agree = [abs(a["head_offset"] - a["offset"]) for _, _, a in aligned
             if a.get("head_offset") is not None]
    if agree:
        print(f"head vs full |diff|<0.3 {share(agree, lambda v: v < 0.3)}"
              f" <1 {share(agree, lambda v: v < 1)}")
    spreads = [a["spread"] for _, _, a in aligned]
    within = [a["within_1s"] for _, _, a in aligned]
    print(f"align spread (median |line - offset|): median {np.median(spreads):.2f},"
          f" p90 {np.percentile(spreads, 90):.2f}")
    print(f"align within_1s: median {np.median(within):.2f},"
          f" <0.5 {share(within, lambda v: v < 0.5)}")
    # Line by line: how far each aligned line start is from the lyrics'
    # start, over the pairs the aligner is sure of.
    lines = [abs(d) for _, _, a in aligned if a["within_1s"] >= 0.6 for d in a["deltas"]]
    if lines:
        l = np.array(lines)
        print(f"lines (sure pairs): n={len(l)} |d|<0.3 {np.mean(l < 0.3):.2f}"
              f" <0.5 {np.mean(l < 0.5):.2f} <1 {np.mean(l < 1):.2f}"
              f" median {np.median(l):.2f}")
    print("far or unsure pairs (index source offset spread within score):")
    for r, s, a in aligned:
        if abs(a["offset"]) >= 0.5 or a["within_1s"] < 0.6:
            print(f"  #{r['index']} {s} {a['offset']} {a['spread']} {a['within_1s']} {a['score']}")
    secs = sum(r["seconds"] for r in records if r.get("emission_ms"))
    ms = sum(r["emission_ms"] for r in records)
    if secs:
        print(f"model time: {ms / 1000 / secs:.3f} s per audio second")
    if "--truth" in sys.argv:
        print("live uploads with their own LRCLIB timing:")
        for r in records:
            t = r["sources"].get("truth")
            if not t or not isinstance(t.get("align"), dict):
                continue
            for s, v in r["sources"].items():
                a = v.get("align") or {}
                print(f"  #{r['index']} {s} align {a.get('offset')} within {a.get('within_1s')}"
                      f" head {a.get('head_offset')} vad_first {v.get('vad_first')}")


if __name__ == "__main__":
    main()
