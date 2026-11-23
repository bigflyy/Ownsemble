"""Plan 10 H1: fit plain words (lyrics with no times) to the recording.

The aligner (MMS_FA forced alignment) needs only the words, so plain words
get a start per line exactly as timed lyrics do. What G0b's "sure" check
cannot do for them: two of its four signals (local_dev, step_dev) compare
each line's shift against the source's own times, which plain words do not
have. This script looks for a check that needs no source times.

Data: the cached emissions and heard starts of G0b (line_confidence.py),
with the timed lyrics' times dropped, so the truth is known: a line is good
when its fitted start is within 1 s of the start a recogniser heard in the
separated vocals (GigaAM RNNT on the Russian songs; Whisper on the others,
as a second, looser truth). No model runs here.

Per line, signals that need no source times:
  score       mean letter probability of the line's letters
  word_min    the lowest word score in the line
  star_agree  how far the start moves when a "*" token (any sound) may
              absorb the audio between lines (G0b)
  star_score  the line's mean letter probability in that star alignment
  word_gap    the longest pause between two words of the line (s)
  rate_dev    |ln(the line's letters per second / the song's median)|
  pace_one    the line's start against a straight line through the starts
              of the 3 lines before it (or the 3 after it), by letters
              sung: the smaller of the two misses (s); one side may hold a
              break, so the better side counts
  pace_two    the same through the 3 lines on both sides (s)
  between     the start against the place the line's letters give it
              between the line before and the line after (s)
  gap_before  pause from the end of the line before to this start (s)
  gap_after   pause from this end to the next line's start (s)

Then: a logistic model scored out of fold (whole songs held out), unsure
lines placed by letters between sure neighbours, and whether plain words of
another song are told apart by the share of sure lines (each song's words
aligned to another song's recording).

    python -I plain_words.py DATA_DIR [DATA_DIR ...] [--star 0] [--sure 0.7]
        [--small score,star_agree,...] [--out lines.jsonl]

Each DATA_DIR needs emission/, songs/, asr-rnnt/ and asr-whisper/. Prints
only indexes, sources and numbers: never words or names.
"""

import argparse
import json
import math
import sys
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).parent))
import line_confidence as lc  # noqa: E402
import timing_probe as tp  # noqa: E402

GOOD = lc.GOOD

FEATURES = ["score", "word_min", "star_agree", "star_score", "word_gap", "rate_dev",
            "pace_one", "pace_two", "between", "gap_before", "gap_after"]

# Signals that are distances or pauses (seconds or ratios >= 0) enter the
# model as ln(1 + x); probabilities enter as they are.
LOGGED = {"star_agree", "word_gap", "rate_dev", "pace_one", "pace_two", "between",
          "gap_before", "gap_after"}

# G0b's sure formula (needs the source's times): the baseline to compare.
def timed_sure(row):
    z = (1.80 + 5.287 * row["score"] - 1.128 * math.log1p(row["local_dev"])
         - 1.170 * math.log1p(row["step_dev"]) - 2.138 * math.log1p(row["star_agree"]))
    return 1 / (1 + math.exp(-z))


def line_fit(start_list, letters_list):
    """Least-squares start = a + b * letters through the given points;
    None when fewer than 2 points or no spread in letters."""
    if len(start_list) < 2:
        return None
    x, y = np.asarray(letters_list, float), np.asarray(start_list, float)
    if np.ptp(x) == 0:
        return None
    b, a = np.polyfit(x, y, 1)
    return a, b


