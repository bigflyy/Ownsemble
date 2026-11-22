"""Plan 10 F2: can this PC find, from the audio alone, how far a song's timed
lyrics are off?

Reads the folder written by app/tool/probe_lyrics_timing.dart
(songs/<index>.json with every timed source's lines, audio/<index>.mp3) and
measures, per song and per source, the offset each method suggests. The
lyrics' own times are the reference: for studio songs they are mostly right,
so a good method suggests about 0 s there and something large only where the
lines really are off.

Methods:
  vad-first  Silero VAD (a 2 MB speech detector): the first second of steady
             voice minus the first sung line.
  vad-corr   The VAD's voice curve against the lines' "someone sings now"
             curve: the shift (-30..+30 s) where the two match best.
  ctc-corr   The same search, with the voice curve taken from the aligner
             model below (1 - its "no letter" probability).
  align      MMS_FA forced alignment (torchaudio, wav2vec2 300M, 1.2 GB): the
             words are placed on the audio, each line gets a start, and the
             median of (aligned start - lyrics start) is the offset.

    python -I timing_probe.py DATA_DIR OUT.jsonl [--only 0,1] [--no-align]

Prints only indexes, sources, numbers and timings: never words or names.
"""

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

SAMPLE_RATE = 16000
# The voice curves are compared at this step (seconds).
STEP = 0.1
# The farthest shift the correlation search tries, either way (seconds).
MAX_SHIFT = 30.0

# Cyrillic to Latin for the aligner, which knows only a-z and the apostrophe.
CYRILLIC = {
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "yo",
    "ж": "zh", "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m",
    "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
    "ф": "f", "х": "h", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "sch",
    "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
    "і": "i", "ї": "yi", "є": "ye", "ґ": "g",
}


def decode(mp3_path):
    """Decodes an MP3 to 16 kHz mono float32 samples with ffmpeg."""
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(mp3_path), "-ac", "1",
         "-ar", str(SAMPLE_RATE), "-f", "f32le", "-"],
        check=True, capture_output=True,
    ).stdout
    return np.frombuffer(raw, dtype=np.float32).copy()


def sung_lines(lines):
    """The lines with words and a start, as (start_s, end_s, text).

    LRCLIB and NetEase give only starts: a line ends where the next begins,
    but at most 8 s later, so a long instrumental after it does not count as
    singing.
    """
    timed = [l for l in lines if "s" in l]
    result = []
    for i, line in enumerate(timed):
        start = line["s"] / 1000
        following = timed[i + 1]["s"] / 1000 if i + 1 < len(timed) else start + 8
        end = line["e"] / 1000 if "e" in line else following
        end = min(end, following, start + 8)
        if line["t"].strip() and end > start:
            result.append((start, end, line["t"]))
    return result


def lines_curve(sung, frames):
    """1 where some line is being sung, 0 elsewhere, at STEP."""
    curve = np.zeros(frames, dtype=np.float32)
    for start, end, _ in sung:
        a, b = int(start / STEP), int(end / STEP)
        curve[max(a, 0):max(min(b, frames), 0)] = 1
    return curve


def best_shift(voice, lines):
    """The shift (s) of the lines that best matches the voice curve.

    Returns (shift, score, margin): Pearson correlation at the best shift
    and how much it beats the best shift more than 2 s away (a small margin
    means the answer is not trustworthy).
    """
    n = len(voice)
    span = int(MAX_SHIFT / STEP)
    scores = []
    for k in range(-span, span + 1):
        shifted = np.zeros(n, dtype=np.float32)
        if k >= 0:
            shifted[k:] = lines[: n - k]
        else:
            shifted[:k] = lines[-k:]
        if shifted.std() == 0:
            scores.append(-1.0)
            continue
        scores.append(float(np.corrcoef(voice, shifted)[0, 1]))
    scores = np.array(scores)
    best = int(scores.argmax())
    far = [s for i, s in enumerate(scores) if abs(i - best) * STEP > 2]
    margin = float(scores[best] - max(far)) if far else 0.0
    return (best - span) * STEP, float(scores[best]), margin


def to_steps(values, seconds_per_value, frames):
    """Averages a per-frame curve into STEP bins."""
    times = np.arange(len(values)) * seconds_per_value
    bins = (times / STEP).astype(int)
    out = np.zeros(frames, dtype=np.float32)
    counts = np.zeros(frames, dtype=np.float32)
    keep = bins < frames
    np.add.at(out, bins[keep], values[keep])
    np.add.at(counts, bins[keep], 1)
    return out / np.maximum(counts, 1)


