"""Plan 10 I2i1: the GPU runs against the CPU runs, by the app's own outputs.

Reads what tool/check_separator.dart, check_gigaam.dart and
check_whisper.dart wrote (see .local/v2-tools/gpu-60-run.sh) and prints:

- separator: the DirectML vocals (16 kHz mono) against the CPU's, as the
  signal-to-difference ratio in dB, and the time per song;
- GigaAM: per song the words of 1.24.4 CPU and 1.24.4 DirectML against
  1.31.1 CPU (share of the reference's words kept in order, by difflib),
  mean confidence, the 0.80 route, and the times;
- Whisper: Vulkan against the CPU on the same vocals, the same way, and the
  times (first run includes the shader compile).

Run: py -3 -I experiments/f2-timing/gpu_compare.py .local/v2-test
Prints no lyric text (only counts), so the output is safe for chat.
"""

import difflib
import json
import math
import sys
from pathlib import Path

import numpy as np


def load_json(path: Path):
    """One detail file of a check tool, or None when it is missing."""
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def words_of(detail) -> list[str]:
    """The heard words in order, lower-cased (text only, for matching)."""
    return [
        word[2].lower()
        for chunk in detail["chunks"]
        for word in chunk["words"]
    ]


def kept_share(reference: list[str], other: list[str]) -> float:
    """Share of the reference's words that the other run has in the same order."""
    if not reference:
        return 1.0 if not other else 0.0
    matcher = difflib.SequenceMatcher(a=reference, b=other, autojunk=False)
    same = sum(block.size for block in matcher.get_matching_blocks())
    return same / len(reference)


def ratio_db(reference: np.ndarray, other: np.ndarray) -> float:
    """10 log10 of the reference's energy over the difference's energy."""
    n = min(len(reference), len(other))
    difference = reference[:n] - other[:n]
    noise = float(np.dot(difference, difference))
    signal = float(np.dot(reference[:n], reference[:n]))
    if noise == 0:
        return math.inf
    return 10 * math.log10(signal / noise)


def runs_by_song(path: Path) -> dict:
    """The dart-runs.jsonl lines of a folder, the last one per song."""
    result = {}
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            row = json.loads(line)
            result[str(row.get("song", row.get("name")))] = row
    return result


def separator(root: Path) -> None:
    out = root / "stt-i2i"
    print("== separator: DirectML vs CPU 1.31.1 (stt-i2b), 16 kHz mono vocals")
    runs = runs_by_song(out / "sep-dml" / "dart-runs.jsonl")
    cpu_runs = runs_by_song(root / "stt-i2b" / "dart-runs.jsonl")
    for song, row in runs.items():
        line = (
            f"#{song}: {row['seconds']:.0f} s song, DML separate "
            f"{row['separate_ms'] / 1000:.1f} s (model {row['model_ms'] / 1000:.1f} s), "
            f"peak ws {row['peak_ws_mb']} MB"
        )
        cpu_file = root / "stt-i2b" / f"{song}.vocals16.f32"
        if cpu_file.exists():
            cpu = np.fromfile(cpu_file, dtype="<f4")
            dml = np.fromfile(out / "sep-dml" / f"{song}.vocals16.f32", dtype="<f4")
            cpu_row = cpu_runs.get(song)
            cpu_time = (
                f", CPU separate {cpu_row['separate_ms'] / 1000:.1f} s" if cpu_row else ""
            )
            line += f"; vs CPU {ratio_db(cpu, dml):.1f} dB{cpu_time}"
        print(line)
    v124 = out / "sep-cpu124" / "13.vocals16.f32"
    if v124.exists():
        cpu = np.fromfile(root / "stt-i2b" / "13.vocals16.f32", dtype="<f4")
        print(f"#13 CPU 1.24.4 vs CPU 1.31.1: {ratio_db(cpu, np.fromfile(v124, dtype='<f4')):.1f} dB")


def gigaam(root: Path) -> None:
    out = root / "stt-i2i"
    print("== GigaAM int8 on the DirectML vocals: 1.24.4 CPU and DML vs 1.31.1 CPU")
    base = out / "gig-cpu131"
    for path in sorted((p for p in base.glob("*.dart.json") if p.name.split(".")[0].isdigit()), key=lambda p: int(p.name.split(".")[0])):
        song = path.name.split(".")[0]
        ref = load_json(path)
        line = (
            f"#{song}: 1.31.1 {len(words_of(ref))} words, mean {ref['mean_confidence']:.3f}, "
            f"{'ru' if ref['russian'] else 'whisper'}, encode {ref['encode_ms'] / 1000:.1f} s"
        )
        for tag in ("gig-cpu124", "gig-dml"):
            other = load_json(out / tag / path.name)
            if other is None:
                line += f"; {tag} missing"
                continue
            line += (
                f"; {tag[4:]} kept {kept_share(words_of(ref), words_of(other)):.2f}, "
                f"{len(words_of(other))} words, mean {other['mean_confidence']:.3f}, "
                f"{'ru' if other['russian'] else 'whisper'}, "
                f"open {other['open_ms'] / 1000:.1f} s encode {other['encode_ms'] / 1000:.1f} s, "
                f"peak ws {other['peak_ws_mb']} MB"
            )
        print(line)


def whisper(root: Path) -> None:
    out = root / "stt-i2i"
    print("== Whisper turbo: Vulkan vs CPU (stt-i2d/run-2) on the same vocals")
    for song in ("13", "55", "57"):
        cpu = load_json(root / "stt-i2d" / "run-2" / f"{song}.dart.json")
        line = f"#{song}: CPU {cpu['transcribe_ms'] / 1000:.1f} s, {len(words_of(cpu))} words, mean {cpu['mean_confidence']:.3f}"
        for tag, folder in (("vk1", "wh-vk"), ("vk2", "wh-vk"), ("cpuvk", "wh-cpuvk")):
            other = load_json(out / folder / f"{song}.{tag}.json")
            if other is None:
                continue
            line += (
                f"; {tag} open {other['open_ms'] / 1000:.1f} s, transcribe {other['transcribe_ms'] / 1000:.1f} s, "
                f"kept {kept_share(words_of(cpu), words_of(other)):.2f}, mean {other['mean_confidence']:.3f}, "
                f"peak ws {other['peak_ws_mb']} MB"
            )
        print(line)
    print("== Whisper on Vulkan, all 11 (DirectML vocals)")
    for path in sorted((out / "wh-vk11").glob("*.vk.json"), key=lambda p: int(p.name.split(".")[0])):
        row = load_json(path)
        print(
            f"#{row['name']}: {row['seconds']:.0f} s, chunks {len(row['chunks'])}, "
            f"transcribe {row['transcribe_ms'] / 1000:.1f} s, {len(words_of(row))} words, "
            f"mean {row['mean_confidence']:.3f}"
        )


def main() -> None:
    root = Path(sys.argv[1])
    separator(root)
    gigaam(root)
    whisper(root)


if __name__ == "__main__":
    main()