def plain_features(plain, starred, spf):
    """Per placed line (index into the lyrics), the signals that need no
    source times, plus "start", "end", "letters" and "at" (letters sung
    before the line)."""
    placed = [i for i, words in enumerate(plain) if words]
    rows = {}
    at = 0
    for i in placed:
        words = plain[i]
        start, end = words[0][0] * spf, words[-1][1] * spf
        letters = sum(n for _, _, _, n in words)
        gaps = [(words[k + 1][0] - words[k][1]) * spf for k in range(len(words) - 1)]
        all_scores = [s for _, _, s, n in words for _ in range(n)]
        row = {
            "start": start, "end": end, "letters": letters, "at": at,
            "score": float(np.mean(all_scores)),
            "word_min": float(min(s for _, _, s, _ in words)),
            "word_gap": max(gaps) if gaps else 0.0,
            "rate": letters / max(end - start, spf),
        }
        if starred is not None and starred[i]:
            row["star_agree"] = abs(starred[i][0][0] * spf - start)
            row["star_score"] = float(np.mean(
                [s for _, _, s, n in starred[i] for _ in range(n)]))
        else:
            row["star_agree"], row["star_score"] = 0.0, row["score"]
        rows[i] = row
        at += letters
    song_rate = float(np.median([rows[i]["rate"] for i in placed])) if placed else 1.0
    for pos, i in enumerate(placed):
        r = rows[i]
        r["rate_dev"] = abs(math.log(r["rate"] / song_rate))
        before = placed[max(0, pos - 3):pos]
        after = placed[pos + 1:pos + 4]
        misses = []
        for side in (before, after):
            fit = line_fit([rows[k]["start"] for k in side], [rows[k]["at"] for k in side])
            if fit:
                misses.append(abs(r["start"] - (fit[0] + fit[1] * r["at"])))
        r["pace_one"] = min(misses) if misses else 0.0
        both = before + after
        fit = line_fit([rows[k]["start"] for k in both], [rows[k]["at"] for k in both])
        r["pace_two"] = abs(r["start"] - (fit[0] + fit[1] * r["at"])) if fit else 0.0
        if before and after:
            a, b = rows[before[-1]], rows[after[0]]
            share = (r["at"] - a["at"]) / max(b["at"] - a["at"], 1)
            r["between"] = abs(r["start"] - (a["start"] + share * (b["start"] - a["start"])))
        else:
            r["between"] = 0.0
        r["gap_before"] = max(r["start"] - rows[before[-1]]["end"], 0.0) if before else 0.0
        r["gap_after"] = max(rows[after[0]]["start"] - r["end"], 0.0) if after else 0.0
    return rows


def timed_signals(rows, sung):
    """G0b's two time signals (local_dev, step_dev) from the source's own
    times, only for the baseline."""
    placed = sorted(rows)
    delta = {i: rows[i]["start"] - sung[i][0] for i in placed}
    out = {}
    for pos, i in enumerate(placed):
        around = [delta[placed[k]] for k in range(max(0, pos - 3), min(len(placed), pos + 4))
                  if k != pos]
        steps = []
        if pos > 0:
            steps.append(abs(delta[i] - delta[placed[pos - 1]]))
        if pos + 1 < len(placed):
            steps.append(abs(delta[i] - delta[placed[pos + 1]]))
        out[i] = {"local_dev": abs(delta[i] - float(np.median(around))) if around else 0.0,
                  "step_dev": min(steps) if steps else 0.0}
    return out


def song_lines(data, index):
    """Every usable source of a song: (source, sung lines, line words)."""
    song = json.loads((data / "songs" / f"{index}.json").read_text(encoding="utf-8"))
    out = []
    for source, lines in song["sources"].items():
        sung = tp.sung_lines(lines)
        if len(sung) < 3:
            continue
        if tp.romanize(" ".join(t for _, _, t in sung))[1] < 0.8:
            continue
        out.append((source, sung, [tp.romanize(t)[0] for _, _, t in sung]))
    return out


def seconds_of(data, index, results):
    """The audio's length (s) as the transcript or the F2 results give it."""
    for sub in ("asr-rnnt", "asr-whisper"):
        path = data / sub / f"{index}-transcript.json"
        if path.exists():
            seconds = json.loads(path.read_text(encoding="utf-8")).get("audio_seconds")
            if seconds:
                return seconds
    return results.get(index, {}).get("seconds")


