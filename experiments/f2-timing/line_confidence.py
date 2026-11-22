"""Plan 10 G0b: which of the aligner's retimed lines can be trusted, without a
recogniser in the app?

The aligner (MMS_FA forced alignment, timing_probe.py) gives every lyric line
a start from the audio. On live uploads about a quarter of those starts are
wrong (lines not sung there, changed, repeated, or a wrong match). This script
looks for a per-line signal that the app can compute from the aligner alone
and that separates the good lines from the wrong ones. The truth is the line
start a recogniser heard in the separated vocals (asr_check.py: GigaAM or
Whisper word times); a line is "good" when its aligned start is within 1 s of
the heard one. Lines whose opening words were not heard have no truth and do
not count.

It reads the aligner's cached output (DATA/emission/<index>.npy, written by
timing_probe.py), so no model runs here: forced alignment itself takes
milliseconds.

Per line it measures (all from the aligner):
  score       mean letter probability of the line's letters
  word_min    the lowest word score in the line
  rate        letters per second of the aligned line (squeezed or stretched)
  dur_ratio   aligned length / the lyrics' own line length
  word_gap    the longest pause between two words of the line (s)
  local_dev   how far the line's shift is from the median shift of the 3
              lines before and the 3 after (shifts drift smoothly)
  step_dev    the smaller jump in shift to the line before or after
  star_agree  how far the start moves when a "*" token (any sound, MMS_FA's
              with_star) may absorb the audio between lines
  star_score  the line's mean letter probability in that star alignment

Then it compares ways to use them: trust lines whose signals pass, and give
the other lines the shift of their trusted neighbours (interpolated by time).

    python -I line_confidence.py DATA_DIR:ASR_SUBDIR [DATA_DIR:ASR_SUBDIR ...]
        [--emission emission] [--star -1.0] [--out lines.jsonl]

Prints only indexes, sources and numbers: never words or names.
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import torch
import torchaudio.functional as F

sys.path.insert(0, str(Path(__file__).parent))
import asr_check  # noqa: E402
import timing_probe as tp  # noqa: E402

# MMS_FA's letters; index 0 is the CTC blank. The emission has one column
# per label; a star column, when used, is appended after them.
LABELS = ('-', 'a', 'i', 'e', 'n', 'o', 'u', 't', 's', 'r', 'm', 'k', 'l', 'd',
          'g', 'h', 'y', 'b', 'p', 'w', 'c', 'v', 'j', 'z', 'f', "'", 'q', 'x')
TOKEN = {c: i for i, c in enumerate(LABELS)}

# A line is good when its aligned start is this close to the heard start (s).
GOOD = 1.0

FEATURES = ["score", "word_min", "rate", "dur_ratio", "word_gap",
            "local_dev", "step_dev", "star_agree", "star_score"]


def align_lines(emission, line_words, star_logp=None):
    """Forced alignment of the lines' words to the emission.

    line_words: for every line its list of romanized words (may be empty).
    star_logp: when given, a "*" token sits before every line and after the
    last one; it matches any frame with this log-probability, so audio the
    lyrics do not cover need not be forced onto the words.

    Returns, per line with words, a dict with the frame spans of its words
    (start, end, score) in order; lines without words map to None.
    """
    columns = emission
    star = None
    if star_logp is not None:
        star = emission.shape[1]
        pad = torch.full((emission.shape[0], 1), float(star_logp))
        columns = torch.cat([emission, pad], dim=1)
    targets, owner = [], []
    for line_index, words in enumerate(line_words):
        if not words:
            continue
        if star is not None:
            targets.append(star)
            owner.append(None)
        for word_index, word in enumerate(words):
            for ch in word:
                targets.append(TOKEN[ch])
                owner.append((line_index, word_index))
    if star is not None:
        targets.append(star)
        owner.append(None)
    if not targets:
        return [None] * len(line_words)
    labels, scores = F.forced_align(
        columns.unsqueeze(0), torch.tensor([targets], dtype=torch.int32), blank=0)
    spans = F.merge_tokens(labels[0], scores[0].exp())
    if len(spans) != len(targets):
        raise RuntimeError(f"{len(spans)} spans for {len(targets)} tokens")
    lines = [None] * len(line_words)
    for span, who in zip(spans, owner):
        if who is None:
            continue
        line_index, word_index = who
        if lines[line_index] is None:
            lines[line_index] = {}
        word = lines[line_index].setdefault(word_index, [])
        word.append((span.start, span.end, float(span.score)))
    result = []
    for line in lines:
        if line is None:
            result.append(None)
            continue
        words = []
        for word_index in sorted(line):
            letters = line[word_index]
            words.append((letters[0][0], letters[-1][1],
                          float(np.mean([s for _, _, s in letters])), len(letters)))
        result.append(words)
    return result


def heard_line_starts_nw(sung, asr_words):
    """{line index: heard start (s)} by a global word alignment.

    asr_check.py matches words with difflib, which takes the longest common
    run first: with repeated choruses it can tie a chorus of the lyrics to a
    later repeat in the audio and skip everything between (seen in G0b: a
    studio song whose every line was "heard" 52 s late). Here the lyric words
    and the heard words are aligned as a whole (Needleman-Wunsch: match +2,
    mismatch -1, gap -1), so each repeat meets its own repeat. A line gets
    the heard time of its first or second word only when that word and the
    next one in the line both matched, so a lone common word does not count.
    """
    lyric, owner, place, line_len = [], [], [], {}
    for index, (_, _, text) in enumerate(sung):
        words = asr_check.folded(text)
        line_len[index] = len(words)
        for k, word in enumerate(words):
            lyric.append(word)
            owner.append(index)
            place.append(k)
    heard, times = [], []
    for w in asr_words:
        for word in asr_check.folded(w["text"]):
            heard.append(word)
            times.append(w["start"])
    n, m = len(lyric), len(heard)
    if not n or not m:
        return {}
    match, mismatch, gap = 2, -1, -1
    score = np.zeros((n + 1, m + 1), dtype=np.int32)
    score[:, 0] = np.arange(n + 1) * gap
    score[0, :] = np.arange(m + 1) * gap
    heard_arr = np.array(heard, dtype=object)
    for i in range(1, n + 1):
        same = np.where(heard_arr == lyric[i - 1], match, mismatch)
        diag = score[i - 1, :-1] + same
        up = score[i - 1, 1:] + gap
        best = np.maximum(diag, up)
        row = score[i]
        row[1:] = best
        # Left moves (a heard word with no lyric word) run along the row.
        for j in range(1, m + 1):
            if row[j - 1] + gap > row[j]:
                row[j] = row[j - 1] + gap
    pairs = {}
    i, j = n, m
    while i > 0 and j > 0:
        here = score[i, j]
        if lyric[i - 1] == heard[j - 1] and here == score[i - 1, j - 1] + match:
            pairs[i - 1] = j - 1
            i, j = i - 1, j - 1
        elif here == score[i - 1, j - 1] + mismatch:
            i, j = i - 1, j - 1
        elif here == score[i - 1, j] + gap:
            i -= 1
        else:
            j -= 1
    starts = {}
    for k in range(n):
        if k not in pairs or place[k] > 1 or owner[k] in starts:
            continue
        single = line_len[owner[k]] == 1
        nxt = k + 1
        follows = (nxt < n and owner[nxt] == owner[k] and nxt in pairs
                   and pairs[nxt] == pairs[k] + 1)
        if single or follows:
            starts[owner[k]] = times[pairs[k]]
    return starts


def line_features(sung, line_words, plain, starred, spf):
    """The per-line signals (see the module docstring) for one source.

    Returns {line index: features} for the lines the aligner placed, with
    "start" (aligned, s) and "delta" (aligned - lyrics start) as well."""
    placed = [i for i, words in enumerate(plain) if words]
    rows = {}
    for i in placed:
        words = plain[i]
        start, end = words[0][0] * spf, words[-1][1] * spf
        letters = sum(n for _, _, _, n in words)
        lyric_start = sung[i][0]
        next_start = sung[i + 1][0] if i + 1 < len(sung) else sung[i][1]
        lyric_len = max(next_start - lyric_start, 0.1)
        gaps = [(words[k + 1][0] - words[k][1]) * spf for k in range(len(words) - 1)]
        all_scores = [s for _, _, s, n in words for _ in range(n)]
        row = {
            "start": start,
            "delta": start - lyric_start,
            "score": float(np.mean(all_scores)),
            "word_min": float(min(s for _, _, s, _ in words)),
            "rate": letters / max(end - start, spf),
            "dur_ratio": (end - start) / lyric_len,
            "word_gap": max(gaps) if gaps else 0.0,
        }
        if starred is not None and starred[i]:
            star_start = starred[i][0][0] * spf
            row["star_agree"] = abs(star_start - start)
            row["star_score"] = float(np.mean(
                [s for _, _, s, n in starred[i] for _ in range(n)]))
        rows[i] = row
    deltas = {i: rows[i]["delta"] for i in placed}
    for pos, i in enumerate(placed):
        around = [deltas[placed[k]] for k in range(max(0, pos - 3), min(len(placed), pos + 4))
                  if k != pos]
        rows[i]["local_dev"] = abs(deltas[i] - float(np.median(around))) if around else 0.0
        steps = []
        if pos > 0:
            steps.append(abs(deltas[i] - deltas[placed[pos - 1]]))
        if pos + 1 < len(placed):
            steps.append(abs(deltas[i] - deltas[placed[pos + 1]]))
        rows[i]["step_dev"] = min(steps) if steps else 0.0
    return rows


def auc(values, good):
    """Probability that a random good line has a higher value than a random
    bad one (0.5 = no signal; below 0.5 = the signal works the other way)."""
    values, good = np.asarray(values, float), np.asarray(good, bool)
    if good.all() or not good.any():
        return float("nan")
    order = values.argsort()
    ranks = np.empty(len(values))
    ranks[order] = np.arange(1, len(values) + 1)
    # Ties share their mean rank.
    for v in np.unique(values):
        same = values == v
        if same.sum() > 1:
            ranks[same] = ranks[same].mean()
    n_good, n_bad = good.sum(), (~good).sum()
    return float((ranks[good].sum() - n_good * (n_good + 1) / 2) / (n_good * n_bad))


def fill_untrusted(starts, lyric_starts, trusted):
    """Final line starts: trusted lines keep the aligner's start; the others
    get the lyrics' start moved by the shift of the nearest trusted lines
    (interpolated by lyrics time between the one before and the one after,
    or the nearest one at the ends). No trusted line: the lyrics as they are.
    """
    keys = sorted(starts)
    sure = [k for k in keys if trusted[k]]
    if not sure:
        return {k: lyric_starts[k] for k in keys}
    sure_t = np.array([lyric_starts[k] for k in sure])
    sure_d = np.array([starts[k] - lyric_starts[k] for k in sure])
    out = {}
    for k in keys:
        if trusted[k]:
            out[k] = starts[k]
        else:
            out[k] = lyric_starts[k] + float(np.interp(lyric_starts[k], sure_t, sure_d))
    return out


def load_pairs(data, asr_subdir, emission_subdir, star_logp, truth):
    """Every (song, source) pair with a recogniser transcript: its lines'
    features, heard starts and lyrics starts."""
    results = {}
    results_path = data / "results-43a.jsonl"
    if results_path.exists():
        for line in open(results_path, encoding="utf-8"):
            record = json.loads(line)
            results[record["index"]] = record
    pairs = []
    for path in sorted((data / asr_subdir).glob("*-transcript.json"),
                       key=lambda p: int(p.stem.split("-")[0])):
        index = int(path.stem.split("-")[0])
        em_path = data / emission_subdir / f"{index}.npy"
        if not em_path.exists():
            continue
        asr = json.loads(path.read_text(encoding="utf-8"))
        heard_words = [w for s in asr["segments"] for w in s.get("words", [])]
        seconds = asr.get("audio_seconds") or results.get(index, {}).get("seconds")
        emission = torch.from_numpy(np.load(em_path))
        spf = seconds / emission.shape[0]
        song = json.loads((data / "songs" / f"{index}.json").read_text(encoding="utf-8"))
        for source, lines in song["sources"].items():
            sung = tp.sung_lines(lines)
            if len(sung) < 3:
                continue
            words_kept = tp.romanize(" ".join(t for _, _, t in sung))
            if words_kept[1] < 0.8:
                continue
            line_words = [tp.romanize(t)[0] for _, _, t in sung]
            if truth == "nw":
                heard = heard_line_starts_nw(sung, heard_words)
            else:
                heard, _ = asr_check.heard_line_starts(sung, heard_words)
            if len(heard) < 3:
                continue
            plain = align_lines(emission, line_words)
            starred = (align_lines(emission, line_words, star_logp)
                       if star_logp is not None else None)
            rows = line_features(sung, line_words, plain, starred, spf)
            pairs.append({
                "data": data.name, "index": index, "source": source,
                "rows": rows, "heard": heard,
                "lyric_starts": {i: sung[i][0] for i in rows},
            })
    return pairs


def table(pairs):
    """One row per line with truth: features, label, error."""
    out = []
    for p in pairs:
        for i, row in p["rows"].items():
            if i not in p["heard"]:
                continue
            err = abs(row["start"] - p["heard"][i])
            out.append({**row, "err": err, "good": err < GOOD,
                        "pair": (p["data"], p["index"], p["source"]), "line": i})
    return out


def report_features(rows, name):
    good = [r["good"] for r in rows]
    print(f"\n{name}: {len(rows)} lines, {np.mean(good):.2f} good (aligner start within"
          f" {GOOD:.0f} s of the heard one)")
    for f in FEATURES:
        have = [r for r in rows if f in r]
        if not have:
            continue
        a = auc([r[f] for r in have], [r["good"] for r in have])
        values_good = [r[f] for r in have if r["good"]]
        values_bad = [r[f] for r in have if not r["good"]]
        print(f"  {f:11s} AUC {a:.2f}  median good {np.median(values_good):7.3f}"
              f"  bad {np.median(values_bad) if values_bad else float('nan'):7.3f}")


# The small form for the app: four signals, all cheap in Dart.
SMALL = ["score", "local_dev", "step_dev", "star_agree"]


def model_matrix(rows, small=False):
    """Features for the combined model; signs and logs so that each is
    roughly linear in how likely a line is good."""
    m = []
    for r in rows:
        if small:
            m.append([r["score"], np.log1p(r["local_dev"]), np.log1p(r["step_dev"]),
                      np.log1p(r.get("star_agree", 0.0))])
            continue
        m.append([
            r["score"], r["word_min"], np.log(r["rate"] + 0.1),
            abs(np.log(max(r["dur_ratio"], 0.01))), np.log1p(r["word_gap"]),
            np.log1p(r["local_dev"]), np.log1p(r["step_dev"]),
            np.log1p(r.get("star_agree", 0.0)), r.get("star_score", r["score"]),
        ])
    return np.array(m)


def all_lines(pairs):
    """Every placed line, with or without truth, for applying a verdict."""
    out = []
    for p in pairs:
        for i, row in p["rows"].items():
            out.append({**row, "pair": (p["data"], p["index"], p["source"]), "line": i})
    return out


def combined(train_rows, any_rows, small=False):
    """Logistic regression on all signals, scored out of fold (whole songs
    held out), so the numbers are not fitted to the lines they judge.

    Trained on the lines with truth; returns {(pair, line): probability}
    for every placed line of every song."""
    from sklearn.linear_model import LogisticRegression
    from sklearn.model_selection import GroupKFold
    song = lambda r: f"{r['pair'][0]}/{r['pair'][1]}"
    x = model_matrix(train_rows, small)
    y = np.array([r["good"] for r in train_rows])
    groups = np.array([song(r) for r in train_rows])
    songs = sorted(set(groups))
    folds = {s: k % 5 for k, s in enumerate(songs)}
    x_any = model_matrix(any_rows, small)
    fold_any = np.array([folds.get(song(r), -1) for r in any_rows])
    fold_train = np.array([folds[g] for g in groups])
    prob = {}
    for k in range(5):
        model = LogisticRegression(max_iter=2000).fit(x[fold_train != k], y[fold_train != k])
        pick = fold_any == k
        for r, p in zip([r for r, f in zip(any_rows, pick) if f],
                        model.predict_proba(x_any[pick])[:, 1]):
            prob[(r["pair"], r["line"])] = float(p)
    model = LogisticRegression(max_iter=2000).fit(x, y)
    names = SMALL if small else FEATURES
    print(f"\n{'Small' if small else 'Combined'} model weights (on all lines):",
          " ".join(f"{n}={w:+.3f}" for n, w in zip(names, model.coef_[0])),
          f"bias={model.intercept_[0]:+.2f}")
    return prob


def rule_ok(r):
    """A rule simple enough to write by hand, for comparison."""
    return float(r["local_dev"] < 1.0 and r["score"] >= 0.2)


def precision_recall(rows, conf, name):
    good = np.array([r["good"] for r in rows])
    print(f"  {name}: AUC {auc(conf, good):.2f}")
    for t in (0.3, 0.5, 0.7, 0.8, 0.9):
        keep = conf >= t
        if keep.sum() == 0:
            continue
        print(f"    >= {t:.1f}: keeps {keep.mean():.2f} of lines, {good[keep].mean():.2f} of"
              f" those good, {keep[good].mean():.2f} of the good kept")


def policy(pairs, conf_by, threshold, name):
    """Share of lines within 1 s of the heard start for several ways."""
    totals = {"lyrics": [], "one shift": [], "aligner all": [], name: []}
    for p in pairs:
        key = (p["data"], p["index"], p["source"])
        rows, heard, lyric = p["rows"], p["heard"], p["lyric_starts"]
        starts = {i: rows[i]["start"] for i in rows}
        shift = float(np.median([rows[i]["delta"] for i in rows]))
        trusted = {i: conf_by.get((key, i), 0.0) >= threshold for i in rows}
        final = fill_untrusted(starts, lyric, trusted)
        for i in rows:
            if i not in heard:
                continue
            totals["lyrics"].append(abs(lyric[i] - heard[i]))
            totals["one shift"].append(abs(lyric[i] + shift - heard[i]))
            totals["aligner all"].append(abs(starts[i] - heard[i]))
            totals[name].append(abs(final[i] - heard[i]))
    return {k: (float(np.mean(np.array(v) < GOOD)), float(np.median(v)))
            for k, v in totals.items() if v}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("sets", nargs="+", help="DATA_DIR:ASR_SUBDIR")
    parser.add_argument("--emission", default="emission")
    parser.add_argument("--star", type=float, default=-1.0)
    parser.add_argument("--out", default=None)
    parser.add_argument("--truth", default="nw", choices=["nw", "difflib"])
    args = parser.parse_args()

    by_set = {}
    for item in args.sets:
        data, asr_subdir = item.rsplit(":", 1)
        data = Path(data)
        label = f"{data.name}/{asr_subdir}"
        by_set[label] = load_pairs(data, asr_subdir, args.emission, args.star, args.truth)
        pairs = by_set[label]
        near = [abs(p["heard"][i] - p["lyric_starts"][i]) < 1.5
                for p in pairs for i in p["heard"] if i in p["lyric_starts"]]
        print(f"{label}: {len(pairs)} song+source pairs, truth for {len(near)} lines,"
              f" {np.mean(near):.2f} of them within 1.5 s of the lyrics' own start"
              f" (truth {args.truth}, star {args.star})", flush=True)

    all_rows = []
    for label, pairs in by_set.items():
        rows = table(pairs)
        report_features(rows, label)
        all_rows += [(label, r) for r in rows]

    rows_only = [r for _, r in all_rows]
    any_rows = [r for pairs in by_set.values() for r in all_lines(pairs)]
    prob = combined(rows_only, any_rows)
    small = combined(rows_only, any_rows, small=True)
    rule = {(r["pair"], r["line"]): rule_ok(r) for r in any_rows}
    for label in by_set:
        mine = [r for (lab, r) in all_rows if lab == label]
        precision_recall(mine, np.array([prob[(r["pair"], r["line"])] for r in mine]),
                         f"{label} combined (out of fold)")
        precision_recall(mine, np.array([small[(r["pair"], r["line"])] for r in mine]),
                         f"{label} small (out of fold)")
        precision_recall(mine, np.array([rule[(r["pair"], r["line"])] for r in mine]),
                         f"{label} rule local_dev < 1 s and score >= 0.2")

    print("\nFinal line starts within 1 s of the heard start (share, median error s):")
    for label, pairs in by_set.items():
        for t in (0.5, 0.7):
            res = policy(pairs, prob, t, f"trusted >= {t} + neighbours")
            print(f"  {label} model {t}: " + "; ".join(
                f"{k} {v[0]:.2f} ({v[1]:.2f})" for k, v in res.items()))
        res = policy(pairs, small, 0.7, "small >= 0.7 + neighbours")
        print(f"  {label} small 0.7: " + "; ".join(
            f"{k} {v[0]:.2f} ({v[1]:.2f})" for k, v in res.items()))
        res = policy(pairs, rule, 0.5, "rule + neighbours")
        print(f"  {label} rule: " + "; ".join(
            f"{k} {v[0]:.2f} ({v[1]:.2f})" for k, v in res.items()))

    # Song level: does the share of sure lines tell whether a pair's lyrics
    # fit the recording at all (for "These lyrics do not match")?
    print("\nPer song+source: share of lines the small model trusts (>= 0.7) against"
          " the share of good lines")
    for label, pairs in by_set.items():
        sure, good = [], []
        for p in pairs:
            key = (p["data"], p["index"], p["source"])
            truth_lines = [i for i in p["rows"] if i in p["heard"]]
            if len(truth_lines) < 5:
                continue
            sure.append(np.mean([small[(key, i)] >= 0.7 for i in p["rows"]]))
            good.append(np.mean([abs(p["rows"][i]["start"] - p["heard"][i]) < GOOD
                                 for i in truth_lines]))
        sure, good = np.array(sure), np.array(good)
        for cut in (0.3, 0.5, 0.7):
            low = sure < cut
            print(f"  {label} sure < {cut}: {low.sum()} of {len(sure)} pairs, their good share"
                  f" median {np.median(good[low]) if low.any() else float('nan'):.2f};"
                  f" the rest median {np.median(good[~low]) if (~low).any() else float('nan'):.2f}"
                  f", pairs under 0.5 good among the rest {int(((good < 0.5) & ~low).sum())}")

    if args.out:
        with open(args.out, "w", encoding="utf-8") as out:
            for label, r in all_rows:
                c = prob[(r["pair"], r["line"])]
                out.write(json.dumps({"set": label, "pair": list(r["pair"]), "line": r["line"],
                                      **{k: round(float(v), 4) for k, v in r.items()
                                         if k not in ("pair", "line", "good")},
                                      "good": bool(r["good"]), "conf": round(float(c), 3),
                                      "small": round(small[(r["pair"], r["line"])], 3)})
                          + "\n")


if __name__ == "__main__":
    main()