class Vad:
    """Silero VAD (ONNX, the form an app could ship): voice probability
    every 32 ms."""

    def __init__(self):
        from silero_vad import load_silero_vad
        self.model = load_silero_vad(onnx=True)

    def probabilities(self, samples):
        import torch
        probs = self.model.audio_forward(torch.from_numpy(samples), SAMPLE_RATE)
        return probs.squeeze(0).numpy(), 512 / SAMPLE_RATE


def first_voice(probs, seconds_per_value, threshold=0.5, hold=1.0):
    """The start (s) of the first stretch of `hold` s with voice above
    `threshold`, or None."""
    need = int(hold / seconds_per_value)
    run = 0
    for i, p in enumerate(probs):
        run = run + 1 if p > threshold else 0
        if run >= need:
            return (i - need + 1) * seconds_per_value
    return None


def romanize(text):
    """Lowercase words in a-z and ', for the aligner; other letters drop.

    Returns (words, kept share of letters)."""
    letters = kept = 0
    out = []
    for ch in text.lower():
        if ch.isalpha():
            letters += 1
            if "a" <= ch <= "z":
                out.append(ch)
                kept += 1
            elif ch in CYRILLIC:
                out.append(CYRILLIC[ch])
                kept += 1
            else:
                out.append(" ")
        elif ch in "'\u2019":
            out.append("'")
        else:
            out.append(" ")
    words = [w.strip("'") for w in "".join(out).split()]
    return [w for w in words if w], (kept / letters if letters else 0.0)


class Aligner:
    """MMS_FA forced alignment of the words to the audio."""

    def __init__(self, threads):
        import torch
        import torchaudio
        torch.set_num_threads(threads)
        bundle = torchaudio.pipelines.MMS_FA
        self.torch = torch
        self.model = bundle.get_model(with_star=False).eval()
        self.tokenizer = bundle.get_tokenizer()
        self.aligner = bundle.get_aligner()

    def emission(self, samples, chunk_s=20, context_s=1):
        """Log-probabilities per 20 ms frame, in chunks (the model's
        attention cannot take a whole song at once), each chunk with 1 s of
        context on both sides that is cut away again."""
        torch = self.torch
        chunk, ctx = chunk_s * SAMPLE_RATE, context_s * SAMPLE_RATE
        parts = []
        with torch.inference_mode():
            for start in range(0, len(samples), chunk):
                a, b = max(0, start - ctx), min(len(samples), start + chunk + ctx)
                wave = torch.from_numpy(samples[a:b]).unsqueeze(0)
                em, _ = self.model(wave)
                em = em[0]
                per_frame = (b - a) / em.shape[0]
                lead = int(round((start - a) / per_frame))
                body = int(round((min(start + chunk, len(samples)) - start) / per_frame))
                parts.append(em[lead:lead + body])
        em = torch.cat(parts)
        return em, len(samples) / SAMPLE_RATE / em.shape[0]

    def align(self, emission, sung):
        """Places every word; returns the aligned start (s) of each line that
        has words, with the line's lyrics start, and the mean word score."""
        words, owner = [], []
        for index, (_, _, text) in enumerate(sung):
            line_words, _ = romanize(text)
            words += line_words
            owner += [index] * len(line_words)
        if not words:
            return [], 0.0
        tokens = self.tokenizer(words)
        spans = self.aligner(emission, tokens)
        return spans, owner