def heard_of(data, sub, index, sung):
    path = data / sub / f"{index}-transcript.json"
    if not path.exists():
        return None
    asr = json.loads(path.read_text(encoding="utf-8"))
    words = [w for s in asr["segments"] for w in s.get("words", [])]
    heard = lc.heard_line_starts_nw(sung, words)
    return heard if len(heard) >= 3 else None


def russian(data):
    path = data / "list-ru.txt"
    if not path.exists():
        return set()
    return {int(Path(line.strip()).stem) for line in open(path) if line.strip()}


def load(data, star):
    """Every (song, source) pair with an emission: its rows and both truths."""
    results = {}
    path = data / "results-43a.jsonl"
    if path.exists():
        for line in open(path, encoding="utf-8"):
            record = json.loads(line)
            results[record["index"]] = record
    ru = russian(data)
    pairs = []
    for em_path in sorted((data / "emission").glob("*.npy"), key=lambda p: int(p.stem)):
        index = int(em_path.stem)
        seconds = seconds_of(data, index, results)
        if not seconds:
            continue
        emission = torch.from_numpy(np.load(em_path))
        spf = seconds / emission.shape[0]
        for source, sung, line_words in song_lines(data, index):
            plain = lc.align_lines(emission, line_words)
            starred = lc.align_lines(emission, line_words, star)
            rows = plain_features(plain, starred, spf)
            if len(rows) < 3:
                continue
            timed = timed_signals(rows, sung)
            for i in rows:
                rows[i].update(timed[i])
                rows[i]["lyric_start"] = sung[i][0]
            pairs.append({
                "data": data.name, "index": index, "source": source, "rows": rows,
                "ru": index in ru, "line_words": line_words, "starts": [t for t, _, _ in sung],
                "rnnt": heard_of(data, "asr-rnnt", index, sung) if index in ru else None,
                "whisper": heard_of(data, "asr-whisper", index, sung),
            })
    return pairs


def matrix(rows, names):
    return np.array([[math.log1p(r[n]) if n in LOGGED else r[n] for n in names] for r in rows])


def labelled(pairs, truth):
    """Lines with a heard start in the given truth: (pair key, line, row, good)."""
    out = []
    for p in pairs:
        heard = p[truth]
        if not heard:
            continue
        key = (p["data"], p["index"], p["source"])
        for i, r in p["rows"].items():
            if i in heard:
                out.append((key, i, r, abs(r["start"] - heard[i]) < GOOD))
    return out


def out_of_fold(train, names, pairs):
    """{(key, line): probability} for every line of every pair, each scored
    by a model that never saw its song (songs without truth: the model
    fitted on all lines); plus that model."""
    from sklearn.linear_model import LogisticRegression
    songs = sorted({f"{k[0]}/{k[1]}" for k, _, _, _ in train})
    fold = {s: n % 5 for n, s in enumerate(songs)}
    folds = np.array([fold[f"{k[0]}/{k[1]}"] for k, _, _, _ in train])
    x = matrix([r for _, _, r, _ in train], names)
    y = np.array([g for _, _, _, g in train])
    fold_models = [LogisticRegression(max_iter=3000).fit(x[folds != f], y[folds != f])
                   for f in range(5)]
    model = LogisticRegression(max_iter=3000).fit(x, y)
    prob = {}
    for p in pairs:
        key = (p["data"], p["index"], p["source"])
        f = fold.get(f"{key[0]}/{key[1]}")
        use = model if f is None else fold_models[f]
        lines = list(p["rows"])
        for i, c in zip(lines, use.predict_proba(matrix([p["rows"][i] for i in lines],
                                                        names))[:, 1]):
            prob[(key, i)] = float(c)
    return prob, model


def apply(model, names, rows):
    return model.predict_proba(matrix(rows, names))[:, 1]


def keep_report(name, conf, good):
    conf, good = np.asarray(conf), np.asarray(good, bool)
    print(f"  {name}: AUC {lc.auc(conf, good):.2f}")
    for t in (0.5, 0.7, 0.8, 0.9):
        keep = conf >= t
        if keep.any():
            print(f"    >= {t:.1f}: keeps {keep.mean():.2f} of lines, {good[keep].mean():.2f}"
                  f" of those good, {keep[good].mean():.2f} of the good kept")


