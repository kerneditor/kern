#!/usr/bin/env python3
"""
Render markdown request batches through cmarkgfm to compare semantics.

Input (stdin):
{
  "mode": "commonmark" | "gfm",
  "items": [{"id": 1, "input_markdown": "...", "output_markdown": "..."}]
}

Output (stdout):
{
  "mode": "...",
  "results": [{
    "id": 1,
    "input_html": "...",
    "output_html": "...",
    "semantic_match": true
  }]
}
"""

from __future__ import annotations

import argparse
import json
import sys

from cmarkgfm import github_flavored_markdown_to_html, markdown_to_html


def render(mode: str, markdown: str) -> str:
    if mode == "gfm":
        return github_flavored_markdown_to_html(markdown)
    if mode == "commonmark":
        return markdown_to_html(markdown)
    raise ValueError(f"Unsupported mode: {mode}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Render markdown batches via cmarkgfm")
    parser.add_argument("--mode", choices=["commonmark", "gfm"], required=True)
    parser.add_argument("--input-file", help="Optional JSON payload file path (fallback: stdin)")
    args = parser.parse_args()

    if args.input_file:
        with open(args.input_file, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    else:
        payload = json.load(sys.stdin)
    items = payload.get("items", [])

    results = []
    for item in items:
        case_id = int(item["id"])
        input_markdown = str(item["input_markdown"])
        output_markdown = str(item["output_markdown"])
        input_html = render(args.mode, input_markdown)
        output_html = render(args.mode, output_markdown)
        semantic_match = input_html == output_html
        results.append(
            {
                "id": case_id,
                # Keep payload small enough for large corpus runs:
                # include full HTML only for mismatches.
                "input_html": input_html if not semantic_match else "",
                "output_html": output_html if not semantic_match else "",
                "semantic_match": semantic_match,
            }
        )

    json.dump({"mode": args.mode, "results": results}, sys.stdout, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
