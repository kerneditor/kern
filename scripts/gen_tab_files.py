#!/usr/bin/env python3
"""Generate 55 unique test files for tab testing."""
import os

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
DIR = os.path.join(ROOT, "test-fixtures", "tabs")
os.makedirs(DIR, exist_ok=True)

def write_file(num, title, content):
    path = os.path.join(DIR, f"tab-{num:02d}.md")
    with open(path, 'w') as f:
        f.write(f"# Tab Test {num:02d} — {title}\n\n{content}\n")

# tab-01 to tab-10: Simple text
write_file(1, "Short Text", "A single paragraph of text for testing.")
write_file(2, "Two Paragraphs", "First paragraph.\n\nSecond paragraph.")
write_file(3, "Headings Only", "## Section A\n\n## Section B\n\n## Section C")
write_file(4, "Bold and Italic", "Some **bold** text and *italic* text and `code`.")
write_file(5, "Five Lines", "\n".join(f"Line {i+1}: Hello World" for i in range(5)))
write_file(6, "Blockquote", "> This is a blockquote\n> spanning two lines")
write_file(7, "Horizontal Rule", "Above\n\n---\n\nBelow")
write_file(8, "Link Test", "[Click here](https://example.com) for more info.")
write_file(9, "Inline Code", "Use `console.log()` for debugging in `JavaScript`.")
write_file(10, "Empty-ish", "This file has minimal content.")

# tab-11 to tab-20: Code blocks
langs = [
    ("JavaScript", "javascript", "const x = 42;\nconsole.log(`Value: ${x}`);"),
    ("Python", "python", "def hello():\n    print('Hello, World!')"),
    ("Rust", "rust", 'fn main() {\n    println!("Hello from Rust!");\n}'),
    ("Go", "go", 'package main\n\nimport "fmt"\n\nfunc main() {\n    fmt.Println("Hello")\n}'),
    ("Swift", "swift", 'import Foundation\nlet greeting = "Hello"\nprint(greeting)'),
    ("TypeScript", "typescript", "interface User {\n  id: number;\n  name: string;\n}\n\nconst user: User = { id: 1, name: 'Alice' };"),
    ("Java", "java", 'public class Main {\n    public static void main(String[] args) {\n        System.out.println("Hello");\n    }\n}'),
    ("C++", "cpp", '#include <iostream>\nint main() {\n    std::cout << "Hello" << std::endl;\n    return 0;\n}'),
    ("Ruby", "ruby", 'class Greeter\n  def initialize(name)\n    @name = name\n  end\n  def greet = "Hello, #{@name}!"\nend'),
    ("SQL", "sql", "SELECT u.name, COUNT(o.id) AS order_count\nFROM users u\nLEFT JOIN orders o ON u.id = o.user_id\nGROUP BY u.name\nORDER BY order_count DESC;"),
]
for i, (name, lang, code) in enumerate(langs, 11):
    write_file(i, f"{name} Code", f"```{lang}\n{code}\n```")

# tab-21 to tab-30: Checklists and lists
write_file(21, "Simple Checklist", "- [x] Done\n- [ ] Pending\n- [x] Also done")
write_file(22, "Nested Checklist", "- Parent\n  - [x] Child done\n  - [ ] Child pending")
write_file(23, "Ordered List", "1. First\n2. Second\n3. Third\n4. Fourth\n5. Fifth")
write_file(24, "Nested Ordered", "1. Level 1\n   1. Level 2a\n   2. Level 2b\n2. Level 1 again")
write_file(25, "Mixed Lists", "1. Ordered\n   - Bullet under ordered\n   - Another bullet\n2. Second ordered")
write_file(26, "Long Checklist", "\n".join(f"- [{'x' if i % 3 == 0 else ' '}] Task {i+1}" for i in range(20)))
write_file(27, "Deep Bullets", "- L0\n  - L1\n    - L2\n      - L3\n        - L4\n          - L5")
write_file(28, "Definition-like", "**Term 1**\n: Definition of term 1\n\n**Term 2**\n: Definition of term 2")
write_file(29, "Checklist Rich", "- [x] **Bold** task\n- [ ] *Italic* task\n- [x] `Code` task\n- [ ] [Link](https://example.com) task")
write_file(30, "All Checked", "\n".join(f"- [x] Completed item {i+1}" for i in range(10)))

