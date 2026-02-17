#!/usr/bin/env python3
"""
Fetch and materialize official Markdown spec examples for local conformance tests.

Outputs:
  - test-fixtures/spec/commonmark-<version>.json
  - test-fixtures/spec/gfm-<tag>.json
"""

from __future__ import annotations

import argparse
import json
import re
import urllib.request
from pathlib import Path

COMMONMARK_VERSION = "0.31.2"
COMMONMARK_URL_TEMPLATE = "https://spec.commonmark.org/{version}/spec.json"

GFM_TAG = "0.29.0.gfm.13"
GFM_SPEC_URL_TEMPLATE = "https://raw.githubusercontent.com/github/cmark-gfm/{tag}/test/spec.txt"


def fetch_text(url: str) -> str:
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "KernTextKit-spec-fixture-updater/1.0",
            "Accept": "text/plain, application/json;q=0.9, */*;q=0.1",
        },
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read().decode("utf-8")


def parse_gfm_spec_txt(spec_text: str) -> list[dict]:
    """
    Parse cmark-gfm spec.txt format.
    """
    tests: list[dict] = []
    header_re = re.compile(r"^#+ ")

    line_number = 0
    start_line = 0
    end_line = 0
    example_number = 0
    markdown_lines: list[str] = []
    html_lines: list[str] = []
    state = 0  # 0 regular, 1 markdown, 2 html
    extensions: list[str] = []
    headertext = ""

    open_marker_prefix = "`" * 32 + " example"
    close_marker = "`" * 32

    for line in spec_text.splitlines(keepends=True):
        line_number += 1
        stripped = line.strip()

        if stripped.startswith(open_marker_prefix):
            state = 1
            extensions = stripped[len(open_marker_prefix) :].split()
            continue

        if stripped == close_marker:
            state = 0
            example_number += 1
            end_line = line_number
            if "disabled" not in extensions:
                tests.append(
                    {
                        "example": example_number,
                        "start_line": start_line,
                        "end_line": end_line,
                        "section": headertext,
                        "markdown": "".join(markdown_lines).replace("→", "\t"),
                        "html": "".join(html_lines).replace("→", "\t"),
                        "extensions": extensions,
                    }
                )
            start_line = 0
            markdown_lines = []
            html_lines = []
            extensions = []
            continue

        if stripped == ".":
            state = 2
            continue

        if state == 1:
            if start_line == 0:
                start_line = line_number - 1
            markdown_lines.append(line)
            continue

        if state == 2:
            html_lines.append(line)
            continue

        if state == 0 and header_re.match(line):
            headertext = header_re.sub("", line).strip()

    return tests


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Update official Markdown spec fixtures")
    parser.add_argument(
        "--output-dir",
        default="test-fixtures/spec",
        help="Directory to write spec fixture JSON files",
    )
    parser.add_argument(
        "--commonmark-version",
        default=COMMONMARK_VERSION,
        help="CommonMark spec version (default: %(default)s)",
    )
    parser.add_argument(
        "--gfm-tag",
        default=GFM_TAG,
        help="cmark-gfm tag for test/spec.txt (default: %(default)s)",
    )
    args = parser.parse_args()

    output_dir = Path(args.output_dir)

    commonmark_url = COMMONMARK_URL_TEMPLATE.format(version=args.commonmark_version)
    commonmark_raw = fetch_text(commonmark_url)
    commonmark_examples = json.loads(commonmark_raw)
    commonmark_payload = {
        "source": commonmark_url,
        "spec": "commonmark",
        "version": args.commonmark_version,
        "example_count": len(commonmark_examples),
        "examples": commonmark_examples,
    }
    commonmark_path = output_dir / f"commonmark-{args.commonmark_version}.json"
    write_json(commonmark_path, commonmark_payload)

    gfm_url = GFM_SPEC_URL_TEMPLATE.format(tag=args.gfm_tag)
    gfm_raw = fetch_text(gfm_url)
    gfm_examples = parse_gfm_spec_txt(gfm_raw)
    gfm_payload = {
        "source": gfm_url,
        "spec": "gfm",
        "version": args.gfm_tag,
        "example_count": len(gfm_examples),
        "examples": gfm_examples,
    }
    gfm_path = output_dir / f"gfm-{args.gfm_tag}.json"
    write_json(gfm_path, gfm_payload)

    print(f"Wrote {commonmark_payload['example_count']} CommonMark examples to {commonmark_path}")
    print(f"Wrote {gfm_payload['example_count']} GFM examples to {gfm_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
