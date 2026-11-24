"""Plan 10 I2d: compares the app's Whisper (app/tool/check_whisper.dart) with gigaam_app's
(whisper_ref.py) on the same vocals.

    python -I check_whisper.py DIR [--a dart --b ref] NAMES...

For each NAME: DIR/NAME.A.json against DIR/NAME.B.json: chunk sample ranges,
each chunk's language, every token (bytes, start, end, probability) and every
word (start, end, text, confidence), all exactly; then the mean confidence.
Prints counts and the script of the words (Cyrillic, CJK, Latin letters), no
words themselves. Exit code 1 if anything differs.
"""

import argparse
import json
import re
import sys
from pathlib import Path

SCRIPTS = {"cyrillic": r"[Ѐ-ӿ]", "cjk": r"[぀-ヿ㐀-鿿가-힯]",
           "latin": r"[A-Za-zÀ-ɏ]"}


def letters_by_script(words):
    text = "".join(w[2] for w in words)
    return {name: len(re.findall(pattern, text)) for name, pattern in SCRIPTS.items()}


def split_tokens(chunks):
    """Tokens whose bytes are not whole UTF-8 characters on their own."""
    count = 0
    for chunk in chunks:
        for token in chunk["tokens"]:
            try:
                bytes.fromhex(token[0]).decode("utf-8")
            except UnicodeDecodeError:
                count += 1
    return count


def compare(name, a, b):
    problems = []
    ranges_a = [(c["start"], c["end"]) for c in a["chunks"]]
    ranges_b = [(c["start"], c["end"]) for c in b["chunks"]]
    if ranges_a != ranges_b:
        problems.append(f"chunk ranges differ: {len(ranges_a)} vs {len(ranges_b)}")
        return problems, {}
    tokens = words = 0
    for index, (ca, cb) in enumerate(zip(a["chunks"], b["chunks"])):
        if ca["language"] != cb["language"]:
            problems.append(f"chunk {index}: language {ca['language']} vs {cb['language']}")
        if ca["tokens"] != cb["tokens"]:
            first = next((i for i, (x, y) in enumerate(zip(ca["tokens"], cb["tokens"])) if x != y),
                         min(len(ca["tokens"]), len(cb["tokens"])))
            fields = []
            if first < min(len(ca["tokens"]), len(cb["tokens"])):
                x, y = ca["tokens"][first], cb["tokens"][first]
                fields = [n for n, u, v in zip(("bytes", "start", "end", "p"), x, y) if u != v]
            problems.append(f"chunk {index}: tokens differ from token {first} "
                            f"({len(ca['tokens'])} vs {len(cb['tokens'])}; fields {fields})")
        if ca["words"] != cb["words"]:
            first = next((i for i, (x, y) in enumerate(zip(ca["words"], cb["words"])) if x != y),
                         min(len(ca["words"]), len(cb["words"])))
            problems.append(f"chunk {index}: words differ from word {first} "
                            f"({len(ca['words'])} vs {len(cb['words'])})")
        tokens += len(ca["tokens"])
        words += len(ca["words"])
    if abs(a["mean_confidence"] - b["mean_confidence"]) > 1e-12:
        problems.append(f"mean confidence {a['mean_confidence']} vs {b['mean_confidence']}")
    all_words = [w for c in a["chunks"] for w in c["words"]]
    languages = {}
    for chunk in a["chunks"]:
        languages[chunk["language"]] = languages.get(chunk["language"], 0) + 1
    info = {"chunks": len(ranges_a), "tokens": tokens, "words": words, "languages": languages,
            "split_tokens": split_tokens(a["chunks"]), "letters": letters_by_script(all_words),
            "mean_confidence": round(a["mean_confidence"], 4)}
    return problems, info


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("dir", type=Path)
    parser.add_argument("--a", default="dart")
    parser.add_argument("--b", default="ref")
    parser.add_argument("names", nargs="+")
    args = parser.parse_args()
    failed = False
    for name in args.names:
        a = json.loads((args.dir / f"{name}.{args.a}.json").read_text(encoding="utf-8"))
        b = json.loads((args.dir / f"{name}.{args.b}.json").read_text(encoding="utf-8"))
        problems, info = compare(name, a, b)
        status = "SAME" if not problems else "DIFFERENT"
        print(f"{name} ({args.a} vs {args.b}): {status} {json.dumps(info)}")
        for problem in problems:
            print(f"  {problem}")
        failed = failed or bool(problems)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