# tab-31 to tab-35: Tables
write_file(31, "Simple Table", "| A | B | C |\n|---|---|---|\n| 1 | 2 | 3 |\n| 4 | 5 | 6 |")
write_file(32, "Wide Table", "| " + " | ".join(f"Col{i}" for i in range(1, 11)) + " |\n|" + "|".join(["---"] * 10) + "|\n| " + " | ".join(f"D{i}" for i in range(1, 11)) + " |")
write_file(33, "Rich Table", "| Feature | Status | Notes |\n|---------|--------|-------|\n| **Bold** | `done` | *italic* |\n| ~~removed~~ | active | [link](https://example.com) |")
write_file(34, "Aligned Table", "| Left | Center | Right |\n|:-----|:------:|------:|\n| L | C | R |\n| Left | Center | Right |")
write_file(35, "Large Table", "| ID | Name | Value | Status | Priority |\n|-----|------|-------|--------|----------|\n" + "\n".join(f"| {i} | Item-{i} | {i*100} | {'Active' if i%2==0 else 'Inactive'} | {'High' if i<4 else 'Low'} |" for i in range(1, 16)))

# tab-36 to tab-40: Mermaid diagrams
write_file(36, "Flowchart", "```mermaid\nflowchart TD\n    A[Start] --> B{Decision}\n    B -->|Yes| C[Action]\n    B -->|No| D[End]\n    C --> D\n```")
write_file(37, "Sequence", "```mermaid\nsequenceDiagram\n    Client->>Server: Request\n    Server->>DB: Query\n    DB-->>Server: Result\n    Server-->>Client: Response\n```")
write_file(38, "Class Diagram", "```mermaid\nclassDiagram\n    class Animal {\n        +String name\n        +eat() void\n    }\n    class Dog {\n        +bark() void\n    }\n    Animal <|-- Dog\n```")
write_file(39, "Pie Chart", '```mermaid\npie title Languages\n    "Swift" : 40\n    "TypeScript" : 30\n    "CSS" : 20\n    "Other" : 10\n```')
write_file(40, "State Diagram", "```mermaid\nstateDiagram-v2\n    [*] --> Idle\n    Idle --> Loading: open\n    Loading --> Editing: loaded\n    Editing --> Saving: save\n    Saving --> Editing: done\n    Editing --> [*]: close\n```")

# tab-41 to tab-45: LaTeX math
write_file(41, "Simple Math", "Inline: $E = mc^2$\n\nBlock:\n\n$$\n\\int_0^\\infty e^{-x} dx = 1\n$$")
write_file(42, "Matrix", "$$\nA = \\begin{pmatrix} 1 & 2 \\\\ 3 & 4 \\end{pmatrix}\n$$")
write_file(43, "Summation", "$$\n\\sum_{n=1}^{\\infty} \\frac{1}{n^2} = \\frac{\\pi^2}{6}\n$$")
write_file(44, "Greek Letters", "$\\alpha, \\beta, \\gamma, \\delta, \\epsilon, \\theta, \\lambda, \\mu, \\pi, \\sigma, \\phi, \\omega$")
write_file(45, "Complex Equation", "$$\n\\frac{\\partial^2 u}{\\partial t^2} = c^2 \\nabla^2 u\n$$\n\nThe wave equation in $n$ dimensions.")

# tab-46 to tab-50: Mixed content (200+ lines)
for i in range(46, 51):
    content_parts = [
        f"## Section A of Tab {i}\n",
        "Some introductory text with **bold** and *italic*.\n",
        "```python\ndef hello():\n    print('Hello from tab " + str(i) + "')\n```\n",
        "- Item 1\n- Item 2\n- Item 3\n  - Sub item\n",
        "| Col1 | Col2 |\n|------|------|\n| A | B |\n",
        "> A blockquote with some wisdom.\n",
        "$E = mc^2$\n",
        "---\n",
    ]
    content = ""
    for _ in range(30):
        import random
        random.seed(i * 100 + _)
        content += random.choice(content_parts) + "\n"
    write_file(i, f"Mixed Content {i}", content)

# tab-51 to tab-55: Large documents (500+ lines)
for i in range(51, 56):
    parts = []
    for j in range(1, 51):
        parts.append(f"## Chapter {j}\n")
        for k in range(10):
            parts.append(f"Paragraph {k+1} of chapter {j} in tab {i}. Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.\n")
        parts.append("")
    write_file(i, f"Large Document {i}", "\n".join(parts))

# Verify
import glob
files = sorted(glob.glob(os.path.join(DIR, "tab-*.md")))
print(f"Created {len(files)} tab files")
for f in files[-5:]:
    with open(f) as fh:
        lc = sum(1 for _ in fh)
    print(f"  {os.path.basename(f)}: {lc} lines")
