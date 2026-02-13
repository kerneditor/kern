#!/usr/bin/env python3
"""Append sections 8-11 to mega-stress-test.md"""
import random
import os

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OUT = os.path.join(ROOT, "test-fixtures", "mega-stress-test.md")
lines = []
def w(s=""): lines.append(s)

# ═══════════════════════════════════════════════════════════════════
# SECTION 8: DEEP NESTING
# ═══════════════════════════════════════════════════════════════════
w("---")
w()
w("## Section 8: Deep Nesting")
w()
w("### Bullet list nested 6+ levels")
w()
w("- Level 0")
w("  - Level 1")
w("    - Level 2")
w("      - Level 3")
w("        - Level 4")
w("          - Level 5")
w("            - Level 6 (very deep)")
w("            - Another at level 6")
w("          - Back to level 5")
w("        - Back to level 4")
w("      - Back to level 3")
w("    - Back to level 2")
w("  - Back to level 1")
w("- Back to level 0")
w()
w("### Ordered list nested 5+ levels")
w()
w("1. First at level 0")
w("   1. Level 1 item a")
w("      1. Level 2 item i")
w("         1. Level 3 item A")
w("            1. Level 4 item I")
w("            2. Level 4 item II")
w("         2. Level 3 item B")
w("      2. Level 2 item ii")
w("   2. Level 1 item b")
w("2. Second at level 0")
w("   1. Level 1 under second")
w("      1. Level 2 under second")
w()

w("### Blockquote nested 4+ levels")
w()
w("> Level 1 blockquote")
w("> > Level 2 blockquote")
w("> > > Level 3 blockquote")
w("> > > > Level 4 blockquote — this is very deeply nested")
w("> > > > and continues on the next line")
w("> > > Back to level 3")
w("> > Back to level 2")
w("> Back to level 1")
w()

w("### Mixed nesting: ordered > bullet > checklist > blockquote")
w()
w("1. Ordered item 1")
w("   - Bullet under ordered")
w("     - [x] Checked task under bullet")
w("       > Blockquote under checklist")
w("       > with multiple lines")
w("     - [ ] Unchecked task")
w("       > Another blockquote")
w("   - Another bullet")
w("     - [x] Done")
w("     - [ ] Pending")
w("2. Ordered item 2")
w("   - Bullet")
w("     - [x] Task")
w()

# More deep nesting variants
w("### Alternating ordered and unordered")
w()
w("1. Ordered")
w("   - Unordered")
w("     1. Ordered again")
w("        - Unordered again")
w("          1. Ordered once more")
w("             - Unordered once more")
w()

# ═══════════════════════════════════════════════════════════════════
# SECTION 9: LINKS AND IMAGES
# ═══════════════════════════════════════════════════════════════════
w("---")
w()
w("## Section 9: Links and Images")
w()
w("### Regular links")
w()
w("- [Milkdown Documentation](https://milkdown.dev)")
w("- [GitHub](https://github.com)")
w("- [Apple Developer](https://developer.apple.com)")
w("- [MDN Web Docs](https://developer.mozilla.org)")
w("- [TypeScript Handbook](https://www.typescriptlang.org/docs/handbook/)")
w()

w("### Link with title")
w()
w('[Hover me for title](https://example.com "This is a link title")')
w()

w("### Autolinks")
w()
w("Visit https://example.com for more information.")
w()

w("### HTTPS Images (various sizes)")
w()
w("Small image (200x50):")
w()
w("![Small](https://placehold.co/200x50/007aff/ffffff?text=Small)")
w()
w("Medium image (400x100):")
w()
w("![Medium](https://placehold.co/400x100/34c759/ffffff?text=Medium)")
w()
w("Large image (800x200):")
w()
w("![Large](https://placehold.co/800x200/ff9500/ffffff?text=Large+Image)")
w()
w("Square image (300x300):")
w()
w("![Square](https://placehold.co/300x300/5856d6/ffffff?text=Square)")
w()

w("### Broken image (404 — error handling test)")
w()
w("![This should fail](https://placehold.co/does-not-exist-404)")
w()

w("### Image inside a link")
w()
w("[![Clickable image](https://placehold.co/300x80/007aff/ffffff?text=Click+Me)](https://example.com)")
w()

# ═══════════════════════════════════════════════════════════════════
# SECTION 10: EDGE CASES
# ═══════════════════════════════════════════════════════════════════
w("---")
w()
w("## Section 10: Edge Cases")
w()

w("### Very long single line (500+ characters)")
w()
w("A" * 600)
w()

w("### Empty code block")
w()
w("```")
w("```")
w()

w("### Code block with only whitespace")
w()
w("```")
w("   ")
w("  ")
w(" ")
w("```")
w()

w("### Special characters")
w()
w("Angle brackets: < > &lt; &gt;")
w()
w("Ampersand: & &amp;")
w()
w('Quotes: " \' ` ``')
w()
w("Symbols: ~!@#$%^&*()_+-=[]{}|;:,.<>?/")
w()
w("Backslash: \\ \\\\")
w()

w("### Nested blockquote with code block inside")
w()
w("> Here is a blockquote containing code:")
w("> ")
w("> ```python")
w("> def hello():")
w('>     print("Hello from inside a blockquote!")')
w("> ```")
w("> ")
w("> And some text after the code block.")
w()

w("### Horizontal rules in various formats")
w()
w("Above rule 1 (three hyphens):")
w()
w("---")
w()
w("Above rule 2 (three asterisks):")
w()
w("***")
w()
w("Above rule 3 (three underscores):")
w()
w("___")
w()

w("### Consecutive headings")
w()
w("# Heading 1")
w("## Heading 2")
w("### Heading 3")
w("#### Heading 4")
w("##### Heading 5")
w("###### Heading 6")
w()