def analyse_source(sung, frames, vad_curve, ctc_curve, aligned):
    """All the methods' numbers for one source's lines."""
    result = {"lines": len(sung)}
    lines = lines_curve(sung, frames)
    first_line = sung[0][0]
    if vad_curve is not None:
        probs, spv = vad_curve
        voice_at = first_voice(probs, spv)
        result["vad_first"] = None if voice_at is None else round(voice_at - first_line, 2)
        shift, score, margin = best_shift(to_steps(probs, spv, frames), lines)
        result["vad_corr"] = [round(shift, 2), round(score, 3), round(margin, 3)]
    if ctc_curve is not None:
        shift, score, margin = best_shift(ctc_curve, lines)
        result["ctc_corr"] = [round(shift, 2), round(score, 3), round(margin, 3)]
    if aligned is not None:
        result["align"] = aligned
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("data")
    parser.add_argument("out")
    parser.add_argument("--only", default="")
    parser.add_argument("--no-align", action="store_true")
    parser.add_argument("--threads", type=int, default=4)
    args = parser.parse_args()
    data = Path(args.data)
    only = {int(i) for i in args.only.split(",") if i.strip()}
    songs = sorted((data / "songs").glob("*.json"), key=lambda p: int(p.stem))
    vad = Vad()
    aligner = None if args.no_align else Aligner(args.threads)
    with open(args.out, "a", encoding="utf-8") as out:
        for song_path in songs:
            song = json.loads(song_path.read_text(encoding="utf-8"))
            index = song["index"]
            if only and index not in only:
                continue
            mp3 = data / "audio" / f"{index}.mp3"
            if not mp3.exists():
                print(f"#{index} no audio")
                continue
            clock = time.time()
            samples = decode(mp3)
            seconds = len(samples) / SAMPLE_RATE
            frames = int(seconds / STEP) + 1
            vad_curve = vad.probabilities(samples)
            vad_ms = int((time.time() - clock) * 1000)

            emission = ctc_curve = None
            align_ms = 0
            if aligner is not None:
                # The model's output is kept beside the audio, so the
                # analysis can change without running the model again.
                cached = data / "emission" / f"{index}.npy"
                started = time.time()
                if cached.exists():
                    emission = aligner.torch.from_numpy(np.load(cached))
                    spf = seconds / emission.shape[0]
                else:
                    emission, spf = aligner.emission(samples)
                    cached.parent.mkdir(exist_ok=True)
                    np.save(cached, emission.numpy().astype(np.float32))
                blank = emission[:, 0].exp().numpy()
                ctc_curve = to_steps(1 - blank, spf, frames)
                align_ms = int((time.time() - started) * 1000)

            record = {"index": index, "seconds": round(seconds, 1),
                      "vad_ms": vad_ms, "emission_ms": align_ms, "sources": {}}
            for source, lines in song["sources"].items():
                sung = sung_lines(lines)
                if len(sung) < 3:
                    continue
                aligned = None
                if aligner is not None:
                    _, kept = romanize(" ".join(t for _, _, t in sung))
                    if kept < 0.8:
                        aligned = {"skipped": f"letters kept {kept:.2f}"}
                    else:
                        started = time.time()
                        spans, owner = aligner.align(emission, sung)
                        starts, scores = {}, []
                        for word_spans, line_index in zip(spans, owner):
                            begin = word_spans[0].start * spf
                            scores.append(float(np.mean([s.score for s in word_spans])))
                            starts.setdefault(line_index, begin)
                        deltas = [starts[i] - sung[i][0] for i in sorted(starts)]
                        # The cheap form: only the lines of the first 60 s,
                        # placed on the first 90 s of audio.
                        head = [i for i in range(len(sung)) if sung[i][0] < 60]
                        head_offset = None
                        if len(head) >= 3:
                            frames_90 = min(emission.shape[0], int(90 / spf))
                            head_spans, head_owner = aligner.align(
                                emission[:frames_90].contiguous(),
                                [sung[i] for i in head])
                            head_starts = {}
                            for word_spans, line_index in zip(head_spans, head_owner):
                                head_starts.setdefault(line_index, word_spans[0].start * spf)
                            head_offset = round(float(np.median(
                                [head_starts[k] - sung[head[k]][0] for k in head_starts])), 2)
                        offset = float(np.median(deltas))
                        spread = float(np.median([abs(d - offset) for d in deltas]))
                        within = float(np.mean([abs(d - offset) < 1.0 for d in deltas]))
                        aligned = {
                            "offset": round(offset, 2),
                            "spread": round(spread, 2),
                            "within_1s": round(within, 2),
                            "score": round(float(np.mean(scores)), 3),
                            "first_delta": round(deltas[0], 2),
                            "head_offset": head_offset,
                            "head_lines": len(head),
                            "deltas": [round(d, 2) for d in deltas],
                            "ms": int((time.time() - started) * 1000),
                        }
                record["sources"][source] = analyse_source(
                    sung, frames, vad_curve, ctc_curve, aligned)
            out.write(json.dumps(record) + "\n")
            out.flush()
            parts = []
            for source, r in record["sources"].items():
                a = r.get("align", {})
                parts.append(
                    f"{source}: vad_first {r.get('vad_first')} vad_corr {r.get('vad_corr')}"
                    f" ctc_corr {r.get('ctc_corr')} align {a.get('offset', a.get('skipped'))}"
                    f" spread {a.get('spread')} within {a.get('within_1s')} head {a.get('head_offset')}")
            print(f"#{index} {seconds:.0f}s vad {vad_ms}ms emission {align_ms}ms | "
                  + " | ".join(parts), flush=True)


if __name__ == "__main__":
    sys.exit(main())