def place_by_letters(rows, sure):
    """Final starts: sure lines keep the aligner's start; an unsure line
    is placed by letters between the sure lines around it (at the ends:
    from the nearest sure line at the song's sure pace). No sure line: the
    aligner's starts as they are."""
    keys = sorted(rows)
    good = [k for k in keys if sure[k]]
    if not good:
        return {k: rows[k]["start"] for k in keys}
    if len(good) >= 2:
        rates = [rows[k]["rate"] for k in good]
        pace = float(np.median(rates))
    else:
        pace = rows[good[0]]["rate"]
    at = np.array([rows[k]["at"] for k in good], float)
    st = np.array([rows[k]["start"] for k in good], float)
    out = {}
    for k in keys:
        r = rows[k]
        if sure[k]:
            out[k] = r["start"]
        elif r["at"] <= at[0]:
            out[k] = st[0] - (at[0] - r["at"]) / pace
        elif r["at"] >= at[-1]:
            last = good[-1]
            out[k] = rows[last]["end"] + (r["at"] - at[-1] - rows[last]["letters"]) / pace
        else:
            out[k] = float(np.interp(r["at"], at, st))
    return out


def place_timed(rows, sure):
    """G0b's way (needs the source's times): unsure lines get the sure
    neighbours' shift, interpolated by lyrics time."""
    starts = {k: r["start"] for k, r in rows.items()}
    lyric = {k: r["lyric_start"] for k, r in rows.items()}
    return lc.fill_untrusted(starts, lyric, sure)


def placement_report(pairs, truth, conf, cut):
    totals = {k: [] for k in ("lyrics' own times", "aligner, every line",
                              "sure lines only", "plain: unsure by letters",
                              "plain: unsure keep aligner", "timed G0b (needs times)")}
    for p in pairs:
        heard = p[truth]
        if not heard:
            continue
        key = (p["data"], p["index"], p["source"])
        rows = p["rows"]
        sure = {i: conf[(key, i)] >= cut for i in rows}
        timed = {i: timed_sure(rows[i]) >= 0.7 for i in rows}
        by_letters = place_by_letters(rows, sure)
        by_times = place_timed(rows, timed)
        for i in rows:
            if i not in heard:
                continue
            h = heard[i]
            totals["lyrics' own times"].append(abs(rows[i]["lyric_start"] - h))
            totals["aligner, every line"].append(abs(rows[i]["start"] - h))
            if sure[i]:
                totals["sure lines only"].append(abs(rows[i]["start"] - h))
            totals["plain: unsure by letters"].append(abs(by_letters[i] - h))
            totals["plain: unsure keep aligner"].append(abs(rows[i]["start"] - h))
            totals["timed G0b (needs times)"].append(abs(by_times[i] - h))
    for k, v in totals.items():
        if v:
            v = np.array(v)
            print(f"    {k:28s} {np.mean(v < GOOD):.2f} within 1 s (median {np.median(v):.2f} s,"
                  f" {len(v)} lines)")
    unsure_letters, unsure_aligner = [], []
    for p in pairs:
        heard = p[truth]
        if not heard:
            continue
        key = (p["data"], p["index"], p["source"])
        sure = {i: conf[(key, i)] >= cut for i in p["rows"]}
        by_letters = place_by_letters(p["rows"], sure)
        for i in p["rows"]:
            if i in heard and not sure[i]:
                unsure_letters.append(abs(by_letters[i] - heard[i]) < GOOD)
                unsure_aligner.append(abs(p["rows"][i]["start"] - heard[i]) < GOOD)
    if unsure_letters:
        print(f"    unsure lines only ({len(unsure_letters)}): by letters"
              f" {np.mean(unsure_letters):.2f}, aligner's own {np.mean(unsure_aligner):.2f}")