w("### Very Long Heading That Goes On And On And Should Still Render Properly Without Breaking The Layout Or Causing Horizontal Scrollbars In The Editor")
w()
w("Content after the long heading.")
w()

w("### HTML entities")
w()
w("&copy; &reg; &trade; &mdash; &ndash; &hellip; &laquo; &raquo; &bull; &nbsp;")
w()

w("### Escaped markdown characters")
w()
w("\\*not italic\\* \\*\\*not bold\\*\\* \\`not code\\` \\[not a link\\] \\# not a heading")
w()

# ═══════════════════════════════════════════════════════════════════
# SECTION 11: FILLER / VOLUME (to reach 5000+ lines)
# ═══════════════════════════════════════════════════════════════════
w("---")
w()
w("## Section 11: Volume Test (Filler Content)")
w()
w("The following content is generated to push the document past 5000 lines,")
w("testing the editor's performance with large documents.")
w()

# Generate ~80 subsections with ~40 lines each = ~3200 lines
paragraphs = [
    "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.",
    "Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.",
    "Curabitur pretium tincidunt lacus. Nulla gravida orci a odio. Nullam varius, turpis et commodo pharetra, est eros bibendum elit, nec luctus magna felis sollicitudin mauris. Integer in mauris eu nibh euismod gravida.",
    "Praesent dapibus, neque id cursus faucibus, tortor neque egestas augue, eu vulputate magna eros eu erat. Aliquam erat volutpat. Nam dui mi, tincidunt quis, accumsan porttitor, facilisis luctus, metus.",
    "Phasellus ultrices nulla quis nibh. Quisque a lectus. Donec consectetuer ligula vulputate sem tristique cursus. Nam nulla quam, gravida non, commodo a, sodales sit amet, nisi.",
    "Pellentesque fermentum dolor. Aliquam quam lectus, facilisis auctor, ultrices ut, elementum vulputate, nunc. Sed adipiscing ornare risus. Morbi est est, blandit sit amet, sagittis vel, euismod vel, velit.",
    "Software engineering requires careful planning, systematic testing, and continuous improvement. Every line of code should serve a purpose, and every abstraction should earn its place in the architecture.",
    "The best editors are the ones that get out of your way. They should load instantly, render faithfully, and save automatically. No setup wizards, no configuration files, no learning curves.",
    "A markdown editor should respect the format's simplicity while providing visual feedback that helps writers focus on content rather than syntax. WYSIWYG rendering bridges the gap between raw text and final output.",
    "Performance is a feature, not an afterthought. Every millisecond of startup time, every megabyte of memory, and every frame of animation contributes to the overall user experience.",
]

code_samples = [
    ("python", "x = sum(i**2 for i in range(100))\nprint(f'Result: {x}')"),
    ("javascript", "const arr = [1, 2, 3].map(x => x * 2);\nconsole.log(arr);"),
    ("swift", "let greeting = \"Hello, World!\"\nprint(greeting)"),
    ("rust", "let v: Vec<i32> = (0..10).collect();\nprintln!(\"{:?}\", v);"),
    ("go", "fmt.Println(\"Hello from Go\")"),
    ("typescript", "const x: number = 42;\nconsole.log(`Value: ${x}`);"),
]

formats = [
    lambda t: f"**{t}**",  # bold
    lambda t: f"*{t}*",    # italic
    lambda t: f"`{t}`",    # code
    lambda t: t,            # plain
    lambda t: f"~~{t}~~",  # strikethrough
]

random.seed(42)  # reproducible

for section_num in range(1, 81):
    w(f"### Volume Section {section_num}")
    w()

    # 2-3 paragraphs with random formatting
    for _ in range(random.randint(2, 3)):
        para = random.choice(paragraphs)
        # Apply random formatting to a few words
        words = para.split()
        if len(words) > 10:
            idx = random.randint(2, len(words) - 3)
            fmt = random.choice(formats)
            words[idx] = fmt(words[idx])
        w(' '.join(words))
        w()

    # Every 5th section, add a code block
    if section_num % 5 == 0:
        lang, code = random.choice(code_samples)
        w(f"```{lang}")
        w(code)
        w("```")
        w()

    # Every 7th section, add a small table
    if section_num % 7 == 0:
        w("| Key | Value |")
        w("|-----|-------|")
        for j in range(3):
            w(f"| item-{j} | value-{j} |")
        w()

    # Every 10th section, add a checklist
    if section_num % 10 == 0:
        w("- [x] Completed task")
        w("- [ ] Pending task")
        w("- [x] Another done")
        w()

    # Every 8th section, add a bullet list
    if section_num % 8 == 0:
        for j in range(4):
            w(f"- Item {j+1} in volume section {section_num}")
        w()

    # Every 12th section, add a blockquote
    if section_num % 12 == 0:
        w("> This is a blockquote in volume section.")
        w("> It contains multiple lines of content.")
        w()

    # Every 15th section, add math
    if section_num % 15 == 0:
        w(f"Inline math: $x_{section_num} = \\sqrt{{{section_num}}}$")
        w()
        w("$$")
        w(f"\\sum_{{i=1}}^{{{section_num}}} i^2 = \\frac{{{section_num}({section_num}+1)(2 \\cdot {section_num}+1)}}{{6}}")
        w("$$")
        w()

w("---")
w()
w("*End of Kern Mega Stress Test — 5000+ lines of comprehensive markdown content*")
w()

with open(OUT, 'a') as f:
    f.write('\n'.join(lines))

# Count total lines
with open(OUT) as f:
    total = sum(1 for _ in f)
print(f"Part 3 appended: {len(lines)} lines")
print(f"Total file: {total} lines")
