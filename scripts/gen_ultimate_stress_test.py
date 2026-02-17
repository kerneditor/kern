#!/usr/bin/env python3
"""Generate test-fixtures/ultimate-stress-test.md.

This fixture is combination-dense (feature permutations), while mega-stress-test.md remains
volume-dense (5000+ lines).
"""

from __future__ import annotations

from itertools import combinations
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "test-fixtures" / "ultimate-stress-test.md"


def slug(s: str) -> str:
    out = []
    for ch in s.lower():
        if ch.isalnum() or ch in {" ", "-"}:
            out.append(ch)
    return "".join(out).strip().replace(" ", "-")


def write(lines: list[str]) -> None:
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    lines: list[str] = []
    lines.append("# Kern Ultimate Stress Test (Permutation Dense)")
    lines.append("")
    lines.append("This file is intentionally dense with feature and action permutations.")
    lines.append("It is the canonical fixture for exhaustive typing/action matrix tests.")
    lines.append("")

    sections = [
        "Heading Matrix",
        "List And Task Matrix",
        "Inline Formatting Matrix",
        "Code Fence Language Matrix",
        "Table Matrix",
        "Blockquote And Rule Matrix",
        "Math Matrix",
        "Image Matrix",
        "Mermaid Matrix",
        "Action Permutation Seeds",
        "Typing Volume Tail",
    ]

    lines.append("## Table of Contents")
    lines.append("")
    for section in sections:
        lines.append(f"- [{section}](#{slug(section)})")
    lines.append("")

    # 1) Heading matrix
    lines.append("## Heading Matrix")
    lines.append("")
    for level in range(1, 7):
        marks = "#" * level
        lines.append(f"{marks} H{level} plain heading")
        lines.append(f"{marks} [ ] H{level} unchecked task heading")
        lines.append(f"{marks} [x] H{level} checked task heading")
        lines.append("")

    # 2) List + task matrix
    lines.append("## List And Task Matrix")
    lines.append("")
    bullets = ["-", "*", "+"]
    states = ["[ ]", "[x]"]
    for marker in bullets:
        lines.append(f"### Bullet marker `{marker}`")
        lines.append("")
        lines.append(f"{marker} plain item")
        lines.append(f"{marker} nested parent")
        lines.append(f"  {marker} nested child")
        for state in states:
            lines.append(f"{marker} {state} task using marker {marker}")
            lines.append(f"  {marker} {state} nested task")
        lines.append("")

    lines.append("### Ordered lists and ordered tasks")
    lines.append("")
    for n in [1, 2, 9, 10, 42]:
        lines.append(f"{n}. plain ordered item")
        lines.append(f"{n}. [ ] ordered unchecked task")
        lines.append(f"{n}. [x] ordered checked task")
    lines.append("")
    lines.append("### Standalone task shortcuts")
    lines.append("")
    lines.append("[ ] standalone unchecked")
    lines.append("[x] standalone checked")
    lines.append("[] standalone shortcut without space")
    lines.append("")

    lines.append("### Mixed nesting permutations")
    lines.append("")
    for i in range(1, 9):
        lines.append(f"{i}. ordered parent {i}")
        lines.append("   - [ ] child unchecked task")
        lines.append("   - [x] child checked task")
        lines.append("   - child plain bullet")
        lines.append("     1. grandchild ordered")
        lines.append("     1. [ ] grandchild ordered task")
        lines.append("     1. [x] grandchild ordered checked task")
    lines.append("")

    # 3) Inline matrix
    lines.append("## Inline Formatting Matrix")
    lines.append("")
    atoms = [
        ("bold", "**bold**"),
        ("italic", "*italic*"),
        ("strike", "~~strike~~"),
        ("code", "`code`"),
        ("link", "[link](https://example.com/path?q=1#frag)"),
    ]
    lines.append("### Singles")
    lines.append("")
    for name, token in atoms:
        lines.append(f"- `{name}` => {token}")
    lines.append("")
    lines.append("### Pair combinations")
    lines.append("")
    for (name_a, a), (name_b, b) in combinations(atoms, 2):
        lines.append(f"- `{name_a}+{name_b}` => {a} then {b}")
    lines.append("")
    lines.append("### Triple combinations")
    lines.append("")
    for (name_a, a), (name_b, b), (name_c, c) in combinations(atoms, 3):
        lines.append(f"- `{name_a}+{name_b}+{name_c}` => {a} / {b} / {c}")
    lines.append("")

    # 4) Code fences
    lines.append("## Code Fence Language Matrix")
    lines.append("")
    snippets: dict[str, list[str]] = {
        "javascript": ['const answer = 42;', 'console.log(`answer=${answer}`);'],
        "typescript": ["interface User { id: number; name: string }", "const u: User = { id: 1, name: 'A' };"],
        "python": ["def fib(n: int) -> list[int]:", "    return [0, 1][:n]"],
        "rust": ["fn main() {", '    println!("hi");', "}"],
        "go": ["package main", 'func main() { println("hi") }'],
        "swift": ["struct User { let id: Int }", "print(User(id: 1))"],
        "kotlin": ["data class User(val id: Int)", 'println(User(1))'],
        "ruby": ["class User; attr_accessor :id; end", "puts User.new"],
        "java": ["record User(int id) {}", "System.out.println(new User(1));"],
        "c": ["int main(void) {", '  puts("hi");', "  return 0;", "}"],
        "cpp": ["int main() {", '  std::cout << "hi";', "}"],
        "bash": ["for f in *.md; do", '  echo "$f"', "done"],
        "zsh": ["typeset -a items=(a b c)", "print -l -- $items"],
        "powershell": ['Write-Host "hello"', "Get-ChildItem ."],
        "sql": ["SELECT id, name FROM users WHERE active = 1;", "UPDATE users SET active = 0 WHERE id = 42;"],
        "json": ['{"name":"kern","enabled":true}'],
        "yaml": ["name: kern", "enabled: true"],
        "toml": ["[editor]", "name = 'kern'"],
        "html": ["<section><h1>Kern</h1></section>"],
        "css": [".editor { display: grid; gap: 12px; }"],
        "xml": ["<root><item id=\"1\"/></root>"],
        "dockerfile": ["FROM swift:6.0", "RUN swift --version"],
        "lua": ['print("hello")'],
        "php": ["<?php", 'echo "hello";'],
    }
    for lang, snippet_lines in snippets.items():
        lines.append(f"### {lang}")
        lines.append("")
        lines.append(f"```{lang}")
        lines.extend(snippet_lines)
        lines.append("```")
        lines.append("")

    # 5) Tables
    lines.append("## Table Matrix")
    lines.append("")
    lines.append("| Left | Center | Right |")
    lines.append("| :--- | :----: | ----: |")
    lines.append("| alpha | beta | gamma |")
    lines.append("| **bold** | `code` | [link](https://example.com) |")
    lines.append("")
    lines.append("| Feature | GFM Default | Kern Extensions |")
    lines.append("| --- | --- | --- |")
    lines.append("| Ordered tasks | literal | rendered |")
    lines.append("| Heading checkboxes | literal | rendered |")
    lines.append("")

    # 6) Quote + rules
    lines.append("## Blockquote And Rule Matrix")
    lines.append("")
    lines.append('> "The best way to predict the future is to invent it."')
    lines.append("> - [ ] quoted unchecked task")
    lines.append("> - [x] quoted checked task")
    lines.append("> 1. quoted ordered item")
    lines.append("> 1. [ ] quoted ordered task")
    lines.append("")
    lines.append("---")
    lines.append("")
    lines.append("***")
    lines.append("")
    lines.append("___")
    lines.append("")

    # 7) Math
    lines.append("## Math Matrix")
    lines.append("")
    lines.append("Inline math examples: $E=mc^2$, $\\alpha+\\beta=\\gamma$, and $\\sum_{i=1}^{n} i = n(n+1)/2$.")
    lines.append("")
    lines.append("$$")
    lines.append("\\int_{-\\infty}^{\\infty} e^{-x^2} dx = \\sqrt{\\pi}")
    lines.append("$$")
    lines.append("")
    lines.append("$$")
    lines.append("A = \\begin{pmatrix} 1 & 2 \\\\ 3 & 4 \\end{pmatrix}")
    lines.append("$$")
    lines.append("")

    # 8) Images
    lines.append("## Image Matrix")
    lines.append("")
    lines.append("![Local sample](screenshots/01-default-sample.png)")
    lines.append("")
    lines.append("![Broken local image](screenshots/does-not-exist.png)")
    lines.append("")
    lines.append("![Remote sample 1](https://upload.wikimedia.org/wikipedia/commons/thumb/0/02/Oia%2C_Santorini_HDR_sunset.jpg/640px-Oia%2C_Santorini_HDR_sunset.jpg)")
    lines.append("")
    lines.append("![Remote sample 2](https://upload.wikimedia.org/wikipedia/commons/thumb/3/3f/Fronalpstock_big.jpg/640px-Fronalpstock_big.jpg)")
    lines.append("")

    # 9) Mermaid
    lines.append("## Mermaid Matrix")
    lines.append("")
    lines.append("```mermaid")
    lines.append("flowchart TD")
    lines.append("Open[Open File] --> Parse[Parse Markdown]")
    lines.append("Parse --> Render[Render WYSIWYG]")
    lines.append("Render --> Save[Auto Save]")
    lines.append("```")
    lines.append("")
    lines.append("```mermaid")
    lines.append("sequenceDiagram")
    lines.append("participant User")
    lines.append("participant Kern")
    lines.append("User->>Kern: Type markdown")
    lines.append("Kern->>Kern: Apply input rules")
    lines.append("Kern-->>User: Rendered output")
    lines.append("```")
    lines.append("")

    # 10) Action seeds
    lines.append("## Action Permutation Seeds")
    lines.append("")
    lines.append("These lines are intentionally repetitive for typing/backspace/replace permutations.")
    lines.append("")
    for i in range(1, 241):
        lines.append(f"- ACTION-SEED-{i:03d}: alpha beta gamma delta {i}")
    lines.append("")

    # 11) Volume tail
    lines.append("## Typing Volume Tail")
    lines.append("")
    for i in range(1, 701):
        lines.append(
            f"Volume line {i:04d}: quick brown fox with **bold**, *italic*, `code`, "
            f"[link](https://example.com/{i}), and task marker [ ] candidate."
        )
        if i % 25 == 0:
            lines.append(f"- [ ] checkpoint task {i}")
            lines.append(f"1. ordered checkpoint {i}")
            lines.append("---")
            lines.append("")

    lines.append("")
    lines.append("*End of Kern Ultimate Stress Test*")
    write(lines)
    print(f"Wrote {OUT}")


if __name__ == "__main__":
    main()