def shuffled(line_words, seed):
    """The same lines in another order (the null: the song's own letters,
    not in the order sung)."""
    order = np.random.default_rng(seed).permutation(len(line_words))
    return [line_words[k] for k in order]


def song_stats(emission, spf, line_words, model, names, star, cut, starts=None):
    """Sure share and mean letter score of the words on a recording; with
    the lyrics' own starts also G0b's timed sure share."""
    plain = lc.align_lines(emission, line_words)
    starred = lc.align_lines(emission, line_words, star)
    rows = plain_features(plain, starred, spf)
    if len(rows) < 3:
        return None
    out = {"sure": float(np.mean(apply(model, names, list(rows.values())) >= cut)),
           "score": float(np.mean([r["score"] for r in rows.values()]))}
    if starts is not None:
        timed = timed_signals(rows, [(t, 0, "") for t in starts])
        out["timed"] = float(np.mean([timed_sure({**rows[i], **timed[i]}) >= 0.7
                                      for i in rows]))
    return out


def wrong_song(pairs, model, names, star, cut, shift=7, shuffles=3):
    """Each pair's words on its own recording and on another song's of the
    same set (skipping one that shares many words: a second upload of the
    same song), each as sung and with the lines shuffled."""
    by_data = {}
    for p in pairs:
        by_data.setdefault(p["data"], []).append(p)
    out = []
    for mine in by_data.values():
        indexes = sorted({p["index"] for p in mine})
        words_of = {}
        for p in mine:
            words_of.setdefault(p["index"], set()).update(w for ln in p["line_words"] for w in ln)
        for p in mine:
            own_words = {w for ln in p["line_words"] for w in ln}
            pos = indexes.index(p["index"])
            other = None
            for step in range(shift, shift + len(indexes)):
                cand = indexes[(pos + step) % len(indexes)]
                if cand == p["index"]:
                    continue
                union = own_words | words_of[cand]
                if len(own_words & words_of[cand]) / max(len(union), 1) < 0.3:
                    other = cand
                    break
            if other is None:
                continue
            row = {"pair": (p["data"], p["index"], p["source"]), "good": p.get("good_share")}
            for label, index in (("own", p["index"]), ("other", other)):
                seconds = p["other_seconds"](index)
                if not seconds:
                    break
                em = torch.from_numpy(np.load(Path(p["dir"]) / "emission" / f"{index}.npy"))
                spf = seconds / em.shape[0]
                as_sung = song_stats(em, spf, p["line_words"], model, names, star, cut,
                                     p["starts"])
                nulls = [song_stats(em, spf, shuffled(p["line_words"], 1000 * p["index"] + k),
                                    model, names, star, cut) for k in range(shuffles)]
                nulls = [n for n in nulls if n]
                if not as_sung or not nulls:
                    break
                row[label] = as_sung
                row[label + "_null"] = {k: float(np.mean([n[k] for n in nulls]))
                                        for k in ("sure", "score")}
            else:
                out.append(row)
    return out


