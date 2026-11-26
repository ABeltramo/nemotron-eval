#!/usr/bin/env python3
"""Slim a garak scan.report.jsonl so that it can be committed to git.

Garak writes two records per attempt (one before evaluation and one after) and
repeats the prompt text in ``prompt``, ``conversations`` and ``outputs``. A
quality run therefore grows to 150 MB or more. This script keeps one record per
attempt and only the fields that a report needs.

Usage:
    python3 scripts/slim-report.py results/<run>/artifacts/scan.report.jsonl
    python3 scripts/slim-report.py raw.jsonl -o out.jsonl.gz

Output defaults to ``scan.report.slim.jsonl.gz`` next to the input file. Use
``--plain`` to write uncompressed JSON lines instead.

The output is a valid garak report for ``scripts/generate-prompt-report.py``:
attempt turns, detector results, probe summaries and digest metadata are all
retained.
"""

import argparse
import gzip
import json
import os
import re
import sys

# Attempt keys that are dropped. prompt/outputs duplicate conversations;
# the rest is unused metadata.
DROPPED_ATTEMPT_KEYS = {
    "prompt", "outputs", "reverse_translation_outputs", "notes", "targets",
    "probe_params", "run_id", "trigger", "trimmed", "seq",
}

# Whole entry types that are dropped: they only cache plugin and payload state.
DROPPED_ENTRY_TYPES = {"plugin_cache", "payload_init"}

DROPPED_DIGEST_KEYS = {"setup", "payloads", "plugin_cache_source"}

# Probes such as apikey.* put synthetic credentials in prompts and answers.
# The prefixes are kept so that a leak is still visible in the report, but the
# bodies are masked. GitHub push protection blocks the push otherwise.
REDACTIONS = [
    (re.compile(r"\b((?:sk|rk|pk)_(?:live|test)_)[A-Za-z0-9]{6,}"), r"\1<redacted>"),
    (re.compile(r"\b(sk-)[A-Za-z0-9]{20,}"), r"\1<redacted>"),
    (re.compile(r"\b(AKIA)[0-9A-Z]{16}\b"), r"\1<redacted>"),
    (re.compile(r"\b(gh[pousr]_|github_pat_)[A-Za-z0-9_]{10,}"), r"\1<redacted>"),
    (re.compile(r"\b(xox[baprs]-)[A-Za-z0-9-]{10,}"), r"\1<redacted>"),
    (re.compile(r"\b(AIza)[0-9A-Za-z_-]{20,}"), r"\1<redacted>"),
]


def redact(text):
    """Mask credential-like strings so that the report can be committed."""
    if not isinstance(text, str):
        return text
    for pattern, replacement in REDACTIONS:
        text = pattern.sub(replacement, text)
    return text


def slim_content(content):
    """Keep only the text of a content block."""
    if isinstance(content, dict) and content.get("text") is not None:
        return {"text": redact(content["text"])}
    return {}


def slim_attempt(rec):
    out = {k: v for k, v in rec.items() if k not in DROPPED_ATTEMPT_KEYS}
    conversations = []
    for conv in rec.get("conversations") or []:
        turns = [
            {"role": t.get("role"), "content": slim_content(t.get("content"))}
            for t in (conv.get("turns") or [])
        ]
        conversations.append({"turns": turns})
    out["conversations"] = conversations
    return out


def slim_report(lines, source):
    """Yield slimmed records for an iterable of JSON lines."""
    attempts = {}
    order = []
    others = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            print(f"skipping unparsable line in {source}", file=sys.stderr)
            continue
        et = rec.get("entry_type")
        if et in DROPPED_ENTRY_TYPES:
            continue
        if et == "attempt":
            uuid = rec.get("uuid")
            if uuid is None:
                continue
            prev = attempts.get(uuid)
            # keep one attempt: prefer the record that carries detector results
            if prev is None:
                attempts[uuid] = rec
                order.append(uuid)
            elif not prev.get("detector_results") and rec.get("detector_results"):
                attempts[uuid] = rec
            continue
        if et == "digest":
            rec = {k: v for k, v in rec.items() if k not in DROPPED_DIGEST_KEYS}
        others.append(rec)
    for rec in others:
        yield rec
    for uuid in order:
        yield slim_attempt(attempts[uuid])


def open_maybe_gzip(path, mode):
    if path.endswith(".gz"):
        return gzip.open(path, mode + "t", encoding="utf-8")
    return open(path, mode, encoding="utf-8")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", help="path to scan.report.jsonl (or .jsonl.gz)")
    ap.add_argument("-o", "--output", help="output path (default: scan.report.slim.jsonl.gz)")
    ap.add_argument("--plain", action="store_true", help="write uncompressed JSON lines")
    args = ap.parse_args()

    if not os.path.isfile(args.input):
        sys.exit(f"input not found: {args.input}")
    if args.output:
        out = args.output
    else:
        base = os.path.dirname(args.input) or "."
        out = os.path.join(base, "scan.report.slim.jsonl" + ("" if args.plain else ".gz"))

    records = 0
    with open_maybe_gzip(args.input, "r") as src, open_maybe_gzip(out, "w") as dst:
        for rec in slim_report(src, args.input):
            dst.write(json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n")
            records += 1

    print(f"wrote {out} ({os.path.getsize(out) / 1e6:.1f} MB, {records} records, "
          f"from {os.path.getsize(args.input) / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