def wrong_report(rows):
    """How well each song-level rule tells the words of the song from the
    words of another song."""
    q = lambda v: " ".join(f"{x:.2f}" for x in np.quantile(v, [0.05, 0.25, 0.5, 0.75, 0.95]))
    fit = [r for r in rows if r["good"] is not None and r["good"] >= 0.7]
    rules = {
        "sure share (plain)": lambda c: c["sure"],
        "timed G0b sure share": lambda c: c["timed"],
        "mean letter score": lambda c: c["score"],
        "sure - shuffled sure": lambda c: c["sure"] - c["null"]["sure"],
        "score - shuffled score": lambda c: c["score"] - c["null"]["score"],
        "score / shuffled score": lambda c: c["score"] / max(c["null"]["score"], 1e-6),
    }
    print(f"  {len(rows)} pairs, {len(fit)} of them with GigaAM truth and >= 70% of lines right")
    for name, value in rules.items():
        real = np.array([value({**r["own"], "null": r["own_null"]}) for r in rows])
        wrong = np.array([value({**r["other"], "null": r["other_null"]}) for r in rows])
        real_fit = np.array([value({**r["own"], "null": r["own_null"]}) for r in fit])
        print(f"  {name}: quantiles 5/25/50/75/95% real {q(real)}; wrong {q(wrong)}")
        for share in (0.10, 0.05, 0.02, 0.0):
            c = float(np.quantile(wrong, 1 - share))
            print(f"    cut {c:.3f} (lets {share:.0%} of wrong pass): real failing"
                  f" {np.mean(real <= c):.2f}, fitting pairs failing {np.mean(real_fit <= c):.2f}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("dirs", nargs="+")
    parser.add_argument("--star", type=float, default=0.0)
    parser.add_argument("--sure", type=float, default=0.7)
    parser.add_argument("--small", default="score,star_agree,pace_one,rate_dev")
    parser.add_argument("--out", default=None)
    args = parser.parse_args()
    torch.set_num_threads(2)

    pairs = []
    for d in args.dirs:
        data = Path(d)
        results = {}
        path = data / "results-43a.jsonl"
        if path.exists():
            for line in open(path, encoding="utf-8"):
                rec = json.loads(line)
                results[rec["index"]] = rec
        mine = load(data, args.star)
        for p in mine:
            p["dir"] = str(data)
            p["other_seconds"] = lambda i, data=data, results=results: seconds_of(data, i, results)
        n_rnnt = sum(1 for p in mine if p["rnnt"])
        n_wh = sum(1 for p in mine if p["whisper"] and not p["ru"])
        print(f"{data.name}: {len(mine)} song+source pairs; GigaAM truth {n_rnnt},"
              f" Whisper truth (non-Russian) {n_wh}", flush=True)
        pairs += mine

    train = labelled(pairs, "rnnt")
    print(f"\nGigaAM-labelled lines: {len(train)}, {np.mean([g for *_, g in train]):.2f} good"
          " (aligner start within 1 s of the heard one)")
    for set_name in sorted({k[0] for k, *_ in train}):
        mine = [(r, g) for k, _, r, g in train if k[0] == set_name]
        print(f"\n{set_name}: signal AUC (0.5 = none), median good / bad")
        for f in FEATURES + ["local_dev", "step_dev"]:
            vals = [r[f] for r, _ in mine]
            good = [g for _, g in mine]
            a = lc.auc([-v if f in LOGGED or f in ("local_dev", "step_dev") else v
                        for v in vals], good)
            vg = [r[f] for r, g in mine if g]
            vb = [r[f] for r, g in mine if not g]
            tag = "  (needs the source's times)" if f in ("local_dev", "step_dev") else ""
            print(f"  {f:11s} AUC {a:.2f}  good {np.median(vg):7.3f}  bad {np.median(vb):7.3f}{tag}")

    small = [s for s in args.small.split(",") if s]
    models = {}
    conf_by = {}
    for label, names in (("all signals", FEATURES), (f"small ({', '.join(small)})", small)):
        prob, model = out_of_fold(train, names, pairs)
        models[label] = (model, names)
        conf_by[label] = prob
        print(f"\nModel {label}, fitted on all GigaAM lines:",
              " ".join(f"{n}={w:+.3f}" for n, w in zip(names, model.coef_[0])),
              f"bias={model.intercept_[0]:+.3f}")
        for set_name in sorted({k[0] for k, *_ in train}):
            mine = [(prob[(k, i)], g) for k, i, _, g in train if k[0] == set_name]
            keep_report(f"{set_name} out of fold", [c for c, _ in mine], [g for _, g in mine])
    print("\nG0b timed check (needs the source's times), for comparison:")
    for set_name in sorted({k[0] for k, *_ in train}):
        mine = [(timed_sure(r), g) for k, _, r, g in train if k[0] == set_name]
        keep_report(f"{set_name}", [c for c, _ in mine], [g for _, g in mine])

    # Whisper on the non-Russian songs: the models unchanged (not fitted to them).
    print("\nCarried over unchanged: Whisper truth, non-Russian songs")
    whisper_pairs = [p for p in pairs if not p["ru"]]
    wl = labelled(whisper_pairs, "whisper")
    for label, (model, names) in models.items():
        for set_name in sorted({k[0] for k, *_ in wl}):
            mine = [(r, g) for k, _, r, g in wl if k[0] == set_name]
            keep_report(f"{set_name} {label}", apply(model, names, [r for r, _ in mine]),
                        [g for _, g in mine])
    for set_name in sorted({k[0] for k, *_ in wl}):
        mine = [(timed_sure(r), g) for k, _, r, g in wl if k[0] == set_name]
        keep_report(f"{set_name} G0b timed", [c for c, _ in mine], [g for _, g in mine])

    small_label = list(models)[1]
    small_model, small_names = models[small_label]
    print(f"\nFinal starts within 1 s of the heard start, small model >= {args.sure}:")
    for set_name in sorted({p["data"] for p in pairs}):
        mine = [p for p in pairs if p["data"] == set_name and p["rnnt"]]
        print(f"  {set_name}, GigaAM truth (out of fold):")
        placement_report(mine, "rnnt", conf_by[small_label], args.sure)
        other = [p for p in pairs if p["data"] == set_name and not p["ru"] and p["whisper"]]
        conf = {}
        for p in other:
            key = (p["data"], p["index"], p["source"])
            for i, c in zip(p["rows"], apply(small_model, small_names, list(p["rows"].values()))):
                conf[(key, i)] = float(c)
        print(f"  {set_name}, Whisper truth, non-Russian (model unchanged):")
        placement_report(other, "whisper", conf, args.sure)

    print(f"\nPer song+source: share of sure lines (small >= {args.sure}) against the share"
          " of good lines (GigaAM)")
    for set_name in sorted({p["data"] for p in pairs}):
        sure, good = [], []
        for p in pairs:
            if p["data"] != set_name or not p["rnnt"]:
                continue
            key = (p["data"], p["index"], p["source"])
            truth = [i for i in p["rows"] if i in p["rnnt"]]
            if len(truth) < 5:
                continue
            sure.append(np.mean([conf_by[small_label][(key, i)] >= args.sure
                                 for i in p["rows"] if (key, i) in conf_by[small_label]]))
            good.append(np.mean([abs(p["rows"][i]["start"] - p["rnnt"][i]) < GOOD
                                 for i in truth]))
        sure, good = np.array(sure), np.array(good)
        for cut in (0.3, 0.5, 0.7):
            low = sure < cut
            print(f"  {set_name} sure < {cut}: {low.sum()} of {len(sure)} pairs, good share median"
                  f" {np.median(good[low]) if low.any() else float('nan'):.2f}; the rest"
                  f" {np.median(good[~low]) if (~low).any() else float('nan'):.2f}, pairs under 0.5"
                  f" good among the rest {int(((good < 0.5) & ~low).sum())}")

    for p in pairs:
        if p["rnnt"]:
            truth = [i for i in p["rows"] if i in p["rnnt"]]
            if len(truth) >= 5:
                p["good_share"] = float(np.mean(
                    [abs(p["rows"][i]["start"] - p["rnnt"][i]) < GOOD for i in truth]))
    print("\nWords of another song aligned to the recording (small model, fitted on all;"
          f" sure >= {args.sure}):")
    wrong_rows = wrong_song(pairs, small_model, small_names, args.star, args.sure)
    wrong_report(wrong_rows)
    if args.out:
        with open(Path(args.out).with_suffix(".pairs.json"), "w", encoding="utf-8") as out:
            json.dump([{**r, "pair": list(r["pair"])} for r in wrong_rows], out)

    if args.out:
        with open(args.out, "w", encoding="utf-8") as out:
            for k, i, r, g in train:
                out.write(json.dumps({"pair": list(k), "line": i, "good": bool(g),
                                      "small": round(conf_by[small_label][(k, i)], 3),
                                      **{f: round(float(r[f]), 4) for f in FEATURES}}) + "\n")


if __name__ == "__main__":
    main()
